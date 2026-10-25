#include "data.hpp"
#include <windows.h>
#include <fstream>
#include <stdexcept>
#include <algorithm>
#include <cctype>

namespace coop {
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
RootLock::RootLock(const fs::path& root) : handle_(INVALID_HANDLE_VALUE) {
    const auto state = root/L".coop";
    const DWORD attributes = GetFileAttributesW(state.c_str());
    if (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_REPARSE_POINT))
        throw std::runtime_error("Coop state directory cannot be a reparse point");
    fs::create_directories(state);
    handle_ = CreateFileW((state/L"write.lock").c_str(), GENERIC_READ|GENERIC_WRITE, 0, nullptr,
        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL|FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (handle_ == INVALID_HANDLE_VALUE) throw std::runtime_error("Root is busy or write lock cannot be opened");
    FILE_ATTRIBUTE_TAG_INFO tag{};
    if (!GetFileInformationByHandleEx(handle_, FileAttributeTagInfo, &tag, sizeof(tag)) || (tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
        CloseHandle(handle_);
        throw std::runtime_error("Unsafe root lock file");
    }
}
RootLock::~RootLock() { if (handle_ != INVALID_HANDLE_VALUE) CloseHandle(handle_); }
Json bucket_sources(const Context& context) {
    Json sources = Json::array();
    const auto registry = context.root/L".coop"/L"buckets.json";
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
void write_json(const fs::path& path, const Json& value) {
    const auto bytes = value.dump(2) + "\n";
    fs::create_directories(path.parent_path());
    const auto temporary = fs::path(path.wstring()+L".tmp-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));
    HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) throw std::runtime_error("Cannot create temporary state file");
    DWORD written = 0;
    const bool success = WriteFile(file,bytes.data(),static_cast<DWORD>(bytes.size()),&written,nullptr) &&
        written == bytes.size() && FlushFileBuffers(file);
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
}
