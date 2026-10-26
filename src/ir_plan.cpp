#include "ir.hpp"
#include <stdexcept>
#include <string>

// The planner turns validated IR plus the current installation facts into the operation sequence.
// Preview output and every execution backend consume this one sequence, and each step states the
// effect it has, so what a user reviews is what will be attempted.
namespace coop::ir {
const char* operation_name(Operation operation) {
    switch (operation) {
    case Operation::download: return "download";
    case Operation::verify: return "verify";
    case Operation::extract: return "extract";
    case Operation::hook: return "hook";
    case Operation::installer: return "installer";
    case Operation::publish_current: return "publish-current";
    case Operation::entries: return "entries";
    case Operation::shortcuts: return "shortcuts";
    case Operation::environment: return "environment";
    case Operation::persistence: return "persistence";
    case Operation::commit_state: return "commit-state";
    case Operation::remove_entries: return "remove-entries";
    case Operation::remove_shortcuts: return "remove-shortcuts";
    case Operation::remove_environment: return "remove-environment";
    case Operation::unlink_persistence: return "unlink-persistence";
    case Operation::unlink_current: return "unlink-current";
    case Operation::remove_version: return "remove-version";
    case Operation::adopt_state: return "adopt-state";
    }
    return "unknown";
}
namespace {
std::string count_text(std::size_t count, const char* singular, const char* plural) {
    return std::to_string(count)+" "+(count == 1 ? singular : plural);
}
void add_hooks(Plan& plan, const Package& package, HookStage stage, bool previous) {
    for (std::size_t index = 0; index < package.hooks.size(); ++index) {
        if (package.hooks[index].stage != stage) continue;
        plan.steps.push_back({Operation::hook,index,previous,
            "run the "+std::string(hook_stage_name(stage))+" hook with the real PowerShell host"
            + (previous ? " from the installed version" : "")});
    }
}
void add_removal(Plan& plan, const Package& package, bool previous, bool retain_version) {
    add_hooks(plan,package,HookStage::pre_uninstall,previous);
    if (package.uninstaller)
        plan.steps.push_back({Operation::installer,0,previous,"run the declared uninstaller program "+package.uninstaller->file});
    add_hooks(plan,package,HookStage::uninstaller,previous);
    plan.steps.push_back({Operation::unlink_current,0,previous,"unpublish current; the version directory stays"});
    if (!package.entries.empty())
        plan.steps.push_back({Operation::remove_entries,0,previous,"remove "+count_text(package.entries.size(),"command entry","command entries")});
    if (!package.shortcuts.empty())
        plan.steps.push_back({Operation::remove_shortcuts,0,previous,"remove "+count_text(package.shortcuts.size(),"Start Menu shortcut","Start Menu shortcuts")});
    if (!package.environment.empty())
        plan.steps.push_back({Operation::remove_environment,0,previous,"revert "+count_text(package.environment.size(),"declared environment entry","declared environment entries")+" whose ownership still matches"});
    if (!retain_version) {
        if (!package.persistence.empty())
            plan.steps.push_back({Operation::unlink_persistence,0,previous,"unlink "+count_text(package.persistence.size(),"persistence mapping","persistence mappings")+"; stored data is retained"});
        plan.steps.push_back({Operation::remove_version,0,previous,"remove the version directory"});
    }
    add_hooks(plan,package,HookStage::post_uninstall,previous);
}
void add_installation(Plan& plan) {
    const auto& package = plan.package;
    for (std::size_t index = 0; index < package.downloads.size(); ++index) {
        const auto& download = package.downloads[index];
        plan.steps.push_back({Operation::download,index,false,"download "+download.filename+
            (download.renamed ? " (renamed from "+download.url+")" : " from "+download.url)});
        plan.steps.push_back({Operation::verify,index,false,"verify "+download.filename+" with "+
            digest_algorithm_name(download.digest.algorithm)+" digest"});
        if (download.format != ArchiveFormat::file)
            plan.steps.push_back({Operation::extract,index,false,"extract "+download.filename+" as "+
                archive_format_name(download.format)});
    }
    if (plan.previous) add_removal(plan,*plan.previous,true,true);
    add_hooks(plan,package,HookStage::pre_install,false);
    if (package.installer)
        plan.steps.push_back({Operation::installer,0,false,"run the declared installer program "+package.installer->file});
    add_hooks(plan,package,HookStage::installer,false);
    plan.steps.push_back({Operation::publish_current,0,false,"publish current for version "+package.version});
    if (!package.entries.empty())
        plan.steps.push_back({Operation::entries,0,false,"create "+count_text(package.entries.size(),"command entry","command entries")});
    if (!package.shortcuts.empty())
        plan.steps.push_back({Operation::shortcuts,0,false,"create "+count_text(package.shortcuts.size(),"Start Menu shortcut","Start Menu shortcuts")});
    if (!package.environment.empty())
        plan.steps.push_back({Operation::environment,0,false,"apply "+count_text(package.environment.size(),"declared environment entry","declared environment entries")});
    if (!package.persistence.empty())
        plan.steps.push_back({Operation::persistence,0,false,"link "+count_text(package.persistence.size(),"persistence mapping","persistence mappings")});
    add_hooks(plan,package,HookStage::post_install,false);
    plan.steps.push_back({Operation::commit_state,0,false,"commit installation records"});
}
// A reset republishes a version directory that already exists locally. It performs the same
// user-visible exposure work as Scoop's reset (current link, persistence, entries, shortcuts,
// environment) but never downloads, extracts, or runs install/uninstall hooks or declared
// installer programs: those already ran when the version was installed, and re-running arbitrary
// external side effects is not safe.
void add_reset(Plan& plan) {
    if (!plan.previous) return;
    const auto& current = *plan.previous;
    const auto& retained = plan.package;
    plan.steps.push_back({Operation::unlink_current,0,true,"unpublish the current version; its version directory stays"});
    if (!current.entries.empty())
        plan.steps.push_back({Operation::remove_entries,0,true,"remove "+count_text(current.entries.size(),"command entry","command entries")+" of the replaced version"});
    if (!current.shortcuts.empty())
        plan.steps.push_back({Operation::remove_shortcuts,0,true,"remove "+count_text(current.shortcuts.size(),"Start Menu shortcut","Start Menu shortcuts")+" of the replaced version"});
    if (!current.environment.empty())
        plan.steps.push_back({Operation::remove_environment,0,true,"revert "+count_text(current.environment.size(),"declared environment entry","declared environment entries")+" of the replaced version whose ownership still matches"});
    plan.steps.push_back({Operation::publish_current,0,false,"publish current for the retained local version "+retained.version});
    if (!retained.persistence.empty())
        plan.steps.push_back({Operation::persistence,0,false,"reuse the retained version's declared persistence mappings; stored data is not rolled back"});
    if (!retained.entries.empty())
        plan.steps.push_back({Operation::entries,0,false,"create "+count_text(retained.entries.size(),"command entry","command entries")});
    if (!retained.shortcuts.empty())
        plan.steps.push_back({Operation::shortcuts,0,false,"create "+count_text(retained.shortcuts.size(),"Start Menu shortcut","Start Menu shortcuts")});
    if (!retained.environment.empty())
        plan.steps.push_back({Operation::environment,0,false,"apply "+count_text(retained.environment.size(),"declared environment entry","declared environment entries")});
    plan.steps.push_back({Operation::commit_state,0,false,"commit the reset installation record"});
}
}
Plan plan(Action action, const Package& package, const Package* previous, bool retain_previous_version) {
    Plan result;
    result.action = action;
    result.package = package;
    if (previous) result.previous = *previous;
    switch (action) {
    case Action::install:
    case Action::update:
        add_installation(result);
        break;
    case Action::uninstall:
        add_removal(result,package,false,retain_previous_version);
        result.steps.push_back({Operation::commit_state,0,false,"commit installation records"});
        break;
    case Action::adopt:
        result.steps.push_back({Operation::adopt_state,0,false,"record the existing installation as shared management state"});
        result.steps.push_back({Operation::commit_state,0,false,"commit installation records"});
        break;
    case Action::reset:
        if (!previous) throw std::runtime_error("A reset requires the currently installed package");
        add_reset(result);
        break;
    }
    return result;
}
}


