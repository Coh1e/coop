#pragma once
#include "package.hpp"
#include "data.hpp"
#include <optional>

namespace coop {
// Command entries are forwarded according to the target file type, matching the fixed
// Scoop shim behavior: EXE/COM run directly, BAT/CMD through cmd.exe, PS1 through
// PowerShell, JAR through the Java runtime, PY through Python and every other target
// through bash. Scoop has no "unknown" branch: its else branch is the bash host.
enum class LauncherKind { direct, command_script, power_shell, java, python, bash };
LauncherKind launcher_kind(const fs::path& target);
const char* launcher_text(LauncherKind kind);
std::string command_launcher_name(const fs::path& target);
// Scoop entries for .py and the bash else-branch are native .cmd/sh wrappers instead of a
// copied launcher executable. These host programs must exist before any entry is published.
std::optional<fs::path> command_host_path(LauncherKind kind);
std::string command_host_problem(LauncherKind kind);
// The exact file contents Scoop's shim() writes for each script branch. The .cmd/.ps1 files use
// CRLF and the shell wrapper uses LF with no trailing newline, like Out-UTF8File in Scoop.
// Coop always publishes these Scoop views beside its own launcher for BAT/CMD, PS1 and JAR targets,
// because Scoop's shortcut declarations can target them (for example mqtt-spy points a shortcut at
// shims/mqtt-spy.cmd) and because an alias declared for two shim families must keep both families
// on disk exactly like Scoop.
std::string scoop_command_cmd(LauncherKind kind, const fs::path& target, const std::string& arguments);
std::string scoop_command_shell(LauncherKind kind, const fs::path& target, const std::string& arguments);
// The .ps1 file of Scoop's power-shell branch; the .cmd and shell wrappers come from the two
// functions above.
std::string scoop_command_ps1(const fs::path& target, const std::string& arguments);

// Windows GUI targets are started without a console window by patching the copied
// console launcher's PE subsystem, like Scoop does for GUI shims.
bool is_gui_executable(const fs::path& path);
void mark_launcher_gui(const fs::path& launcher);

// Shortcuts live in the user's Start Menu "Scoop Apps" folder. An isolated directory can
// be selected with COOP_PROGRAMS_DIR for tests; the default user folder is used otherwise.
fs::path shortcut_directory(const Context& context);
fs::path shortcut_link_path(const Context& context, const std::string& name);
struct ShortcutIdentity { fs::path target; std::string arguments; fs::path icon; };
std::optional<ShortcutIdentity> read_shortcut(const fs::path& link);
void write_shortcut(const fs::path& link, const fs::path& target, const std::string& arguments, const fs::path& icon);

// Declared environment values are expanded against the package's current directory so the
// launchers keep working after an update switches the current junction.
std::string expand_package_value(const Context& context, const ir::Package& package, const fs::path& base, const std::string& value);
// Scoop substitutes $dir, $original_dir and $persist_dir in bin/shortcut arguments before it
// writes the shim metadata or shortcut, so the same values must reach the shared files.
std::string expand_exposure_arguments(const Context& context, const std::string& package_name,
    const fs::path& base, const std::string& value);
Json expanded_environment(const Context& context, const ir::Package& package, const fs::path& base);
Json expanded_path_entries(const Context& context, const ir::Package& package, const fs::path& base);

Json exposure_plan_json(const Context& context, const ir::Package& package, const fs::path& base);
// psmodule exposure in the preview: the shared modules junction and the user PSModulePath entry,
// stated the same way for the operation that creates it and the one that removes it.
Json ps_module_plan_json(const Context& context, const std::string& name, const fs::path& target, bool removal);
}
