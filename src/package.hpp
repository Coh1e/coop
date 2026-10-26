#pragma once
#include "data.hpp"
#include "ir.hpp"
#include <memory>
#include <optional>

namespace coop {
enum class DiagnosticKind { syntax, adapter, validation, environment, capability, verification };
struct Diagnostic { DiagnosticKind kind; std::string code; std::string message; };
enum class ArchiveKind { none, zip, seven_zip, tar, msi, inno_setup };
struct Artifact {
    std::string url;
    std::string filename;
    // The declared digest value paired with its algorithm. The IR remains authority for the
    // declaration; this projection only lets the legacy execution helpers read the same value.
    std::string digest;
    ir::DigestAlgorithm algorithm = ir::DigestAlgorithm::sha256;
    bool renamed = false;
    // The source declared an executable archive payload (Scoop's `#/name.7z` idiom). The backend
    // inspects the verified content: an NSIS installer uses the declared 7-Zip helper, everything
    // else stays with the native archive reader.
    bool installer_payload = false;
    ArchiveKind archive = ArchiveKind::none;
    fs::path extract_directory;
    fs::path extract_destination;
};
struct CommandExposure { fs::path target; std::string name; std::string arguments; };
struct ShortcutExposure { fs::path target; std::string name; std::string arguments; fs::path icon; };
struct Persistence { fs::path source; fs::path target; };
struct EnvironmentSetting { std::string name; std::string value; };
enum class ScriptPhase { before_install, installer, after_install, before_uninstall, uninstaller, after_uninstall };
struct ScriptOperation { ScriptPhase phase; std::string text; std::string declared_by; };
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
    // Normalized IR this record was projected from. Planning consumes it directly so the legacy
    // execution record cannot become a second source of package semantics.
    std::shared_ptr<const ir::Package> definition;
};
enum class Action { adopt, install, update, uninstall, reset };
enum class StepKind {
    download, verify, extract, script, installer, publish_current, commands,
    shortcuts, environment, persistence, commit_state, remove_commands,
    unlink_current, remove_environment, unlink_persistence, remove_version, adopt_state, uninstaller, remove_shortcuts
};
struct Step { StepKind kind; std::size_t index = 0; bool previous_package = false; std::string detail; };
struct FilePrecondition { fs::path path; std::string sha256; };
struct LocalFacts { fs::path current; fs::path directory; bool exists = false; };
enum class AdoptionEligibility { eligible, already_managed, unsupported, untested, inconsistent };
struct LegacyCommand { std::string name; FilePrecondition executable; FilePrecondition metadata; };
struct LegacyShortcut { std::string name; fs::path path; std::string sha256; };
struct AdoptionAssessment {
    AdoptionEligibility eligibility = AdoptionEligibility::untested;
    std::vector<LegacyCommand> commands;
    std::vector<LegacyShortcut> shortcuts;
    std::vector<Diagnostic> diagnostics;
};
struct Plan {
    Action action;
    Package package;
    std::optional<Package> previous;
    std::vector<Step> steps;
    std::vector<FilePrecondition> preconditions;
    std::vector<Diagnostic> diagnostics;
    bool execution_available = false;
    LocalFacts local;
    // A package that exists only in the system-level root stays read-only. A user-scope install
    // still runs in the current-user root; update/uninstall/reset/adopt are refused instead of
    // silently targeting the wrong scope.
    std::optional<fs::path> global_installation;
    std::optional<Package> update_candidate;
    std::optional<AdoptionAssessment> adoption;
    std::vector<std::string> blocking_dependents;
    std::vector<std::string> unverified_dependents;
    // Resolved dependency plans, in the order they must be executed. An installed dependency is
    // reused; an uninstalled one carries its own IR operation sequence and package record.
    std::vector<ir::DependencyPlan> dependencies;
    bool purge = false;
    // IR operations this plan was built from. Preview reports them verbatim and the execution
    // backend is migrated onto the same sequence instead of re-deriving package order.
    std::vector<ir::Step> ir_steps;
    // Scoop-created .cmd/.ps1/sh wrappers for this package's command names. They are removed with
    // the entries only when their content still points at apps/<package>/.
    std::vector<fs::path> scoop_entry_wrappers;
};
DiagnosticKind diagnostic_kind(ir::Layer layer);
std::string sha256_file(const fs::path& path);
// Native digest with the algorithm the Manifest declared. Unsupported or missing algorithms throw
// instead of silently falling back to SHA256.
std::string digest_file(const fs::path& path, ir::DigestAlgorithm algorithm);
std::string sha256_text(const std::string& value);
// Windows identity boundaries: names and paths are ordinal case-insensitive; existing paths are also
// compared by filesystem identity so junctions, short names and separator differences cannot split one package.
bool equal_name(const std::string& a, const std::string& b);
bool same_identity(const fs::path& a, const fs::path& b);
std::string dependency_package_name(const std::string& specified);
Package parse_package(const fs::path& path, const std::string& name, const std::string& bucket,
                      const std::string& architecture);
// Project an already normalized IR package into the legacy execution record. This is a field
// projection only; it does not read the Manifest or reinterpret source fields.
Package project_package(const ir::Package& definition);
Plan make_plan(const Context& context, Action action, const std::string& request, const std::string& architecture);
void recheck_plan(const Plan& plan);
int execute_plan(const Context& context, const Plan& plan);
Json execute_plan_result(const Context& context, const Plan& plan);
std::string execution_blocker(const Context& context, const Plan& plan);
std::string package_execution_blocker(const Context& context, const Package& package);
AdoptionAssessment assess_adoption(const Context& context, const Plan& plan);
Json commit_adoption_result(const Context& context, const Plan& plan);
bool recover_adoption(const Context& context, const Plan& plan, const fs::path& journal_path);
Json adoption_recovery_status(const Context& context, const fs::path& journal_path, bool execute);
// Recovery of a package transaction is only automatic when every journaled path is still
// owned by Coop and can be reverted without guessing. Scripts recorded by the journal are
// never re-run; their external effects remain unknown.
Json package_recovery_status(const Context& context, const fs::path& journal_path, bool execute);
// Query may read the last committed record moved into a transaction, but only from Coop's own
// transaction subtree and after the same path safety checks used by recovery.
bool recovery_record_path_allowed(const Context& context, const fs::path& path);
int package_command(const Context& context, const std::wstring& command, const std::vector<std::wstring>& args,
            const std::string& architecture);
}
