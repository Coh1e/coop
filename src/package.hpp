#pragma once
#include "app.hpp"
#include <optional>

namespace coop {
enum class DiagnosticKind { syntax, adapter, validation, environment, capability, verification };
struct Diagnostic { DiagnosticKind kind; std::string code; std::string message; };
enum class ArchiveKind { none, zip, seven_zip, tar, msi };
struct Artifact {
    std::string url;
    std::string filename;
    std::string sha256;
    ArchiveKind archive = ArchiveKind::none;
    fs::path extract_directory;
    fs::path extract_destination;
};
struct CommandExposure { fs::path target; std::string name; std::string arguments; };
struct ShortcutExposure { fs::path target; std::string name; std::string arguments; fs::path icon; };
struct Persistence { fs::path source; fs::path target; };
struct EnvironmentSetting { std::string name; std::string value; };
enum class ScriptPhase { before_install, installer, after_install, before_uninstall, uninstaller, after_uninstall };
struct ScriptOperation { ScriptPhase phase; std::string text; };
struct InstallerProcess { fs::path file; std::vector<std::string> arguments; bool keep = false; };
struct Package {
    std::string name;
    std::string bucket;
    std::string version;
    std::string architecture;
    fs::path manifest_path;
    std::string manifest_sha256;
    std::vector<Artifact> artifacts;
    std::vector<std::string> dependencies;
    std::vector<CommandExposure> commands;
    std::vector<ShortcutExposure> shortcuts;
    std::vector<Persistence> persistence;
    std::vector<fs::path> path_entries;
    std::vector<EnvironmentSetting> environment;
    std::vector<ScriptOperation> scripts;
    std::optional<InstallerProcess> installer;
    std::optional<InstallerProcess> uninstaller;
    std::vector<Diagnostic> diagnostics;
};
enum class Action { adopt, install, update, uninstall };
enum class StepKind {
    download, verify, extract, script, installer, publish_current, commands,
    shortcuts, environment, persistence, commit_state, remove_commands,
    unlink_current, remove_environment, unlink_persistence, remove_version, adopt_state, uninstaller, remove_shortcuts
};
struct Step { StepKind kind; std::size_t index = 0; bool previous_package = false; };
struct FilePrecondition { fs::path path; std::string sha256; };
struct LocalFacts { fs::path current; fs::path directory; bool exists = false; };
struct Plan {
    Action action;
    Package package;
    std::optional<Package> previous;
    std::vector<Step> steps;
    std::vector<FilePrecondition> preconditions;
    std::vector<Diagnostic> diagnostics;
    bool execution_available = false;
    LocalFacts local;
    std::optional<Package> update_candidate;
};
std::string sha256_file(const fs::path& path);
Package parse_package(const fs::path& path, const std::string& name, const std::string& bucket,
                      const std::string& architecture);
Plan make_plan(const Context& context, Action action, const std::string& request, const std::string& architecture);
void recheck_plan(const Plan& plan);
int execute_plan(const Context& context, const Plan& plan);
std::string execution_blocker(const Context& context, const Plan& plan);
int preview(const Context& context, const std::wstring& command, const std::vector<std::wstring>& args,
            const std::string& architecture);
}
