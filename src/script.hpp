#pragma once
#include "package.hpp"
#include "data.hpp"
#include <optional>

namespace coop {
// Lifecycle hooks are trusted Manifest script text. Coop does not interpret, rewrite or whitelist
// that text: a real PowerShell host runs it with the same session Scoop uses. The session is built
// from the pinned Scoop compatibility library in assets/scoop-lib, so `ensure`, `info`, `warn`,
// `error`, `abort`, `success`, `appdir`, `env_add_path`, `env_set`, `Expand-*Archive`,
// `Get-EnvVar`, `Set-EnvVar`, `Invoke-ExternalCommand` and the rest are the upstream helpers rather
// than a reduced copy. Only host requirements are checked before execution; anything PowerShell
// accepts runs, and a legitimate edit to a script never turns into a capability refusal.
struct ScriptHostInfo {
    // The real PowerShell interpreter, if one is available.
    std::optional<fs::path> interpreter;
    // Directory holding the pinned Scoop compatibility library (core.ps1, install.ps1, …).
    std::optional<fs::path> library;
    // Pinned upstream version of that library, reported as provenance.
    std::string library_version;
    // First missing host requirement; empty when a hook can be started.
    std::string problem;
};
// Resolves the hook host without starting a process: never downloads, installs or writes anything.
ScriptHostInfo script_host();
const char* script_phase_name(ScriptPhase phase);
// Captured script output is arbitrary bytes. JSON records keep a UTF-8 safe representation of
// the tails while the raw bytes stay in the per-hook log files.
std::string script_json_text(const std::string& value);

struct ScriptRun {
    int exit_code = 0;
    fs::path interpreter;
    // Exact hook text handed to the host; kept as evidence of what ran.
    fs::path hook_path;
    // Generated host that loaded the Scoop library, bound the context and invoked the hook text.
    fs::path host_path;
    fs::path library;
    // Transaction-local copy of the Manifest bytes this hook session bound to $manifest.
    fs::path manifest_path;
    fs::path stdout_path;
    fs::path stderr_path;
    std::size_t stdout_bytes = 0;
    std::size_t stderr_bytes = 0;
    std::string stdout_tail;
    std::string stderr_tail;
};
// Runs one hook in a child PowerShell process. The host sets the Scoop context ($app, $bucket,
// $version, $architecture, $fname, $dir, $original_dir, $persist_dir, $bucketsdir, $global,
// $manifest, $purge for uninstall) and its working directory, then executes the hook text through
// Invoke-Command like Scoop's Invoke-HookScript. stdout and stderr are drained on separate threads
// into per-hook log files (every byte) while a bounded tail is kept for JSON records. A non-zero
// exit code is reported to the caller; the script is never retried and its external effects are
// never claimed as reversible.
ScriptRun run_package_script(const Context& context, const Package& package, std::size_t index,
    const fs::path& directory, const fs::path& original_directory, const fs::path& persist_directory,
    const fs::path& transaction, const std::string& command_name, bool purge,
    const fs::path& manifest_path);

// An installer/uninstaller program declared with installer.file/installer.args (or
// uninstaller.file/uninstaller.args) runs in the same real PowerShell host and pinned Scoop library
// that run hook scripts. The generated host calls Scoop's own Invoke-Installer with only the
// installer/uninstaller *script* property suppressed, because the IR plan carries that script as a
// separate hook operation. Everything else stays upstream behavior: the declared program must
// resolve inside $dir, $dir/$global/$version argument substitution, direct invocation of a .ps1
// program, non-zero propagation, and removal of the program after a successful run unless
// keep=true. The program itself is external code: its effects outside the managed package and
// persist roots are unknown, are not rolled back, and it is never re-run automatically.
struct InstallerRun {
    int exit_code = 0;
    fs::path interpreter;
    // Generated host that loaded the pinned Scoop library, bound the context and called
    // Invoke-Installer for the declared program.
    fs::path host_path;
    fs::path library;
    fs::path manifest_path;
    fs::path stdout_path;
    fs::path stderr_path;
    std::size_t stdout_bytes = 0;
    std::size_t stderr_bytes = 0;
    std::string stdout_tail;
    std::string stderr_tail;
};
InstallerRun run_installer_program(const Context& context, const Package& package, bool uninstall,
    std::size_t index, const fs::path& directory, const fs::path& original_directory,
    const fs::path& persist_directory, const fs::path& transaction, const std::string& command_name,
    bool purge, const fs::path& manifest_path);
}
