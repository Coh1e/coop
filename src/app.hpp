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
    // --timings prints the network/local split after a write command. The machine-readable record is
    // written either way, so a human and a harness see the same numbers.
    bool timings = false;
    // Write-command switches. They change how a plan is executed, never what the manifest means.
    bool no_cache = false;      // -k/--no-cache: ignore <root>/cache
    bool skip_hash = false;     // -s/--skip-hash-check: report a digest mismatch instead of failing
    bool independent = false;   // -i/--independent: do not plan the declared dependencies
    bool force = false;         // -f/--force: act even when the installed version already matches
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
// Names of the packages installed in the current-user root, sorted. `update *` uses it to expand
// the wildcard into the same list Scoop would iterate.
std::vector<std::string> installed_package_names(const Context& context);
int bucket_command(const Context& context, const std::vector<std::wstring>& args, bool quiet_report = false);
// `cache show|rm` and `download`: both work on <root>/cache, which Scoop shares.
int cache_command(const Context& context, const std::vector<std::wstring>& args);
int download_command(const Context& context, const std::vector<std::wstring>& args, const std::string& architecture);
// `hold`/`unhold` flip the `hold` flag in the install record Scoop itself reads.
int hold_command(const Context& context, const std::vector<std::wstring>& args, bool hold);
// `shim add|rm|list|info|alter` manages the shared <root>/shims entries.
int shim_command(const Context& context, const std::vector<std::wstring>& args);
bool package_is_held(const fs::path& version_directory);
// `config` and `alias` read and write the Scoop configuration file, which both clients share.
int config_command(const Context& context, const std::vector<std::wstring>& args);
std::string config_value(const std::string& key);
// `create` emits a manifest skeleton; `virustotal` looks the declared digest up on the service.
int create_command(const Context& context, const std::vector<std::wstring>& args);
int virustotal_command(const Context& context, const std::vector<std::wstring>& args);
int alias_command(const Context& context, const std::vector<std::wstring>& args);
int run_alias_script(const Context& context, const std::string& name, const std::vector<std::wstring>& arguments);
// `import` reads a Scoopfile, registers missing buckets and installs every declared app.
int import_command(const Context& context, const std::vector<std::wstring>& args, const std::string& architecture);
}
