#pragma once
#include "package.hpp"
#include "data.hpp"
#include <optional>

namespace coop {
// Lifecycle hooks are trusted Manifest script text. Coop runs them in a real PowerShell host
// that already provides the Scoop context, but only after a static compatibility check confirms
// that the script stays inside the context, helpers and commands proven by the fixed sample
// corpus. Anything outside that boundary becomes a capability diagnostic, so adoption and
// execution are refused before any side effect instead of half-running a script.
struct ScriptReport {
    ScriptPhase phase = ScriptPhase::before_install;
    bool compatible = true;
    std::vector<std::string> commands;
    std::vector<std::string> helpers;
    std::vector<Diagnostic> diagnostics;
};
struct ScriptCapability {
    std::vector<ScriptReport> scripts;
    bool compatible() const;
    std::vector<std::string> messages() const;
};
// Static part of the capability check, used by preview, execution and adoption.
ScriptCapability check_package_scripts(const Package& package);
// Locates the PowerShell host used for hook scripts. COOP_POWERSHELL pins an explicit
// interpreter for isolated runs; otherwise pwsh.exe is preferred and the Windows PowerShell
// installed with the operating system is the fallback. No global installation is performed.
std::optional<fs::path> powershell_interpreter();
const char* script_phase_name(ScriptPhase phase);
// Captured script output is arbitrary bytes. JSON records keep a UTF-8 safe representation of
// the tails while the raw bytes stay in the per-hook log files.
std::string script_json_text(const std::string& value);

struct ScriptRun {
    int exit_code = 0;
    fs::path interpreter;
    fs::path hook_path;
    fs::path stdout_path;
    fs::path stderr_path;
    std::size_t stdout_bytes = 0;
    std::size_t stderr_bytes = 0;
    std::string stdout_tail;
    std::string stderr_tail;
};
// Runs one hook script in a child PowerShell process. stdout and stderr are drained on separate
// threads into the per-hook log files (every byte) while a bounded tail is kept for JSON records.
// A non-zero exit code is reported to the caller; the script is never retried automatically and
// its external effects are not claimed as reversible.
ScriptRun run_package_script(const Context& context, const Package& package, std::size_t index,
    const fs::path& directory, const fs::path& original_directory, const fs::path& persist_directory,
    const fs::path& transaction, const std::string& command_name);
}
