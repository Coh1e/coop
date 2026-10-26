#include "msi.hpp"
#include "archive.hpp"
#include "data.hpp"
#include <windows.h>
#include <fdi.h>
#include <msi.h>
#include <msiquery.h>
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <cwctype>
#include <functional>
#include <map>
#include <memory>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

namespace coop {
namespace {
constexpr int file_attribute_noncompressed = 0x2000;
// FDICopy receives a cabinet name and a path prefix and hands the concatenation to FNOPEN. Both
// are placeholders: the callbacks below open the real, already-extracted cabinet stream through
// its wide path, so Unicode and long Coop roots keep working.
constexpr char cabinet_placeholder[] = "coop-msi-cabinet.cab";

std::runtime_error installer_error(const std::string& action, UINT status) {
    return std::runtime_error(action + " (Windows Installer error " + std::to_string(status) + ")");
}
// Every MSI handle (database, view, record) is closed through the same API.
class Handle {
public:
    Handle() = default;
    explicit Handle(MSIHANDLE value) : value_(value) {}
    ~Handle() { if (value_) MsiCloseHandle(value_); }
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
    MSIHANDLE get() const { return value_; }
private:
    MSIHANDLE value_ = 0;
};
std::wstring lower(std::wstring value) {
    for (auto& character : value) character = static_cast<wchar_t>(std::towlower(character));
    return value;
}
std::uint64_t number(const std::wstring& value) {
    if (value.empty()) return 0;
    try { return std::stoull(value); }
    catch (const std::exception&) { throw std::runtime_error("MSI table contains a non-numeric size or sequence"); }
}
std::wstring field_text(MSIHANDLE record, UINT field) {
    std::wstring buffer(256, L'\0');
    DWORD length = static_cast<DWORD>(buffer.size());
    UINT status = MsiRecordGetStringW(record, field, buffer.data(), &length);
    if (status == ERROR_MORE_DATA) {
        buffer.resize(static_cast<std::size_t>(length) + 1, L'\0');
        length = static_cast<DWORD>(buffer.size());
        status = MsiRecordGetStringW(record, field, buffer.data(), &length);
    }
    if (status != ERROR_SUCCESS) throw installer_error("Cannot read a field from an MSI table", status);
    buffer.resize(length);
    return buffer;
}
struct Row { std::vector<std::wstring> fields; };
std::vector<Row> query(MSIHANDLE database, const std::wstring& sql, UINT columns) {
    MSIHANDLE raw_view = 0;
    UINT status = MsiDatabaseOpenViewW(database, sql.c_str(), &raw_view);
    if (status != ERROR_SUCCESS) throw installer_error("Cannot query the MSI database", status);
    const Handle view(raw_view);
    status = MsiViewExecute(view.get(), 0);
    if (status != ERROR_SUCCESS) throw installer_error("Cannot execute the MSI database query", status);
    std::vector<Row> rows;
    for (;;) {
        MSIHANDLE raw_record = 0;
        status = MsiViewFetch(view.get(), &raw_record);
        if (status == ERROR_NO_MORE_ITEMS) break;
        if (status != ERROR_SUCCESS) throw installer_error("Cannot read MSI table rows", status);
        const Handle record(raw_record);
        if (MsiRecordGetFieldCount(record.get()) < columns)
            throw std::runtime_error("MSI database query returned fewer columns than requested");
        Row row;
        row.fields.reserve(columns);
        for (UINT field = 1; field <= columns; ++field) row.fields.push_back(field_text(record.get(), field));
        rows.push_back(std::move(row));
        if (rows.size() > maximum_archive_entries) throw std::runtime_error("MSI image has too many rows");
    }
    return rows;
}
// DefaultDir and FileName carry a short|long name pair. The administrative image uses the long
// target name, which is the part after the bar; the colon spelling names a target and source
// explicitly and keeps the target before the colon.
std::wstring target_name(const std::wstring& declared) {
    std::wstring value = declared;
    if (const auto bar = value.find_last_of(L'|'); bar != std::wstring::npos) value = value.substr(bar + 1);
    if (const auto colon = value.find(L':'); colon != std::wstring::npos && colon > 1) value = value.substr(0, colon);
    while (!value.empty() && (value.back() == L'\\' || value.back() == L'/')) value.pop_back();
    return value;
}
fs::path path_component(const std::wstring& value, const std::string& context) {
    if (value.empty() || value == L"." || value == L"..")
        throw std::runtime_error(context + " does not name a concrete directory or file");
    if (value.find_first_of(L"\\/:*?\"<>|") != std::wstring::npos || value.back() == L'.' || value.back() == L' ')
        throw std::runtime_error(context + " contains an unsafe path component: " + utf8(value));
    validate_component(utf8(value));
    return fs::path(value);
}
struct DirectoryRow {
    std::wstring name;
    std::wstring parent;
    std::wstring default_dir;
};
// Resolve the administrative image layout: the image root is TARGETDIR, every other directory is
// the parent's image path plus its long target name, "." keeps the parent path and ".." moves up.
// This is the layout msiexec /a produces under TARGETDIR\SourceDir and therefore the layout Scoop
// already installed into the shared root.
std::vector<fs::path> directory_paths(const std::vector<DirectoryRow>& rows) {
    std::map<std::wstring, std::size_t> index;
    for (std::size_t position = 0; position < rows.size(); ++position) {
        if (!index.emplace(lower(rows[position].name), position).second)
            throw std::runtime_error("MSI Directory table repeats the directory " + utf8(rows[position].name));
    }
    std::vector<fs::path> paths(rows.size());
    std::vector<int> state(rows.size(), 0);
    std::function<fs::path(std::size_t, std::size_t)> resolve = [&](std::size_t position, std::size_t depth) -> fs::path {
        if (state[position] == 2) return paths[position];
        if (state[position] == 1) throw std::runtime_error("MSI Directory table contains a parent cycle");
        if (depth > 64) throw std::runtime_error("MSI Directory table is nested too deeply");
        state[position] = 1;
        const auto& row = rows[position];
        fs::path path;
        if (!row.parent.empty() && lower(row.parent) != lower(row.name)) {
            const auto parent = index.find(lower(row.parent));
            if (parent == index.end())
                throw std::runtime_error("MSI Directory table names a missing parent for " + utf8(row.name));
            path = resolve(parent->second, depth + 1);
            const auto name = target_name(row.default_dir);
            if (name == L"..") path = path.parent_path();
            else if (!name.empty() && name != L".") path /= path_component(name, "MSI directory " + utf8(row.name));
        }
        paths[position] = std::move(path);
        state[position] = 2;
        return paths[position];
    };
    for (std::size_t position = 0; position < rows.size(); ++position) (void)resolve(position, 0);
    return paths;
}
struct MediaRow {
    int disk = 0;
    std::wstring cabinet;
};
struct FileRow {
    std::wstring key;
    std::wstring file_name;
    std::uint64_t size = 0;
    int sequence = 0;
    int attributes = 0;
    fs::path relative;
    bool extracted = false;
};
struct ImageFacts {
    std::vector<std::string> cabinets;
    std::size_t cab_files = 0;
    std::size_t stream_files = 0;
    std::size_t files = 0;
    std::uint64_t bytes = 0;
};
// A file handle opened by FDI callbacks. The same structure serves the cabinet file itself and
// the target files FDI writes, so the callbacks never depend on CRT file descriptors or ANSI paths.
struct OpenFile {
    HANDLE value = INVALID_HANDLE_VALUE;
    bool target = false;
    std::size_t file_index = 0;
    std::uint64_t written = 0;
    bool closed = false;
    ~OpenFile() {
        if (value != INVALID_HANDLE_VALUE && !closed) CloseHandle(value);
    }
};
struct CabinetContext {
    fs::path cabinet;
    fs::path destination;
    const std::map<std::wstring,std::size_t>* by_key = nullptr;
    std::vector<FileRow>* files = nullptr;
    ImageFacts* facts = nullptr;
    std::vector<std::unique_ptr<OpenFile>> handles;
    std::string error;
};
std::string ascii_text(const char* value) {
    const std::string text = value ? value : "";
    for (const auto byte : text) {
        if (static_cast<unsigned char>(byte) >= 0x80)
            throw std::runtime_error("MSI cabinet entry name is not ASCII: " + text);
    }
    return text;
}
CabinetContext* context_of(PFDINOTIFICATION info) { return static_cast<CabinetContext*>(info->pv); }
// FNWRITE/FNREAD/FNSEEK/FNCLOSE receive no user context, so the per-cabinet trampolines carry it
// through a thread-local pointer while FDICopy runs.
thread_local CabinetContext* active_context = nullptr;
std::string windows_error(const char* action) {
    return std::string(action) + " (Windows error " + std::to_string(GetLastError()) + ")";
}
void* far_alloc(ULONG size) { return std::calloc(1,size); }
void far_free(void* memory) { std::free(memory); }
UINT far_read(INT_PTR handle, void* memory, UINT size) {
    auto* file = reinterpret_cast<OpenFile*>(handle);
    if (!file || file->closed || size == 0) return 0;
    DWORD read = 0;
    if (!ReadFile(file->value, memory, size, &read, nullptr)) {
        if (active_context) active_context->error = windows_error("Cannot read the MSI cabinet stream");
        return 0;
    }
    return read;
}
UINT far_write(INT_PTR handle, void* memory, UINT size) {
    auto* file = reinterpret_cast<OpenFile*>(handle);
    if (!file || file->closed) return 0;
    DWORD written = 0;
    if (!WriteFile(file->value, memory, size, &written, nullptr)) {
        if (active_context) active_context->error = windows_error("Cannot write an extracted MSI file");
        return 0;
    }
    file->written += written;
    return written;
}
int far_close(INT_PTR handle) {
    auto* file = reinterpret_cast<OpenFile*>(handle);
    if (!file || file->closed) return 0;
    const bool closed = CloseHandle(file->value) != 0;
    file->closed = true;
    if (!closed) {
        if (active_context) active_context->error = windows_error("Cannot close a cabinet handle");
        return -1;
    }
    return 0;
}
long far_seek(INT_PTR handle, long distance, int origin) {
    auto* file = reinterpret_cast<OpenFile*>(handle);
    if (!file || file->closed) return -1;
    const auto result = SetFilePointer(file->value, distance, nullptr, origin);
    if (result == INVALID_SET_FILE_POINTER) {
        if (active_context) active_context->error = windows_error("Cannot seek in the MSI cabinet stream");
        return -1;
    }
    return static_cast<long>(result);
}
// FDI asks for the cabinet through FNOPEN. Only the placeholder name is answered, and it is
// answered from the wide path Coop already created; any other cabinet request is a multi-volume
// reference this backend does not follow.
INT_PTR open_cabinet(CabinetContext& context, char* requested) {
    const std::string name = requested ? requested : "";
    const auto leaf = name.find_last_of("\\/");
    const std::string leaf_name = leaf == std::string::npos ? name : name.substr(leaf+1);
    if (lower(wide(leaf_name)) != lower(wide(cabinet_placeholder))) {
        context.error = "MSI cabinet references another cabinet file, which Coop does not follow: " + name;
        return -1;
    }
    auto file = std::make_unique<OpenFile>();
    file->value = CreateFileW(context.cabinet.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file->value == INVALID_HANDLE_VALUE) {
        context.error = "Cannot open the extracted MSI cabinet stream (Windows error " +
            std::to_string(GetLastError()) + ")";
        return -1;
    }
    const auto handle = reinterpret_cast<INT_PTR>(file.get());
    context.handles.push_back(std::move(file));
    return handle;
}
// fdintCOPY_FILE creates the target file through the same safe path preparation used by the
// archive backend and returns the handle FDI writes into.
INT_PTR copy_file(CabinetContext& context, PFDINOTIFICATION info) {
    const auto name = ascii_text(info->psz1);
    const auto found = context.by_key->find(lower(wide(name)));
    if (found == context.by_key->end())
        throw std::runtime_error("MSI cabinet entry " + name + " has no matching File table row");
    auto& file = (*context.files)[found->second];
    if (file.extracted) throw std::runtime_error("MSI cabinet stores the file " + utf8(file.key) + " more than once");
    auto target = std::make_unique<OpenFile>();
    const auto path = prepare_package_target(context.destination, file.relative);
    target->value = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (target->value == INVALID_HANDLE_VALUE)
        throw std::runtime_error("Cannot create extracted MSI file " + path_text(file.relative) +
            " (Windows error " + std::to_string(GetLastError()) + ")");
    target->target = true;
    target->file_index = found->second;
    const auto handle = reinterpret_cast<INT_PTR>(target.get());
    context.handles.push_back(std::move(target));
    return handle;
}
INT_PTR close_file(CabinetContext& context, PFDINOTIFICATION info) {
    auto* target = reinterpret_cast<OpenFile*>(info->hf);
    if (!target || !target->target) throw std::runtime_error("MSI cabinet reported an unknown target file");
    auto& file = (*context.files)[target->file_index];
    if (!target->closed) {
        const bool flushed = FlushFileBuffers(target->value) != 0;
        target->closed = true;
        if (!CloseHandle(target->value) || !flushed)
            throw std::runtime_error("Cannot close extracted MSI file " + path_text(file.relative));
    }
    if (file.size && target->written != file.size)
        throw std::runtime_error("MSI cabinet entry " + utf8(file.key) + " has " + std::to_string(target->written) +
            " bytes but the File table declares " + std::to_string(file.size));
    if (target->written > maximum_extracted_bytes || context.facts->bytes + target->written > maximum_extracted_bytes)
        throw std::runtime_error("MSI image expands beyond the supported size limit");
    file.extracted = true;
    context.facts->bytes += target->written;
    context.facts->cab_files += 1;
    return TRUE;
}
INT_PTR far_notify(FDINOTIFICATIONTYPE kind, PFDINOTIFICATION info) {
    auto* context = context_of(info);
    if (!context) return -1;
    try {
        switch (kind) {
        case fdintCABINET_INFO:
            return 0;
        case fdintENUMERATE:
            return 0;
        case fdintPARTIAL_FILE:
            context->error = "MSI cabinet is a partial (multi-part) cabinet: " + ascii_text(info->psz1);
            return -1;
        case fdintCOPY_FILE:
            return copy_file(*context, info);
        case fdintCLOSE_FILE_INFO:
            return close_file(*context, info);
        case fdintNEXT_CABINET:
            context->error = "MSI cabinet requires the next cabinet file, which Coop does not follow: " + ascii_text(info->psz1);
            return -1;
        }
        return 0;
    } catch (const std::exception& failure) {
        context->error = failure.what();
        return -1;
    }
}
INT_PTR far_notify_open(char* name, CabinetContext* context) {
    try {
        return open_cabinet(*context, name);
    } catch (const std::exception& failure) {
        context->error = failure.what();
        return -1;
    }
}
// The FDI callbacks have no user context of their own, so a thin per-cabinet set of trampolines
// carries the context through a thread-local pointer while FDICopy runs.
void* trampoline_alloc(ULONG size) { return far_alloc(size); }
void trampoline_free(void* memory) { far_free(memory); }
INT_PTR trampoline_open(char* name, int, int) {
    if (!active_context) return -1;
    return far_notify_open(name, active_context);
}
UINT trampoline_read(INT_PTR handle, void* memory, UINT size) { return far_read(handle, memory, size); }
UINT trampoline_write(INT_PTR handle, void* memory, UINT size) { return far_write(handle, memory, size); }
int trampoline_close(INT_PTR handle) { return far_close(handle); }
long trampoline_seek(INT_PTR handle, long distance, int origin) { return far_seek(handle, distance, origin); }
INT_PTR trampoline_notify(FDINOTIFICATIONTYPE kind, PFDINOTIFICATION info) { return far_notify(kind, info); }
// Expand one embedded cabinet through the Windows cabinet decompression API so multi-folder, MSZIP
// and LZX cabinets all work, and place every entry at the path the File table declares. Cabinet
// entry names are File table keys, not the installed file names.
void extract_cabinet(const fs::path& cabinet, const std::map<std::wstring,std::size_t>& by_key,
    std::vector<FileRow>& files, const fs::path& destination, ImageFacts& facts) {
    CabinetContext context;
    context.cabinet = cabinet;
    context.destination = destination;
    context.by_key = &by_key;
    context.files = &files;
    context.facts = &facts;
    ERF error{};
    HFDI fdi = FDICreate(trampoline_alloc, trampoline_free, trampoline_open, trampoline_read,
        trampoline_write, trampoline_close, trampoline_seek, cpuUNKNOWN, &error);
    if (!fdi)
        throw std::runtime_error("Cannot initialize the Windows cabinet decompression API (error " +
            std::to_string(error.erfOper) + ")");
    active_context = &context;
    std::string cabinet_name = cabinet_placeholder;
    std::string cabinet_path;
    const BOOL copied = FDICopy(fdi, cabinet_name.data(), cabinet_path.data(), 0, trampoline_notify, nullptr, &context);
    active_context = nullptr;
    FDIDestroy(fdi);
    if (!copied || !context.error.empty()) {
        for (auto& handle : context.handles)
            if (handle->value != INVALID_HANDLE_VALUE && !handle->closed) {
                handle->closed = true;
                CloseHandle(handle->value);
            }
        if (!context.error.empty()) throw std::runtime_error(context.error);
        throw std::runtime_error("Windows cabinet decompression failed for the MSI embedded cabinet");
    }
}
HANDLE create_image_file(const fs::path& destination, const fs::path& relative, fs::path& target) {
    target = prepare_package_target(destination, relative);
    const auto handle = CreateFileW(target.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (handle == INVALID_HANDLE_VALUE)
        throw std::runtime_error("Cannot create extracted MSI file " + path_text(relative) +
            " (Windows error " + std::to_string(GetLastError()) + ")");
    return handle;
}
void write_image_bytes(HANDLE handle, const fs::path& relative, const char* data, std::size_t size) {
    DWORD written = 0;
    if (!WriteFile(handle, data, static_cast<DWORD>(size), &written, nullptr) || written != static_cast<DWORD>(size)) {
        const auto error = GetLastError();
        throw std::runtime_error("Cannot write extracted MSI file " + path_text(relative) +
            " (Windows error " + std::to_string(error) + ")");
    }
}
void close_image_file(HANDLE handle, const fs::path& relative) {
    const bool flushed = FlushFileBuffers(handle) != 0;
    const bool closed = CloseHandle(handle) != 0;
    if (!flushed || !closed) throw std::runtime_error("Cannot close extracted MSI file " + path_text(relative));
}
// Read one binary stream from the MSI _Streams table. Uncompressed package files are stored there
// under their File table key instead of inside a cabinet. The same mechanism provides the embedded
// cabinet bytes that FDI then decompresses.
void copy_stream(MSIHANDLE database, const std::wstring& name, HANDLE handle) {
    MSIHANDLE raw_view = 0;
    UINT status = MsiDatabaseOpenViewW(database, L"SELECT `Data` FROM `_Streams` WHERE `Name` = ?", &raw_view);
    if (status != ERROR_SUCCESS) throw installer_error("Cannot query the MSI _Streams table", status);
    const Handle view(raw_view);
    const Handle parameter(MsiCreateRecord(1));
    if (!parameter.get()) throw std::runtime_error("Cannot allocate an MSI stream query record");
    status = MsiRecordSetStringW(parameter.get(), 1, name.c_str());
    if (status != ERROR_SUCCESS) throw installer_error("Cannot bind an MSI stream name", status);
    status = MsiViewExecute(view.get(), parameter.get());
    if (status != ERROR_SUCCESS) throw installer_error("Cannot execute the MSI _Streams query", status);
    MSIHANDLE raw_record = 0;
    status = MsiViewFetch(view.get(), &raw_record);
    if (status == ERROR_NO_MORE_ITEMS)
        throw std::runtime_error("MSI stream " + utf8(name) + " is not present in the _Streams table");
    if (status != ERROR_SUCCESS) throw installer_error("Cannot read the MSI _Streams row", status);
    const Handle record(raw_record);
    std::array<char, 65536> buffer{};
    for (;;) {
        DWORD read = static_cast<DWORD>(buffer.size());
        status = MsiRecordReadStream(record.get(), 1, buffer.data(), &read);
        if (status != ERROR_SUCCESS) throw installer_error("Cannot read the MSI stream for " + utf8(name), status);
        if (read == 0) break;
        write_image_bytes(handle, name, buffer.data(), read);
    }
}
void extract_stream_file(MSIHANDLE database, const std::wstring& name, const fs::path& destination,
    const fs::path& relative, std::uint64_t expected, ImageFacts& facts) {
    fs::path target;
    const auto handle = create_image_file(destination, relative, target);
    try {
        copy_stream(database, name, handle);
    } catch (...) {
        CloseHandle(handle);
        throw;
    }
    close_image_file(handle, relative);
    const auto actual = fs::file_size(target);
    if (expected && actual != expected)
        throw std::runtime_error("MSI stream for " + utf8(name) + " has " + std::to_string(actual) +
            " bytes but the File table declares " + std::to_string(expected));
    if (facts.bytes + actual > maximum_extracted_bytes) throw std::runtime_error("MSI image expands beyond the supported size limit");
    facts.bytes += actual;
    facts.stream_files += 1;
}
std::optional<fs::path> system_component(const wchar_t* name) {
    std::vector<wchar_t> directory(MAX_PATH + 1);
    for (;;) {
        const auto length = GetSystemDirectoryW(directory.data(), static_cast<UINT>(directory.size()));
        if (!length) return std::nullopt;
        if (length < directory.size()) break;
        directory.resize(static_cast<std::size_t>(length) + 1);
    }
    const auto candidate = fs::path(directory.data()) / name;
    if (fs::is_regular_file(candidate)) return candidate;
    return std::nullopt;
}
}
std::optional<fs::path> msi_database_api() { return system_component(L"msi.dll"); }
std::optional<fs::path> cabinet_api() { return system_component(L"cabinet.dll"); }
Json extract_msi_image(const fs::path& msi, const fs::path& destination, const fs::path& work_directory) {
    try {
        fs::create_directories(destination);
        fs::create_directories(work_directory);
        MSIHANDLE raw_database = 0;
        const auto status = MsiOpenDatabaseW(msi.c_str(), MSIDBOPEN_READONLY, &raw_database);
        if (status != ERROR_SUCCESS)
            throw installer_error("Cannot open the MSI database read-only: " + path_text(msi), status);
        const Handle database(raw_database);
        std::vector<DirectoryRow> directories;
        for (const auto& row : query(database.get(), L"SELECT `Directory`, `Directory_Parent`, `DefaultDir` FROM `Directory`", 3))
            directories.push_back({row.fields[0], row.fields[1], row.fields[2]});
        const auto paths = directory_paths(directories);
        const auto directory_path = [&](const std::wstring& name) -> fs::path {
            for (std::size_t position = 0; position < directories.size(); ++position)
                if (lower(directories[position].name) == lower(name)) return paths[position];
            throw std::runtime_error("MSI Component table names a missing directory " + utf8(name));
        };
        std::map<std::wstring, std::wstring> component_directories;
        for (const auto& row : query(database.get(), L"SELECT `Component`, `Directory_` FROM `Component`", 2)) {
            if (!component_directories.emplace(lower(row.fields[0]), row.fields[1]).second)
                throw std::runtime_error("MSI Component table repeats the component " + utf8(row.fields[0]));
        }
        std::vector<FileRow> files;
        std::map<std::wstring, std::size_t> by_key;
        std::uint64_t declared_bytes = 0;
        for (const auto& row : query(database.get(),
                L"SELECT `File`, `Component_`, `FileName`, `FileSize`, `Attributes`, `Sequence` FROM `File`", 6)) {
            if (files.size() >= maximum_archive_entries) throw std::runtime_error("MSI image has too many files");
            const auto component = component_directories.find(lower(row.fields[1]));
            if (component == component_directories.end())
                throw std::runtime_error("MSI File table names a missing component " + utf8(row.fields[1]) +
                    " for " + utf8(row.fields[0]));
            FileRow file;
            file.key = row.fields[0];
            file.file_name = target_name(row.fields[2]);
            file.size = number(row.fields[3]);
            file.attributes = static_cast<int>(number(row.fields[4]));
            file.sequence = static_cast<int>(number(row.fields[5]));
            declared_bytes += file.size;
            if (declared_bytes > maximum_extracted_bytes)
                throw std::runtime_error("MSI image declares more bytes than the supported limit");
            file.relative = directory_path(component->second) / path_component(file.file_name, "MSI file " + utf8(file.key));
            if (!by_key.emplace(lower(file.key), files.size()).second)
                throw std::runtime_error("MSI File table repeats the file key " + utf8(file.key));
            files.push_back(std::move(file));
        }
        std::vector<MediaRow> media;
        for (const auto& row : query(database.get(), L"SELECT `DiskId`, `Cabinet` FROM `Media`", 2))
            media.push_back({static_cast<int>(number(row.fields[0])), row.fields[1]});
        std::stable_sort(media.begin(), media.end(), [](const MediaRow& left, const MediaRow& right) {
            return left.disk < right.disk;
        });
        ImageFacts facts;
        std::set<std::wstring> extracted_cabinets;
        std::size_t cabinet_index = 0;
        for (const auto& item : media) {
            if (item.cabinet.empty()) continue;
            if (item.cabinet.front() != L'#')
                throw std::runtime_error("MSI " + path_text(msi) + " declares the external cabinet " + utf8(item.cabinet) +
                    "; Coop extracts only embedded cabinets and never runs msiexec.exe or downloads cabinets");
            const auto stream_name = item.cabinet.substr(1);
            if (!extracted_cabinets.insert(lower(stream_name)).second) continue;
            const auto cabinet = work_directory / (L"cabinet-" + std::to_wstring(cabinet_index++) + L".cab");
            const auto handle = CreateFileW(cabinet.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (handle == INVALID_HANDLE_VALUE)
                throw std::runtime_error("Cannot create a temporary cabinet file (Windows error " + std::to_string(GetLastError()) + ")");
            try {
                copy_stream(database.get(), stream_name, handle);
            } catch (...) {
                CloseHandle(handle);
                throw;
            }
            close_image_file(handle, cabinet.filename());
            extract_cabinet(cabinet, by_key, files, destination, facts);
            facts.cabinets.push_back(utf8(stream_name));
            std::error_code ignored;
            fs::remove(cabinet, ignored);
        }
        for (auto& file : files) {
            if (file.extracted) {
                facts.files += 1;
                continue;
            }
            const bool uncompressed = file.sequence == 0 || (file.attributes & file_attribute_noncompressed) != 0;
            if (!uncompressed)
                throw std::runtime_error("MSI file " + utf8(file.key) + " is declared in a cabinet but no embedded cabinet contains it");
            extract_stream_file(database.get(), file.key, destination, file.relative, file.size, facts);
            file.extracted = true;
            facts.files += 1;
        }
        const auto database_api = msi_database_api();
        const auto fdi_api = cabinet_api();
        return Json{
            {"mechanism", "read-only Windows Installer database plus the Windows cabinet decompression API"},
            {"database_api", database_api ? path_text(*database_api) : std::string{}},
            {"cabinet_api", fdi_api ? path_text(*fdi_api) : std::string{}},
            {"database_access", "read-only"},
            {"msiexec_started", false},
            {"administrative_install", false},
            {"elevation", "not requested; the image is written only inside the Coop transaction and version directory"},
            {"reboot", "not scheduled; Coop extracts an administrative image instead of installing the product"},
            {"machine_cache", "not written by Coop: no Windows Installer service call, no administrative install and no product registration"},
            {"directory_rows", directories.size()},
            {"cabinets", facts.cabinets},
            {"cabinet_files", facts.cab_files},
            {"uncompressed_streams", facts.stream_files},
            {"files", facts.files},
            {"bytes", facts.bytes}
        };
    } catch (...) {
        try { erase_tree(destination); } catch (...) { /* Preserve the original extraction failure. */ }
        throw;
    }
}
}
