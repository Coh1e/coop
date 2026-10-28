#pragma once
#include "data.hpp"
#include "ir.hpp"
#include <optional>

namespace coop {
// A file the plan depends on, bound by the plan builder and rechecked before the first write.
struct FilePrecondition { fs::path path; std::string sha256; };
struct LocalFacts { fs::path current; fs::path directory; bool exists = false; };
// The execution Plan is the only contract between planning and execution. It carries the
// normalized IR package, the single IR operation sequence the preview displayed, the dependency
// order and the local facts the builder bound. There is no second package record and no second
// operation list, so execution cannot re-derive package ordering or package semantics.
struct Plan {
    ir::Action action = ir::Action::install;
    ir::Package package;
    std::optional<ir::Package> previous;
    std::vector<ir::Step> steps;
    std::vector<FilePrecondition> preconditions;
    std::vector<ir::Diagnostic> diagnostics;
    LocalFacts local;
    // A package that exists only in the system-level root stays read-only. A user-scope install
    // still runs in the current-user root; update/uninstall/reset are refused instead of silently
    // targeting the wrong scope.
    std::optional<fs::path> global_installation;
    std::vector<std::string> blocking_dependents;
    std::vector<std::string> unverified_dependents;
    // Resolved dependency plans, in the order they must be executed. An installed dependency is
    // reused; an uninstalled one carries its own normalized package and IR operation sequence.
    std::vector<ir::DependencyPlan> dependencies;
    bool purge = false;
    // Installing the version that is already current is a no-op, not a failure. Scoop warns, names
    // the command that would change something, and exits 0 without touching the root; the plan keeps
    // that verdict here so preview, execution and the machine-readable result all agree.
    bool already_installed = false;
    // The executability verdict, computed once by the plan builder from the plan and the current
    // environment. Preview and every execution entry point read this value instead of re-running
    // a copy of the same judgement.
    std::string blocker;
    bool executable() const { return blocker.empty(); }
    // Scoop-created .cmd/.ps1/sh wrappers for this package's command names. They are removed with
    // the entries only when their content still points at apps/<package>/.
    std::vector<fs::path> scoop_entry_wrappers;
};
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
// Source adapter entry point used by planning and query: Scoop Manifest bytes -> validated IR.
ir::Package parse_package(const fs::path& path, const std::string& name, const std::string& bucket,
                          const std::string& architecture);
Plan make_plan(const Context& context, ir::Action action, const std::string& request, const std::string& architecture,
               bool purge = false);
void recheck_plan(const Plan& plan);
int execute_plan(const Context& context, const Plan& plan);
Json execute_plan_result(const Context& context, const Plan& plan);
// The one executability judgement. The plan builder stores its result in Plan::blocker; the same
// function is used for a standalone package (for example a planned dependency).
std::string execution_blocker(const Context& context, const Plan& plan);
// The announcements around a package block, shared by the single-command path and the batch path.
void announce_update_move(const Context& context, const Plan& plan);
// The one spelling of the install success sentence, used by every path that reports it.
void print_install_success(const std::string& name, const std::string& version);
void announce_success_line(const Context& context, const Plan& plan);
std::string capability_blocker(const Context& context, const ir::Package& package);
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
