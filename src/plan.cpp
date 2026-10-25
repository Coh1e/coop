#include "package.hpp"
#include "data.hpp"
#include <algorithm>
#include <iostream>
#include <stdexcept>
#include <windows.h>

namespace coop {
namespace {
bool equal_name(const std::string& a, const std::string& b) {
    const auto left = wide(a), right = wide(b);
    return CompareStringOrdinal(left.c_str(),-1,right.c_str(),-1,TRUE) == CSTR_EQUAL;
}
const char* action_name(Action action) {
    switch (action) {
    case Action::adopt: return "adopt";
    case Action::install: return "install";
    case Action::update: return "update";
    case Action::uninstall: return "uninstall";
    }
    return "unknown";
}
const char* step_name(StepKind kind) {
    switch (kind) {
    case StepKind::download: return "download";
    case StepKind::verify: return "verify-sha256";
    case StepKind::extract: return "extract";
    case StepKind::script: return "script";
    case StepKind::installer: return "installer";
    case StepKind::publish_current: return "publish-current";
    case StepKind::commands: return "commands";
    case StepKind::shortcuts: return "shortcuts";
    case StepKind::environment: return "environment";
    case StepKind::persistence: return "persistence";
    case StepKind::commit_state: return "commit-state";
    case StepKind::remove_commands: return "remove-commands";
    case StepKind::unlink_current: return "unlink-current";
    case StepKind::remove_environment: return "remove-environment";
    case StepKind::unlink_persistence: return "unlink-persistence";
    case StepKind::remove_version: return "remove-version";
    case StepKind::adopt_state: return "adopt-state";
    case StepKind::uninstaller: return "uninstaller";
    case StepKind::remove_shortcuts: return "remove-shortcuts";
    }
    return "unknown";
}
void add_scripts(Plan& plan, const Package& package, ScriptPhase phase, bool previous = false) {
    for (std::size_t i = 0; i < package.scripts.size(); ++i)
        if (package.scripts[i].phase == phase) plan.steps.push_back({StepKind::script,i,previous});
}
void add_remove(Plan& plan, const Package& package, bool previous, bool retain_version) {
    add_scripts(plan,package,ScriptPhase::before_uninstall,previous);
    if (package.uninstaller) plan.steps.push_back({StepKind::uninstaller,0,previous});
    add_scripts(plan,package,ScriptPhase::uninstaller,previous);
    plan.steps.push_back({StepKind::unlink_current,0,previous});
    if (!package.commands.empty()) plan.steps.push_back({StepKind::remove_commands,0,previous});
    if (!package.shortcuts.empty()) plan.steps.push_back({StepKind::remove_shortcuts,0,previous});
    if (!package.environment.empty() || !package.path_entries.empty()) plan.steps.push_back({StepKind::remove_environment,0,previous});
    if (!retain_version) {
        if (!package.persistence.empty()) plan.steps.push_back({StepKind::unlink_persistence,0,previous});
        plan.steps.push_back({StepKind::remove_version,0,previous});
    }
    add_scripts(plan,package,ScriptPhase::after_uninstall,previous);
}
void add_install(Plan& plan) {
    for (std::size_t i = 0; i < plan.package.artifacts.size(); ++i) {
        plan.steps.push_back({StepKind::download,i});
        plan.steps.push_back({StepKind::verify,i});
        if (plan.package.artifacts[i].archive != ArchiveKind::none) plan.steps.push_back({StepKind::extract,i});
    }
    if (plan.previous) add_remove(plan,*plan.previous,true,true);
    add_scripts(plan,plan.package,ScriptPhase::before_install);
    if (plan.package.installer) plan.steps.push_back({StepKind::installer});
    add_scripts(plan,plan.package,ScriptPhase::installer);
    plan.steps.push_back({StepKind::publish_current});
    if (!plan.package.commands.empty()) plan.steps.push_back({StepKind::commands});
    if (!plan.package.shortcuts.empty()) plan.steps.push_back({StepKind::shortcuts});
    if (!plan.package.environment.empty() || !plan.package.path_entries.empty()) plan.steps.push_back({StepKind::environment});
    if (!plan.package.persistence.empty()) plan.steps.push_back({StepKind::persistence});
    add_scripts(plan,plan.package,ScriptPhase::after_install);
    plan.steps.push_back({StepKind::commit_state});
}
Json package_json(const Package& package) {
    Json result = {{"name",package.name},{"bucket",package.bucket},{"version",package.version},{"architecture",package.architecture},
        {"manifest_path",path_text(package.manifest_path)},{"manifest_sha256",package.manifest_sha256},
        {"commands",Json::array()},{"shortcuts",Json::array()},{"persistence",Json::array()},
        {"environment",Json::array()},{"path_entries",Json::array()},{"scripts",Json::array()}};
    for (const auto& item : package.commands) result["commands"].push_back({{"target",path_text(item.target)},{"name",item.name},{"arguments",item.arguments}});
    for (const auto& item : package.shortcuts) result["shortcuts"].push_back({{"target",path_text(item.target)},{"name",item.name},{"arguments",item.arguments},{"icon",path_text(item.icon)}});
    for (const auto& item : package.persistence) result["persistence"].push_back({{"source",path_text(item.source)},{"target",path_text(item.target)}});
    for (const auto& item : package.environment) result["environment"].push_back({{"name",item.name},{"value",item.value}});
    for (const auto& item : package.path_entries) result["path_entries"].push_back(path_text(item));
    static const char* phases[] = {"pre_install","installer","post_install","pre_uninstall","uninstaller","post_uninstall"};
    for (const auto& item : package.scripts) result["scripts"].push_back({{"phase",phases[static_cast<int>(item.phase)]},{"text",item.text},{"side_effects","arbitrary trusted script; external effects cannot be predicted or universally rolled back"}});
    result["dependencies"] = package.dependencies;
    const auto process_json = [](const InstallerProcess& process) {
        return Json{{"file",path_text(process.file)},{"arguments",process.arguments},{"keep",process.keep},
            {"side_effects","external program; effects are unverified and cannot be universally rolled back"}};
    };
    result["installer"] = package.installer ? process_json(*package.installer) : Json(nullptr);
    result["uninstaller"] = package.uninstaller ? process_json(*package.uninstaller) : Json(nullptr);
    return result;
}
}
Plan make_plan(const Context& context, Action action, const std::string& request, const std::string& architecture) {
    Plan plan{action,{},std::nullopt,{},{},{},false,{},std::nullopt};
    auto name = request;
    std::string bucket, version;
    const auto at = name.find('@');
    if (at != std::string::npos) { version = name.substr(at+1); name.resize(at); validate_component(version); }
    const auto slash = name.find('/');
    if (slash != std::string::npos) { bucket = name.substr(0,slash); name.erase(0,slash+1); validate_component(bucket); }
    validate_component(name);
    plan.local.current = context.root/L"apps"/wide(name)/L"current";
    plan.local.exists = fs::is_directory(plan.local.current);
    if (plan.local.exists) plan.local.directory = fs::canonical(plan.local.current);
    const auto read_installed = [&]() {
        if (!plan.local.exists) throw std::runtime_error("No usable local current installation");
        const auto manifest = installed_record(plan.local.current,L"manifest");
        const auto install_path = installed_record(plan.local.current,L"install");
        const auto install = read_json(install_path);
        plan.preconditions.push_back({install_path,sha256_file(install_path)});
        auto package = parse_package(manifest,name,install.value("bucket",std::string{}),install.value("architecture",architecture.empty() ? std::string("64bit") : architecture));
        plan.preconditions.push_back({manifest,package.manifest_sha256});
        if (!bucket.empty() && !equal_name(bucket,package.bucket))
            plan.diagnostics.push_back({DiagnosticKind::environment,"installed-bucket-mismatch","Installed package has a different bucket"});
        return package;
    };
    auto target_architecture = architecture.empty() ? std::string("64bit") : architecture;
    if (action == Action::update) {
        plan.previous = read_installed();
        if (bucket.empty()) bucket = plan.previous->bucket;
        if (architecture.empty()) target_architecture = plan.previous->architecture;
        plan.diagnostics.insert(plan.diagnostics.end(),plan.previous->diagnostics.begin(),plan.previous->diagnostics.end());
    }
    if (action == Action::install || action == Action::update) {
        Json matches = Json::array();
        for (const auto& item : catalog(context))
            if (equal_name(item.at("name"),name) && (bucket.empty() || equal_name(item.at("bucket"),bucket))) matches.push_back(item);
        if (matches.size() != 1) throw std::runtime_error(matches.empty() ? "Package not found in local buckets" : "Ambiguous package; qualify it with its bucket");
        const auto& item = matches.front();
        plan.package = parse_package(fs::path(wide(item.at("path"))),item.at("name"),item.at("bucket"),target_architecture);
        if (!version.empty() && plan.package.version != version)
            plan.diagnostics.push_back({DiagnosticKind::environment,"version-unavailable","Requested version is absent locally; no URL will be guessed"});
        add_install(plan);
    } else {
        plan.package = read_installed();
        if (!version.empty() && version != plan.package.version)
            plan.diagnostics.push_back({DiagnosticKind::environment,"installed-version-mismatch","Requested version is not the current local installation"});
        if (action == Action::adopt) {
            plan.steps.push_back({StepKind::adopt_state});
            for (const auto& candidate : catalog(context)) {
                if (!equal_name(candidate.at("name"),name) || !equal_name(candidate.at("bucket"),plan.package.bucket)) continue;
                plan.update_candidate = parse_package(fs::path(wide(candidate.at("path"))),name,plan.package.bucket,plan.package.architecture);
                plan.preconditions.push_back({plan.update_candidate->manifest_path,plan.update_candidate->manifest_sha256});
                for (const auto& diagnostic : plan.update_candidate->diagnostics)
                    plan.diagnostics.push_back({diagnostic.kind,"future-update-"+diagnostic.code,diagnostic.message});
                break;
            }
        }
        else add_remove(plan,plan.package,false,false);
        plan.steps.push_back({StepKind::commit_state});
    }
    plan.preconditions.push_back({plan.package.manifest_path,plan.package.manifest_sha256});
    const auto registry = context.root/L".coop"/L"buckets.json";
    if (fs::exists(registry)) plan.preconditions.push_back({registry,sha256_file(registry)});
    plan.diagnostics.insert(plan.diagnostics.end(),plan.package.diagnostics.begin(),plan.package.diagnostics.end());
    return plan;
}
void recheck_plan(const Plan& plan) {
    for (const auto& input : plan.preconditions)
        if (input.sha256.empty() || sha256_file(input.path) != input.sha256)
            throw std::runtime_error("Plan input changed; generate a new plan");
    if (fs::is_directory(plan.local.current) != plan.local.exists ||
        (plan.local.exists && fs::canonical(plan.local.current) != plan.local.directory))
        throw std::runtime_error("Current installation changed; generate a new plan");
}
int preview(const Context& context, const std::wstring& command, const std::vector<std::wstring>& args, const std::string& architecture) {
    if (args.size() != 2 || args[1] != L"--dry-run") throw std::runtime_error("Use <package> --dry-run to preview; execution is not available yet");
    const auto action = command == L"install" ? Action::install : command == L"update" ? Action::update : command == L"adopt" ? Action::adopt : Action::uninstall;
    const auto plan = make_plan(context,action,utf8(args[0]),architecture);
    Json result = {{"action",action_name(action)},{"package",package_json(plan.package)},
        {"manifest_sha256",plan.package.manifest_sha256},{"execution_available",plan.execution_available},
        {"artifacts",Json::array()},{"operations",Json::array()},{"preconditions",Json::array()},{"diagnostics",Json::array()}};
    result["local_facts"] = {{"current",path_text(plan.local.current)},{"exists",plan.local.exists},{"current_directory",path_text(plan.local.directory)}};
    result["lifecycle_checks"] = {{"install","unverified"},{"update","unverified"},{"uninstall","unverified"}};
    if (action == Action::adopt && !plan.update_candidate) result["lifecycle_checks"]["update"] = "missing-local-manifest";
    if (plan.update_candidate) {
        result["update_candidate"] = package_json(*plan.update_candidate);
        if (!plan.update_candidate->diagnostics.empty()) result["lifecycle_checks"]["update"] = "known-unsupported-or-invalid";
    }
    if (!plan.package.diagnostics.empty()) {
        result["lifecycle_checks"]["install"] = "known-unsupported-or-invalid";
        result["lifecycle_checks"]["uninstall"] = "known-unsupported-or-invalid";
    }
    if (plan.previous) result["previous_package"] = package_json(*plan.previous);
    for (const auto& item : plan.package.artifacts) result["artifacts"].push_back({{"url",item.url},{"filename",item.filename},{"sha256",item.sha256},{"extract_dir",path_text(item.extract_directory)},{"extract_to",path_text(item.extract_destination)}});
    for (const auto& item : plan.steps) result["operations"].push_back({{"kind",step_name(item.kind)},{"index",item.index},{"previous_package",item.previous_package}});
    for (const auto& item : plan.preconditions) result["preconditions"].push_back({{"path",path_text(item.path)},{"sha256",item.sha256}});
    static const char* categories[] = {"syntax","adapter","ir","environment","capability","verification"};
    for (const auto& item : plan.diagnostics) result["diagnostics"].push_back({{"category",categories[static_cast<int>(item.kind)]},{"code",item.code},{"message",item.message}});
    result["diagnostics"].push_back({{"category","verification"},{"code","execution-unverified"},{"message","Lifecycle execution is not implemented or validated yet"}});
    if (context.json_output) std::cout << result.dump(2,' ',false,Json::error_handler_t::replace) << '\n';
    else std::cout << result.dump(2,' ',false,Json::error_handler_t::replace) << '\n';
    return plan.diagnostics.empty() ? 0 : 1;
}
}
