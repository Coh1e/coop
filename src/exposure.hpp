#pragma once
#include "package.hpp"
#include "data.hpp"
#include <optional>

namespace coop {
// Command entries are forwarded according to the target file type, matching the fixed
// Scoop shim behavior: EXE/COM run directly, BAT/CMD through cmd.exe, PS1 through
// PowerShell and JAR through the Java runtime. Other target types are not guessed.
enum class LauncherKind { direct, command_script, power_shell, java };
std::optional<LauncherKind> launcher_kind(const fs::path& target);
const char* launcher_text(LauncherKind kind);
std::string command_launcher_name(const fs::path& target);

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
std::string expand_package_value(const Context& context, const Package& package, const fs::path& base, const std::string& value);
// Scoop substitutes $dir, $original_dir and $persist_dir in bin/shortcut arguments before it
// writes the shim metadata or shortcut, so the same values must reach the shared files.
std::string expand_exposure_arguments(const Context& context, const std::string& package_name,
    const fs::path& base, const std::string& value);
Json expanded_environment(const Context& context, const Package& package, const fs::path& base);
Json expanded_path_entries(const Context& context, const Package& package, const fs::path& base);

Json exposure_plan_json(const Context& context, const Package& package, const fs::path& base);
// psmodule exposure in the preview: the shared modules junction and the user PSModulePath entry,
// stated the same way for the operation that creates it and the one that removes it.
Json ps_module_plan_json(const Context& context, const std::string& name, const fs::path& target, bool removal);
}
