#pragma once
#include <filesystem>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace coop {
namespace fs = std::filesystem;
struct Context {
    fs::path root;
    std::optional<fs::path> global_root;
    bool json_output = false;
};
// Command-line misuse is reported separately from an operational failure so scripts can tell a
// rejected request (exit 2) from a package action that ran and failed (exit 1).
struct UsageError : std::runtime_error {
    explicit UsageError(const std::string& message) : std::runtime_error(message) {}
};
std::string utf8(const std::wstring& value);
std::wstring wide(const std::string& value);
std::string path_text(const fs::path& path);
// Resolve a root argument to the canonical Windows form used for every derived path: absolute,
// normalized, without a trailing separator, and extended-length (\\?\) when the plain MAX_PATH
// form would be too long for the derived apps/shims/cache tree. The returned path is the real
// filesystem identity; JSON exposes it verbatim.
fs::path normalized_root(const std::wstring& value);
// Keep an existing absolute path usable for long Windows paths. canonical()/weakly_canonical()
// return the plain spelling even when the input carried the extended-length prefix; derived paths
// such as <root>/apps/<package>/current/... would then hit MAX_PATH again. Short and relative paths
// are returned unchanged so output stays in the familiar form.
fs::path operating_path(const fs::path& path);
int query(const Context& context, const std::wstring& command, const std::vector<std::wstring>& args);
int bucket_command(const Context& context, const std::vector<std::wstring>& args);
}
