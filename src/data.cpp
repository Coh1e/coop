#include "data.hpp"
#include "package.hpp"
#include "native.hpp"
#include <atomic>
#include <windows.h>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <algorithm>
#include <cctype>
#include <cwctype>
#include <string>

namespace coop {
namespace {
bool extended_path(const std::wstring& value) {
    return value.starts_with(L"\\\\?\\") || value.starts_with(L"\\\\.\\");
}
// Windows accepts extended-length paths for the whole derived tree. The prefix is only added when
// the plain absolute root is long enough that apps/<package>/<version>/... would exceed MAX_PATH;
// shorter roots keep their familiar form in output and in Scoop script context.
std::wstring extended_form(const std::wstring& value) {
    if (extended_path(value)) return value;
    if (value.starts_with(L"\\\\")) return L"\\\\?\\UNC\\"+value.substr(2);
    if (value.size() >= 2 && value[1] == L':' ) return L"\\\\?\\"+value;
    return value;
}
std::wstring without_trailing_separator(std::wstring value) {
    while (value.size() > 1) {
        const auto last = value.back();
        if (last != L'\\' && last != L'/') break;
        // A drive root (C:\ or \\?\C:\) keeps its separator; everything else loses it.
        if (value[value.size()-2] == L':') break;
        value.pop_back();
    }
    return value;
}
std::wstring environment_value(const wchar_t* name) {
    const DWORD size = GetEnvironmentVariableW(name,nullptr,0);
    if (!size) return {};
    std::wstring value(size,L'\0');
    const DWORD written = GetEnvironmentVariableW(name,value.data(),size);
    if (!written || written >= size) return {};
    value.resize(written);
    return value;
}
// COOP_STATE_DIR may carry %ROOT%; the replacement is per invocation because one test process can
// drive several roots. Comparison is ordinal case-insensitive, like Windows environment names.
std::wstring expand_root_placeholder(std::wstring value, const std::wstring& root) {
    constexpr wchar_t marker[] = L"%ROOT%";
    constexpr std::size_t marker_length = 6;
    std::size_t position = 0;
    while (position + marker_length <= value.size()) {
        if (CompareStringOrdinal(value.c_str()+position,static_cast<int>(marker_length),marker,static_cast<int>(marker_length),TRUE) == CSTR_EQUAL) {
            value.replace(position,marker_length,root);
            position += root.size();
        } else {
            ++position;
        }
    }
    return value;
}
}
fs::path operating_path(const fs::path& path) {
    if (extended_path(path.wstring())) return path;
    if (!path.is_absolute()) return path;
    const auto text = path.wstring();
    if (text.size() >= 240) return fs::path(extended_form(text));
    return path;
}
fs::path normalized_root(const std::wstring& value) {
    if (value.empty() || std::all_of(value.begin(),value.end(),[](wchar_t character) { return std::iswspace(character) != 0; }))
        throw UsageError("Root path must not be empty");
    const auto text = fs::path(value).wstring();
    if (extended_path(text)) return fs::path(without_trailing_separator(text));
    std::error_code error;
    const auto absolute = fs::absolute(fs::path(text),error);
    if (error) throw std::runtime_error("Installation root path cannot be resolved: "+utf8(text));
    auto resolved = without_trailing_separator(absolute.lexically_normal().wstring());
    if (resolved.size() >= 240) resolved = extended_form(resolved);
    return fs::path(resolved);
}
std::string utf8(const std::wstring& value) {
    if (value.empty()) return {};
    const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
        static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    if (!size) throw std::runtime_error("Invalid Unicode text");
    std::string result(size, '\0');
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
        result.data(), size, nullptr, nullptr);
    return result;
}
std::wstring wide(const std::string& value) {
    if (value.empty()) return {};
    const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
        static_cast<int>(value.size()), nullptr, 0);
    if (!size) throw std::runtime_error("Invalid UTF-8 text");
    std::wstring result(size, L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
        result.data(), size);
    return result;
}
std::string path_text(const fs::path& path) { return utf8(path.wstring()); }
fs::path state_directory_for_root(const fs::path& root) {
    const auto requested = environment_value(L"COOP_STATE_DIR");
    if (!requested.empty()) {
        auto path = fs::path(expand_root_placeholder(requested,root.wstring()));
        if (!path.is_absolute()) path = root/path;
        return operating_path(path.lexically_normal());
    }
    const auto profile = environment_value(L"USERPROFILE");
    if (profile.empty())
        throw std::runtime_error("USERPROFILE is not set; set COOP_STATE_DIR to choose where Coop keeps its state");
    // One directory per root: its name plus eight hex digits of the SHA256 of the real root path.
    // The name is sanitised because a drive root has an empty filename and a colon is invalid.
    auto name = root.filename().wstring();
    if (name.empty()) name = root.root_name().wstring();
    const std::wstring invalid = L"<>:\"/\\|?*";
    for (auto& character : name)
        if (character < 32 || invalid.find(character) != std::wstring::npos) character = L'_';
    while (!name.empty() && (name.back() == L'.' || name.back() == L' ')) name.pop_back();
    if (name.empty()) name = L"root";
    if (name.size() > 64u) name.resize(64);
    const auto digest = sha256_text(path_text(root)).substr(0,8);
    return operating_path(fs::path(profile)/L".coop"/L"roots"/(name+L"-"+wide(digest)));
}
fs::path state_directory(const Context& context) { return state_directory_for_root(context.root); }
fs::path state_cache_directory(const Context& context) { return state_directory(context)/L"cache"; }
Json read_json(const fs::path& path) {
    std::error_code error;
    const auto size = fs::file_size(path, error);
    if (error) throw std::runtime_error("Cannot read " + path_text(path) + " (filesystem error " + std::to_string(error.value()) + ")");
    if (size > 16 * 1024 * 1024) throw std::runtime_error("JSON file exceeds 16 MiB limit");
    std::ifstream input(path, std::ios::binary);
    if (!input) throw std::runtime_error("Cannot read " + path_text(path));
    return Json::parse(input);
}
fs::path installed_record(const fs::path& directory, const std::wstring& kind) {
    const auto preferred = directory / (L"scoop-" + kind + L".json");
    return fs::exists(preferred) ? preferred : directory / (kind + L".json");
}
void validate_component(const std::string& value) {
    if (value.empty() || value == "." || value == ".." || value.back() == '.' || value.back() == ' ')
        throw std::runtime_error("Invalid path component");
    if (std::any_of(value.begin(), value.end(), [](unsigned char c) { return c < 32 || std::string("<>:\"/\\|?*").find(c) != std::string::npos; }))
        throw std::runtime_error("Unsafe path component");
    auto base = value.substr(0,value.find('.'));
    for (auto& c : base) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    if (base == "CON" || base == "PRN" || base == "AUX" || base == "NUL" ||
        (base.size() == 4 && (base.starts_with("COM") || base.starts_with("LPT")) && base[3] >= '0' && base[3] <= '9'))
        throw std::runtime_error("Reserved Windows path component");
}
RootLock::RootLock(const Context& context) : handle_(INVALID_HANDLE_VALUE) {
    state_ = state_directory(context);
    const DWORD attributes = GetFileAttributesW(state_.c_str());
    if (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_REPARSE_POINT))
        throw std::runtime_error("Coop state directory cannot be a reparse point");
    fs::create_directories(state_);
    handle_ = CreateFileW((state_/L"write.lock").c_str(), GENERIC_READ|GENERIC_WRITE, 0, nullptr,
        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL|FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (handle_ == INVALID_HANDLE_VALUE) throw std::runtime_error("Root is busy or write lock cannot be opened");
    FILE_ATTRIBUTE_TAG_INFO tag{};
    if (!GetFileInformationByHandleEx(handle_, FileAttributeTagInfo, &tag, sizeof(tag)) || (tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
        CloseHandle(handle_);
        handle_ = INVALID_HANDLE_VALUE;
        throw std::runtime_error("Unsafe root lock file");
    }
}
RootLock::~RootLock() {
    if (handle_ != INVALID_HANDLE_VALUE) CloseHandle(handle_);
    if (state_.empty()) return;
    // A finished write leaves no lock or empty transaction directory behind. A pending journal,
    // package record or test-fault file keeps the state directory in place.
    std::error_code error;
    fs::remove(state_/L"write.lock",error);
    fs::remove(state_/L"transactions",error);
    if (!fs::exists(state_/L"test-faults.json",error)) fs::remove(state_,error);
}
Json bucket_sources(const Context& context) {
    Json sources = Json::array();
    const auto registry = state_directory(context)/L"buckets.json";
    if (fs::exists(registry)) sources = read_json(registry);
    if (!sources.is_array()) throw std::runtime_error("Invalid bucket registry");
    const auto buckets = context.root/L"buckets";
    if (fs::exists(buckets)) for (const auto& bucket : fs::directory_iterator(buckets)) {
        if (!bucket.is_directory()) continue;
        const auto name = path_text(bucket.path().filename());
        if (std::any_of(sources.begin(),sources.end(),[&](const Json& source) {
            const auto registered = wide(source.at("name").get<std::string>());
            return CompareStringOrdinal(registered.c_str(),-1,bucket.path().filename().c_str(),-1,TRUE) == CSTR_EQUAL;
        })) continue;
        sources.push_back({{"name",name},{"kind","unmanaged"},{"path",path_text(bucket.path())},
            {"url",path_text(bucket.path())},{"synced_at",nullptr}});
    }
    return sources;
}
namespace {
std::atomic<std::uint64_t> g_durable_syncs{0};
}
std::uint64_t durable_syncs() { return g_durable_syncs.load(); }
void note_durable_sync() { ++g_durable_syncs; }
bool durable_flush(void* file) {
    if (!FlushFileBuffers(static_cast<HANDLE>(file))) return false;
    note_durable_sync();
    return true;
}
void write_json(const fs::path& path, const Json& value, bool compact, bool durable) {
    const auto bytes = (compact ? value.dump() : value.dump(2)) + "\n";
    fs::create_directories(path.parent_path());
    const auto temporary = fs::path(path.wstring()+L".tmp-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));
    HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) throw std::runtime_error("Cannot create temporary state file");
    DWORD written = 0;
    const bool success = WriteFile(file,bytes.data(),static_cast<DWORD>(bytes.size()),&written,nullptr) &&
        written == bytes.size() && (!durable || durable_flush(file));
    CloseHandle(file);
    if (!success) {
        DeleteFileW(temporary.c_str());
        throw std::runtime_error("Cannot write state file");
    }
    // Antivirus scanners and indexing services can hold a freshly written state file briefly.
    // Retry within a bounded window instead of failing an otherwise valid transaction.
    DWORD error = ERROR_SUCCESS;
    bool moved = false;
    for (int attempt = 0; attempt < 40; ++attempt) {
        if (MoveFileExW(temporary.c_str(),path.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)) { moved = true; break; }
        error = GetLastError();
        if (error != ERROR_SHARING_VIOLATION && error != ERROR_LOCK_VIOLATION && error != ERROR_ACCESS_DENIED) break;
        Sleep(50);
    }
    if (!moved) {
        DeleteFileW(temporary.c_str());
        throw std::runtime_error("Cannot commit state file (Windows error "+std::to_string(error)+")");
    }
}
void erase_tree(const fs::path& path) {
    const auto attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES) return;
    // Scoop marks persist junctions read-only on the link itself (attrib +R /L), and archives can
    // contain read-only files. Clear the bit before unlinking so retained version directories do
    // not look "in use" just because of their persistence links.
    if (attributes & FILE_ATTRIBUTE_READONLY)
        SetFileAttributesW(path.c_str(),attributes & ~FILE_ATTRIBUTE_READONLY);
    if (attributes & FILE_ATTRIBUTE_REPARSE_POINT) {
        if (attributes & FILE_ATTRIBUTE_DIRECTORY) {
            if (!RemoveDirectoryW(path.c_str())) throw std::runtime_error("Cannot unlink managed junction: "+path_text(path));
        } else if (!DeleteFileW(path.c_str())) throw std::runtime_error("Cannot unlink managed file: "+path_text(path));
        return;
    }
    if (attributes & FILE_ATTRIBUTE_DIRECTORY)
        for (const auto& entry : fs::directory_iterator(path)) erase_tree(entry.path());
    if (!fs::remove(path)) throw std::runtime_error("Cannot remove managed path: "+path_text(path));
}
namespace {
void copy_tree(const fs::path& source, const fs::path& destination) {
    const DWORD attributes = GetFileAttributesW(source.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES)
        throw std::runtime_error("Cannot copy a missing path: "+path_text(source));
    if (attributes & FILE_ATTRIBUTE_REPARSE_POINT) {
        fs::create_directories(destination.parent_path());
        if (attributes & FILE_ATTRIBUTE_DIRECTORY) {
            make_junction(destination,junction_target(source));
        } else {
            std::error_code error;
            const auto target = fs::read_symlink(source,error);
            if (error) throw std::runtime_error("Cannot read a link while moving state: "+path_text(source));
            fs::create_symlink(target,destination,error);
            if (error) throw std::runtime_error("Cannot recreate a link while moving state: "+path_text(destination));
        }
        return;
    }
    if (attributes & FILE_ATTRIBUTE_DIRECTORY) {
        fs::create_directories(destination);
        for (const auto& entry : fs::directory_iterator(source))
            copy_tree(entry.path(),destination/entry.path().filename());
        return;
    }
    fs::create_directories(destination.parent_path());
    if (!CopyFileW(source.c_str(),destination.c_str(),TRUE))
        throw std::runtime_error("Cannot copy state file (Windows error "+
            std::to_string(GetLastError())+"): "+path_text(source));
}
}
void move_tree(const fs::path& source, const fs::path& destination) {
    if (MoveFileExW(source.c_str(),destination.c_str(),MOVEFILE_WRITE_THROUGH)) return;
    const DWORD error = GetLastError();
    if (error != ERROR_NOT_SAME_DEVICE)
        throw std::runtime_error("Cannot move "+path_text(source)+" to "+path_text(destination)+
            " (Windows error "+std::to_string(error)+")");
    // State lives under %USERPROFILE% while a Scoop root can be on another volume. Publish and
    // cleanup must still work, so copy the tree and delete the source; a junction is rebuilt at the
    // destination instead of followed.
    try {
        copy_tree(source,destination);
    } catch (...) {
        std::error_code ignored;
        try { erase_tree(destination); } catch (...) { }
        throw;
    }
    erase_tree(source);
}
void migrate_legacy_state(const Context& context) {
    const auto destination = state_directory(context);
    const auto legacy = context.root/L".coop";
    const auto destination_text = path_text(destination);
    const auto legacy_text = path_text(legacy);
    const auto destination_wide = destination.wstring();
    const auto legacy_wide = legacy.wstring();
    if (CompareStringOrdinal(destination_wide.c_str(),-1,legacy_wide.c_str(),-1,TRUE) == CSTR_EQUAL) return;
    // A state directory inside the legacy tree would make the migration walk itself.
    if (destination_wide.size() > legacy_wide.size() &&
        CompareStringOrdinal(destination_wide.c_str(),static_cast<int>(legacy_wide.size()),legacy_wide.c_str(),-1,TRUE) == CSTR_EQUAL &&
        (destination_wide[legacy_wide.size()] == L'\\' || destination_wide[legacy_wide.size()] == L'/')) return;
    std::error_code error;
    if (!fs::is_directory(legacy,error) || error) return;
    try {
        fs::create_directories(destination,error);
        if (error) throw std::runtime_error("cannot create "+destination_text);
        for (const auto& entry : fs::directory_iterator(legacy)) {
            const auto name = entry.path().filename().wstring();
            if (CompareStringOrdinal(name.c_str(),-1,L"write.lock",-1,TRUE) == CSTR_EQUAL) continue;
            fs::path target = destination/name;
            // The old layout kept the search index (and bucket clone staging) at the top level;
            // the new one puts both in the cache subtree.
            if (CompareStringOrdinal(name.c_str(),-1,L"index",-1,TRUE) == CSTR_EQUAL)
                target = destination/L"cache"/L"index";
            else if (CompareStringOrdinal(name.c_str(),-1,L"staging",-1,TRUE) == CSTR_EQUAL)
                target = destination/L"cache"/L"staging";
            if (fs::exists(target)) continue;
            fs::create_directories(target.parent_path(),error);
            if (error) throw std::runtime_error("cannot create "+path_text(target.parent_path()));
            move_tree(entry.path(),target);
        }
        // Remove the old directory only when every entry moved; a skipped or failed entry keeps it.
        fs::remove(legacy,error);
    } catch (const std::exception& failure) {
        std::cerr << "coop: could not migrate the old state directory " << legacy_text << " to "
                  << destination_text << ": " << failure.what() << "; the old directory was kept\n";
    }
}
}
