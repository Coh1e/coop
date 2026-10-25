#include "data.hpp"
#include <windows.h>
#include <fstream>
#include <stdexcept>

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
}
