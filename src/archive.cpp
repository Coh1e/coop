#include "archive.hpp"
#include "data.hpp"
#include <windows.h>
#include <archive.h>
#include <archive_entry.h>
#include <array>
#include <cstdint>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace coop {
namespace {
constexpr std::uint64_t maximum_extracted_bytes = 16ull * 1024 * 1024 * 1024;
constexpr std::uint64_t maximum_entries = 1000000;
struct ArchiveDeleter {
    void operator()(archive* value) const { if (value) archive_read_free(value); }
};
struct EntryDeleter {
    void operator()(archive_entry* value) const { if (value) archive_entry_free(value); }
};
using ArchivePtr = std::unique_ptr<archive, ArchiveDeleter>;
using EntryPtr = std::unique_ptr<archive_entry, EntryDeleter>;
std::string archive_error(archive* value) {
    const char* message = archive_error_string(value);
    return message ? message : "unknown archive error";
}
void require_ordinary_directory(const fs::path& path) {
    const auto attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES || !(attributes & FILE_ATTRIBUTE_DIRECTORY))
        throw std::runtime_error("Archive destination is not a directory");
    if (attributes & FILE_ATTRIBUTE_REPARSE_POINT)
        throw std::runtime_error("Archive destination contains a reparse point");
}
void ensure_directory(const fs::path& path) {
    if (!CreateDirectoryW(path.c_str(),nullptr)) {
        const auto error = GetLastError();
        if (error != ERROR_ALREADY_EXISTS) throw std::runtime_error("Cannot create extracted directory");
        require_ordinary_directory(path);
    }
}
void erase_tree(const fs::path& path) {
    const auto attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES) return;
    if (attributes & FILE_ATTRIBUTE_REPARSE_POINT) {
        if (attributes & FILE_ATTRIBUTE_DIRECTORY) RemoveDirectoryW(path.c_str());
        else DeleteFileW(path.c_str());
        return;
    }
    if (attributes & FILE_ATTRIBUTE_DIRECTORY) for (const auto& entry : fs::directory_iterator(path)) erase_tree(entry.path());
    if (!fs::remove(path)) throw std::runtime_error("Cannot clean extracted archive staging");
}
void ensure_parents(const fs::path& root, const fs::path& path) {
    const auto relative = path.lexically_relative(root);
    if (relative.empty() || relative.is_absolute()) throw std::runtime_error("Archive entry escapes its package destination");
    auto current = root;
    for (const auto& part : relative) {
        validate_component(path_text(part));
        current /= part;
        if (current == path) break;
        const auto attributes = GetFileAttributesW(current.c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES) {
            ensure_directory(current);
        } else {
            if (!(attributes & FILE_ATTRIBUTE_DIRECTORY)) throw std::runtime_error("Archive entry collides with an extracted file");
            if (attributes & FILE_ATTRIBUTE_REPARSE_POINT) throw std::runtime_error("Archive entry would follow a reparse point");
        }
    }
}
fs::path safe_entry_path(archive_entry* entry) {
    const wchar_t* wide_name = archive_entry_pathname_w(entry);
    fs::path name;
    if (wide_name) name = fs::path(wide_name);
    else {
        const char* utf8_name = archive_entry_pathname_utf8(entry);
        if (!utf8_name) utf8_name = archive_entry_pathname(entry);
        if (!utf8_name) throw std::runtime_error("Archive entry has no usable path");
        name = fs::path(wide(utf8_name));
    }
    if (name.empty() || name.is_absolute() || name.has_root_name() || name.has_root_directory())
        throw std::runtime_error("Archive entry has an unsafe path");
    auto text = name.native();
    while (!text.empty() && (text.back() == L'/' || text.back() == L'\\')) text.pop_back();
    if (text.empty()) throw std::runtime_error("Archive entry has an unsafe path");
    name = fs::path(text);
    for (const auto& part : name) {
        if (part == L".") continue;
        validate_component(path_text(part));
    }
    name = name.lexically_normal();
    if (name.empty() || name == L".") throw std::runtime_error("Archive entry has an unsafe path");
    return name;
}
void write_entry(archive* source, const fs::path& destination) {
    const auto handle = CreateFileW(destination.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
    if (handle == INVALID_HANDLE_VALUE) throw std::runtime_error("Cannot create extracted file (Windows error "+std::to_string(GetLastError())+")");
    std::array<char,65536> buffer{};
    bool success = true;
    for (;;) {
        const auto read = archive_read_data(source,buffer.data(),buffer.size());
        if (read < 0) { success = false; break; }
        if (read == 0) break;
        DWORD written = 0;
        if (!WriteFile(handle,buffer.data(),static_cast<DWORD>(read),&written,nullptr) || written != static_cast<DWORD>(read)) {
            success = false;
            break;
        }
    }
    if (!FlushFileBuffers(handle)) success = false;
    CloseHandle(handle);
    if (!success) {
        DeleteFileW(destination.c_str());
        throw std::runtime_error("Archive entry cannot be read: "+archive_error(source));
    }
}
}
void extract_archive(const fs::path& archive_path, const fs::path& destination) {
    ensure_directory(destination);
    ArchivePtr source{archive_read_new()};
    if (!source) throw std::runtime_error("Cannot initialize native archive reader");
    // The tar family is handled by the same native reader for every compression Scoop exposes:
    // plain tar, gzip/tgz, xz/txz, bzip2/tbz and zstd/tzst. Each filter is linked into coop.exe;
    // no external 7z.exe, tar.exe or bzip2.exe is started.
    if (archive_read_support_filter_none(source.get()) != ARCHIVE_OK ||
        archive_read_support_filter_gzip(source.get()) != ARCHIVE_OK ||
        archive_read_support_filter_xz(source.get()) != ARCHIVE_OK ||
        archive_read_support_filter_lzma(source.get()) != ARCHIVE_OK ||
        archive_read_support_filter_bzip2(source.get()) != ARCHIVE_OK ||
        archive_read_support_filter_zstd(source.get()) != ARCHIVE_OK ||
        archive_read_support_format_all(source.get()) != ARCHIVE_OK)
        throw std::runtime_error("Cannot initialize native archive formats");
    if (archive_read_open_filename_w(source.get(),archive_path.wstring().c_str(),64*1024) != ARCHIVE_OK)
        throw std::runtime_error("Cannot open archive: "+archive_error(source.get()));
    std::uint64_t entries = 0, total = 0;
    try {
        for (;;) {
            archive_entry* raw = nullptr;
            const auto result = archive_read_next_header(source.get(),&raw);
            if (result == ARCHIVE_EOF) break;
            if (result != ARCHIVE_OK) throw std::runtime_error("Cannot read archive header: "+archive_error(source.get()));
            EntryPtr entry{archive_entry_clone(raw)};
            if (!entry) throw std::runtime_error("Cannot inspect archive entry");
            if (++entries > maximum_entries) throw std::runtime_error("Archive has too many entries");
            if (archive_entry_symlink(entry.get()) || archive_entry_hardlink(entry.get()))
                throw std::runtime_error("Archive contains a link entry; links are not extracted");
            const auto name = safe_entry_path(entry.get());
            const auto type = archive_entry_filetype(entry.get());
            const auto target = destination/name;
            ensure_parents(destination,target);
            if (type == AE_IFDIR) {
                ensure_directory(target);
            } else if (type == AE_IFREG) {
                const auto size = archive_entry_size(entry.get());
                if (size < 0 || total + static_cast<std::uint64_t>(size) > maximum_extracted_bytes)
                    throw std::runtime_error("Archive expands beyond the supported size limit");
                total += static_cast<std::uint64_t>(size);
                write_entry(source.get(),target);
            } else {
                throw std::runtime_error("Archive contains an unsupported entry type");
            }
            archive_read_data_skip(source.get());
        }
    } catch (...) {
        try { erase_tree(destination); } catch (...) { /* Preserve the original archive failure. */ }
        throw;
    }
}
void merge_archive_tree(const fs::path& source, const fs::path& extract_directory, const fs::path& destination) {
    fs::path root = source;
    if (!extract_directory.empty()) {
        root = source/extract_directory;
        require_ordinary_directory(root);
    }
    ensure_directory(destination);
    for (const auto& entry : fs::recursive_directory_iterator(root)) {
        const auto relative = entry.path().lexically_relative(root);
        if (relative.empty() || relative.is_absolute()) throw std::runtime_error("Extracted path escapes its package destination");
        const auto target = destination/relative;
        ensure_parents(destination,target);
        const auto status = entry.symlink_status();
        if (fs::is_symlink(status)) throw std::runtime_error("Extracted tree contains a link");
        if (fs::is_directory(status)) {
            ensure_directory(target);
        } else if (fs::is_regular_file(status)) {
            if (fs::exists(target)) throw std::runtime_error("Archive entries collide at "+path_text(relative));
            ensure_parents(destination,target);
            if (!fs::copy_file(entry.path(),target,fs::copy_options::none))
                throw std::runtime_error("Cannot publish extracted file");
        } else {
            throw std::runtime_error("Extracted tree contains an unsupported entry type");
        }
    }
}
std::optional<fs::path> msi_installer() {
    wchar_t configured[32768]{};
    const auto configured_length = GetEnvironmentVariableW(L"COOP_MSIEXEC",configured,static_cast<DWORD>(std::size(configured)));
    if (configured_length && configured_length < std::size(configured)) {
        const fs::path candidate(configured);
        if (fs::is_regular_file(candidate)) return candidate;
        return std::nullopt;
    }
    std::vector<wchar_t> system_directory(32768);
    const auto system_length = GetSystemDirectoryW(system_directory.data(),static_cast<UINT>(system_directory.size()));
    if (system_length && system_length < system_directory.size()) {
        const fs::path candidate = fs::path(system_directory.data())/L"msiexec.exe";
        if (fs::is_regular_file(candidate)) return candidate;
    }
    wchar_t windows[32768]{};
    const auto windows_length = GetWindowsDirectoryW(windows,static_cast<UINT>(std::size(windows)));
    if (windows_length && windows_length < std::size(windows)) {
        const fs::path candidate = fs::path(windows)/L"System32"/L"msiexec.exe";
        if (fs::is_regular_file(candidate)) return candidate;
    }
    return std::nullopt;
}
std::vector<ExternalTool> package_external_tools(const Package& package) {
    std::vector<ExternalTool> tools;
    const auto installer = msi_installer();
    for (const auto& artifact : package.artifacts) {
        if (artifact.archive != ArchiveKind::msi) continue;
        tools.push_back({"msiexec.exe","MSI administrative extraction for "+artifact.filename,
            "availability detected per system; Coop never downloads or installs external tools automatically",
            installer.has_value(),false,
            "administrative extraction writes the Windows Installer machine cache under %WINDIR%\\Installer, outside the selected project root; blocked until an isolated extraction mechanism is approved",
            installer.value_or(fs::path{})});
    }
    return tools;
}
}
