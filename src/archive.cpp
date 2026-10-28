#include "archive.hpp"
#include "data.hpp"
#include "exposure.hpp"
#include "inno.hpp"
#include "msi.hpp"
#include "nsis.hpp"
#include <windows.h>
#include <archive.h>
#include <archive_entry.h>
#include <array>
#include <cstdint>
#include <memory>
#include <optional>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

namespace coop {
namespace {
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
// Ordinal, case-insensitive ordering, matching how the same file compares prefixes elsewhere in this
// file: one comparison primitive for every "same path on Windows" question.
struct OrdinalLess {
    bool operator()(const std::wstring& left, const std::wstring& right) const {
        return CompareStringOrdinal(left.c_str(),-1,right.c_str(),-1,TRUE) == CSTR_LESS_THAN;
    }
};
// True when name is root itself or lies below it; relative receives the remainder. Component-wise
// and case-insensitive, so "bin/x2" is not treated as below "bin/x".
bool relative_below(const fs::path& name, const fs::path& root, fs::path& relative) {
    auto name_part = name.begin();
    for (auto root_part = root.begin(); root_part != root.end(); ++root_part, ++name_part) {
        if (name_part == name.end()) return false;
        const auto left = name_part->wstring();
        const auto right = root_part->wstring();
        if (CompareStringOrdinal(left.c_str(),-1,right.c_str(),-1,TRUE) != CSTR_EQUAL) return false;
    }
    relative.clear();
    for (; name_part != name.end(); ++name_part) relative /= *name_part;
    return true;
}
}
void extract_archive(const fs::path& archive_path, const fs::path& destination, const fs::path& extract_directory) {
    ensure_directory(destination);
    ArchivePtr source{archive_read_new()};
    if (!source) throw std::runtime_error("Cannot initialize native archive reader");
    // The tar family is handled by the same native reader for every compression Scoop exposes:
    // plain tar, gzip/tgz, xz/txz, lzma/tlz, bzip2/tbz and zstd/tzst. Each filter is linked into coop.exe;
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
    // A declared extract_dir that selects nothing must fail instead of publishing a version that only
    // looks installed. Counting selected *files* is what distinguishes "empty selection" from a real
    // payload: an archive that merely carries the named directories publishes nothing a user can run.
    std::size_t published_files = 0;
    // Two regular files can land on one target on disk (a/A.TXT and a/a.txt differ in the archive
    // and not in Windows), or a file can land where an earlier directory went. Overwriting silently
    // would leave a version whose contents depend on entry order, so that is a failure. Repeating a
    // directory entry is ordinary in tar streams and stays allowed.
    std::set<std::wstring,OrdinalLess> file_targets;
    std::set<std::wstring,OrdinalLess> directory_targets;
    // Only this call's own writes may be undone. The destination is the package staging directory,
    // which other artifacts of the same package may already have written into.
    std::vector<fs::path> created;
    try {
        for (;;) {
            archive_entry* raw = nullptr;
            const auto result = archive_read_next_header(source.get(),&raw);
            if (result == ARCHIVE_EOF) break;
            if (result != ARCHIVE_OK) throw std::runtime_error("Cannot read archive header: "+archive_error(source.get()));
            EntryPtr entry{archive_entry_clone(raw)};
            if (!entry) throw std::runtime_error("Cannot inspect archive entry");
            if (++entries > maximum_archive_entries) throw std::runtime_error("Archive has too many entries");
            if (archive_entry_symlink(entry.get()) || archive_entry_hardlink(entry.get()))
                throw std::runtime_error("Archive contains a link entry; links are not extracted");
            const auto name = safe_entry_path(entry.get());
            auto relative = name;
            if (!extract_directory.empty()) {
                if (!relative_below(name,extract_directory,relative) || relative.empty()) {
                    archive_read_data_skip(source.get());
                    continue;
                }
            }
            const auto type = archive_entry_filetype(entry.get());
            const auto target = destination/relative;
            const auto key = target.wstring();
            if (type == AE_IFREG) {
                if (file_targets.contains(key) || directory_targets.contains(key))
                    throw std::runtime_error("Archive entries collide at "+path_text(relative));
                file_targets.insert(key);
            } else if (type == AE_IFDIR) {
                if (file_targets.contains(key))
                    throw std::runtime_error("Archive entries collide at "+path_text(relative));
                directory_targets.insert(key);
            }
            // Recorded only when this call actually created the object: a directory an earlier artifact
            // already published is not ours to remove if the publication later fails.
            const auto existed = fs::exists(fs::symlink_status(target));
            // Ancestors that do not exist yet are this call's to create and to undo. The ones already
            // there belong to whoever published them, so they are never recorded.
            std::vector<fs::path> missing_parents;
            for (auto parent = target.parent_path();
                 parent != destination && parent.has_parent_path() &&
                 !fs::exists(fs::symlink_status(parent));
                 parent = parent.parent_path())
                missing_parents.push_back(parent);
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
            // Shallowest first, so the reverse walk in the failure path removes the deepest object
            // first and every directory is empty by the time it is reached.
            for (auto parent = missing_parents.rbegin(); parent != missing_parents.rend(); ++parent)
                created.push_back(*parent);
            if (!existed) created.push_back(target);
            if (type == AE_IFREG) ++published_files;
            archive_read_data_skip(source.get());
        }
        if (!extract_directory.empty() && published_files == 0)
            throw std::runtime_error("Archive does not contain the declared extract_dir: "+path_text(extract_directory));
    } catch (...) {
        // Undo this call's own writes only, deepest object first: the destination is the package
        // staging directory, which other artifacts of the same package may already have written into.
        // Every path here was created by this call, and removing a directory succeeds only while it
        // is empty, so nothing that predates this publication can be reached.
        while (!created.empty()) {
            try { fs::remove(created.back()); }
            catch (...) { /* Preserve the original archive failure. */ }
            created.pop_back();
        }
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
fs::path prepare_package_target(const fs::path& root, const fs::path& relative) {
    if (relative.empty() || relative.is_absolute() || relative.has_root_name() || relative.has_root_directory())
        throw std::runtime_error("Extracted entry has an unsafe path");
    const auto target = root/relative;
    ensure_parents(root,target);
    return target;
}
std::vector<ExternalTool> package_external_tools(const Context& context, const ir::Package& package) {
    std::vector<ExternalTool> tools;
    const auto database_api = msi_database_api();
    const auto fdi_api = cabinet_api();
    InnoHelper inno;
    bool inno_looked_up = false;
    NsisHelper nsis;
    bool nsis_looked_up = false, nsis_reported = false;
    for (const auto& artifact : package.downloads) {
        if (artifact.installer_payload && !nsis_reported) {
            if (!nsis_looked_up) { nsis = nsis_helper(context); nsis_looked_up = true; }
            nsis_reported = true;
            tools.push_back({"7-Zip (NSIS installer payloads)",
                "unpack the NSIS payload of "+artifact.filename+" with the same arguments as Scoop's Expand-7zipArchive after the verified content is identified as an NSIS installer",
                "separately installed 7-Zip software package in the selected root; Coop detects it, never downloads, installs or bundles it, and never substitutes a bundled unpacker",
                !nsis.path.empty(),!nsis.path.empty(),
                nsis.path.empty() ? nsis.problem :
                    "conditional: only a payload whose verified content carries the NSIS FirstHeader signature is unpacked with this helper, while ordinary 7z, ZIP and tar artifacts stay on the native archive reader; the vendor setup.exe is never executed, so its install directory, registry, service and uninstall-registration effects do not happen",
                nsis.path});
            continue;
        }
        if (artifact.format == ir::ArchiveFormat::inno_setup) {
            if (!inno_looked_up) { inno = inno_helper(context); inno_looked_up = true; }
            tools.push_back({"innounp (Inno Setup unpacker)",
                "unpack the Inno Setup payload of "+artifact.filename+" with the same arguments as Scoop's Expand-InnoArchive",
                "separately declared software dependency installed in the selected root; Coop detects it, never downloads or installs it, and never substitutes a bundled unpacker",
                !inno.path.empty(),!inno.path.empty(),
                inno.path.empty() ? inno.problem :
                    "extracts the vendor installer's files only: [Run], [Registry], service, shortcut and uninstall-registration effects are not executed, encrypted installers need a password Coop does not supply, and a non-zero helper exit fails before a version is published",
                inno.path});
            continue;
        }
        if (artifact.format != ir::ArchiveFormat::msi) continue;
        tools.push_back({"Windows Installer APIs","read-only MSI database access (msi.dll) and embedded cabinet decompression (cabinet.dll) for "+artifact.filename,
            "Windows system components; Coop never downloads or installs them and never runs msiexec.exe",
            database_api.has_value() && fdi_api.has_value(),database_api.has_value() && fdi_api.has_value(),
            "read-only database access only: no msiexec.exe process, no administrative installation or product registration, no elevation, no reboot and no %WINDIR%\\Installer machine-cache write; external, multi-part and vendor installer payloads are unsupported and fail with a named error",
            database_api.value_or(fs::path{})});
    }
    // Scoop's shim() runs .py entries through python and every other unrecognized target through
    // bash. Both are external hosts detected before an entry is published, never bundled by Coop.
    bool python_reported = false, bash_reported = false;
    for (const auto& command : package.entries) {
        const auto target = fs::path(wide(command.target));
        const auto kind = launcher_kind(target);
        if (kind == LauncherKind::python && !python_reported) {
            python_reported = true;
            const auto host = command_host_path(kind);
            tools.push_back({"Python (command-entry host)",
                "run the .py command entry "+command.target+" with python.exe, like Scoop's .py shim branch",
                "external program required by the package's declared entry; Coop detects it, never downloads, installs or bundles it",
                host.has_value(),host.has_value(),
                host ? "the entry is started by python.exe found on PATH" : command_host_problem(kind),
                host.value_or(fs::path{})});
        } else if (kind == LauncherKind::bash && !bash_reported) {
            bash_reported = true;
            const auto host = command_host_path(kind);
            tools.push_back({"bash (command-entry host)",
                "run the script command entry "+command.target+" through bash, like Scoop's else shim branch (which also uses cygpath or wslpath for the path)",
                "external program required by the package's declared entry; Coop detects it, never downloads, installs or bundles it",
                host.has_value(),host.has_value(),
                host ? "the entry is started by bash.exe found on PATH; the generated Scoop wrapper uses cygpath or wslpath at run time like Scoop" : command_host_problem(kind),
                host.value_or(fs::path{})});
        }
    }
    return tools;
}
}
