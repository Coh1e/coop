#pragma once
#include <filesystem>
#include <optional>
#include <string>
#include <vector>

namespace coop {
namespace fs = std::filesystem;
struct Context {
    fs::path root;
    std::optional<fs::path> global_root;
    bool json_output = false;
};
std::string utf8(const std::wstring& value);
std::wstring wide(const std::string& value);
std::string path_text(const fs::path& path);
int query(const Context& context, const std::wstring& command, const std::vector<std::wstring>& args);
}
