#include "package.hpp"
#include "data.hpp"
#include "persist.hpp"
#include "versions.hpp"
#include "exposure.hpp"
#include "script.hpp"
#include "shim.hpp"
#include "archive.hpp"
#include "inno.hpp"
#include "msi.hpp"
#include <algorithm>
#include <iostream>
#include <map>
#include <optional>
#include <set>
#include <stdexcept>
#include <windows.h>

namespace coop {
namespace {
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
    case StepKind::verify: return "verify";
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
const char* archive_name(ArchiveKind kind) {
    switch (kind) {
    case ArchiveKind::none: return "none";
    case ArchiveKind::zip: return "zip";
    case ArchiveKind::seven_zip: return "7z";
    case ArchiveKind::tar: return "tar";
    case ArchiveKind::msi: return "msi";
    case ArchiveKind::inno_setup: return "inno-setup";
    }
    return "unknown";
}
std::string trim_text(std::string value) {
    const auto first = value.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) return {};
    return value.substr(first,value.find_last_not_of(" \t\r\n")-first+1);
}
std::string join_text(const std::vector<std::string>& values, const std::string& separator) {
    std::string result;
    for (const auto& value : values) {
        if (!result.empty()) result += separator;
        result += value;
    }
    return result;
}
std::string item_text(const Json& item, const char* key) {
    return item.contains(key) && item.at(key).is_string() ? item.at(key).get<std::string>() : std::string{};
}
// Saved dependent manifests are read through the IR adapter, so reverse-dependency evidence uses
// the same normalized identity as forward dependency planning. Coop's own record is only a fallback
// when the shared manifest is missing or unreadable.
bool read_dependent_dependencies(const Context& context, const Json& item, std::vector<ir::Dependency>& dependencies, std::string& problem) {
    const auto name = item_text(item,"name");
    const auto scope = item_text(item,"scope");
    fs::path root = context.root;
    if (scope == "global") {
        if (!context.global_root) { problem = "Global root is unknown"; return false; }
        root = *context.global_root;
    }
    const auto current = root/L"apps"/wide(name)/L"current";
    try {
        const auto manifest = installed_record(current,L"manifest");
        const auto architecture = item_text(item,"architecture").empty() ? std::string("64bit") : item_text(item,"architecture");
        const auto definition = ir::adapt_manifest(manifest,name,item_text(item,"bucket"),architecture);
        for (const auto& diagnostic : definition.diagnostics)
            if (diagnostic.code == "manifest-json" || diagnostic.code == "manifest-shape") {
                problem = diagnostic.message;
                throw std::runtime_error(diagnostic.message);
            }
        dependencies = definition.dependencies;
        return true;
    } catch (const std::exception& error) { problem = error.what(); }
    if (scope == "user") {
        try {
            const auto record = read_json(context.root/L".coop"/L"packages"/(wide(name)+L".json"));
            if (record.contains("dependencies") && record.at("dependencies").is_array()) {
                std::vector<ir::Dependency> saved;
                for (const auto& entry : record.at("dependencies")) {
                    if (!entry.is_string()) throw std::runtime_error("Managed dependency record contains a non-string value");
                    ir::Dependency dependency;
                    dependency.source = entry.get<std::string>();
                    dependency.name = dependency_package_name(dependency.source);
                    saved.push_back(std::move(dependency));
                }
                dependencies = std::move(saved);
                return true;
            }
        } catch (const std::exception& error) { problem += "; managed record: "+std::string(error.what()); }
    }
    return false;
}
void collect_reverse_dependencies(const Context& context, Plan& plan) {
    std::set<std::string> blocking, unverified;
    for (const auto& item : installed_packages(context)) {
        const auto name = item_text(item,"name");
        const auto scope = item_text(item,"scope");
        if (name.empty()) continue;
        if (scope == "user" && equal_name(name,plan.package.name)) continue;
        fs::path root = context.root;
        if (scope == "global") {
            if (!context.global_root) continue;
            root = *context.global_root;
        }
        if (!fs::is_directory(root/L"apps"/wide(name)/L"current")) continue;
        std::vector<ir::Dependency> dependencies;
        std::string problem;
        if (!read_dependent_dependencies(context,item,dependencies,problem)) {
            unverified.insert(scope+"/"+name);
            continue;
        }
        for (const auto& dependency : dependencies) {
            if (!dependency.name.empty() && equal_name(dependency.name,plan.package.name)) {
                blocking.insert(name);
                break;
            }
        }
    }
    plan.blocking_dependents.assign(blocking.begin(),blocking.end());
    plan.unverified_dependents.assign(unverified.begin(),unverified.end());
    if (!plan.blocking_dependents.empty())
        plan.diagnostics.push_back({DiagnosticKind::verification,"blocked-by-dependents",
            "Installed packages still depend on this package: "+join_text(plan.blocking_dependents,", ")+"; uninstall is refused and no dependent is removed automatically"});
    if (!plan.unverified_dependents.empty())
        plan.diagnostics.push_back({DiagnosticKind::verification,"dependency-evidence-incomplete",
            "Saved dependency evidence cannot be read for: "+join_text(plan.unverified_dependents,", ")+"; missing evidence does not prove that no package depends on this one"});
}
// The IR planner resolves the package graph. This adapter supplies local catalog identity and
// normalized package IR; it does not decide order, cycles or source conflicts itself.
ir::DependencyResolution resolve_package_dependencies(const Context& context, const Package& package,
                                                      bool require_installed) {
    if (!package.definition) return {};
    const auto index = catalog(context);
    ir::DependencySource source;
    source.buckets = [index](const std::string& name) {
        std::vector<std::string> buckets;
        for (const auto& item : index)
            if (equal_name(item_text(item,"name"),name)) buckets.push_back(item_text(item,"bucket"));
        return buckets;
    };
    source.load = [index,architecture = package.architecture](const std::string& bucket, const std::string& name) {
        for (const auto& item : index)
            if (equal_name(item_text(item,"name"),name) && equal_name(item_text(item,"bucket"),bucket)) {
                auto definition = ir::adapt_manifest(fs::path(wide(item_text(item,"path"))),name,bucket,
                    architecture.empty() ? std::string("64bit") : architecture);
                ir::validate(definition);
                return definition;
            }
        throw std::runtime_error("Package not found in local buckets");
    };
    const ir::DependencyBlocker blocker = [&context](const ir::Package& definition) {
        return package_execution_blocker(context,project_package(definition));
    };
    return ir::resolve_dependencies(*package.definition,ir::read_installations(context.root),require_installed,
        source,blocker);
}
StepKind legacy_step(ir::Operation operation) {
    switch (operation) {
    case ir::Operation::download: return StepKind::download;
    case ir::Operation::verify: return StepKind::verify;
    case ir::Operation::extract: return StepKind::extract;
    case ir::Operation::hook: return StepKind::script;
    case ir::Operation::installer: return StepKind::installer;
    case ir::Operation::publish_current: return StepKind::publish_current;
    case ir::Operation::entries: return StepKind::commands;
    case ir::Operation::shortcuts: return StepKind::shortcuts;
    case ir::Operation::environment: return StepKind::environment;
    case ir::Operation::persistence: return StepKind::persistence;
    case ir::Operation::commit_state: return StepKind::commit_state;
    case ir::Operation::remove_entries: return StepKind::remove_commands;
    case ir::Operation::remove_shortcuts: return StepKind::remove_shortcuts;
    case ir::Operation::remove_environment: return StepKind::remove_environment;
    case ir::Operation::unlink_persistence: return StepKind::unlink_persistence;
    case ir::Operation::unlink_current: return StepKind::unlink_current;
    case ir::Operation::remove_version: return StepKind::remove_version;
    case ir::Operation::adopt_state: return StepKind::adopt_state;
    }
    return StepKind::commit_state;
}
// Package actions take their operation sequence from the IR planner only. Preview reports the very
// same steps, so it cannot describe a different order from the one the plan carries.
void append_ir_plan(Plan& plan, ir::Action action, bool retain_previous_version) {
    if (!plan.package.definition) return;
    const auto package_plan = ir::plan(action,*plan.package.definition,
        plan.previous && plan.previous->definition ? plan.previous->definition.get() : nullptr,retain_previous_version);
    for (const auto& step : package_plan.steps)
        plan.steps.push_back({legacy_step(step.operation),step.index,step.previous,step.effect});
    plan.ir_steps = package_plan.steps;
}
Json external_tools_json(const Context& context, const Package& package) {
    Json result = Json::array();
    for (const auto& tool : package_external_tools(context,package))
        result.push_back({{"name",tool.name},{"purpose",tool.purpose},{"policy",tool.policy},
            {"available",tool.available},{"enabled",tool.enabled},{"limitation",tool.limitation},
            {"path",path_text(tool.path)}});
    return result;
}
bool has_msi_artifact(const Package& package) {
    return std::any_of(package.artifacts.begin(),package.artifacts.end(),[](const Artifact& artifact) {
        return artifact.archive == ArchiveKind::msi;
    });
}
bool has_inno_artifact(const Package& package) {
    return std::any_of(package.artifacts.begin(),package.artifacts.end(),[](const Artifact& artifact) {
        return artifact.archive == ArchiveKind::inno_setup;
    });
}
// The permission and reboot facts are stated where the user reviews the plan, and they describe the
// mechanism Coop actually uses rather than the vendor installer's own behaviour.
Json msi_extraction_json() {
    const auto database_api = msi_database_api();
    const auto fdi_api = cabinet_api();
    return {{"mechanism","read-only Windows Installer database access plus the Windows cabinet decompression API"},
        {"database_api",database_api ? path_text(*database_api) : std::string{}},
        {"cabinet_api",fdi_api ? path_text(*fdi_api) : std::string{}},
        {"msiexec_started",false},
        {"administrative_install",false},
        {"elevation","not required for MSI image extraction; Coop writes only inside the selected root, and the read-only database view changes no system folder, registry, service or machine-wide state"},
        {"reboot","not required for MSI image extraction; an administrative image is extracted, so the product installer's reboot scheduling is not executed"},
        {"machine_cache","not written by the MSI image extraction: Coop opens the installer database read-only and never calls msiexec or registers a product"},
        {"layout","administrative image layout from the Directory, Component, File and Media tables with long target names, then the declared extract_dir/extract_to"},
        {"external_cabinets","unsupported: an MSI whose Media table names an external cabinet, or a multi-part cabinet, fails before any file is published"},
        {"differences","the administrative-install copy of the MSI file itself and empty directories that only carry shortcuts are not written"}};
}
// Inno Setup extraction is the one mechanism whose unpacker is a separately installed software
// dependency, so the plan states both the route and the helper's actual availability before any
// download or write happens.
Json inno_setup_json(const Context& context) {
    const auto helper = inno_helper(context);
    return {{"mechanism","the declared external innounp helper, started with Scoop's Expand-InnoArchive arguments"},
        {"helper",path_text(helper.path)},
        {"helper_available",!helper.path.empty()},
        {"helper_problem",helper.problem},
        {"helper_lookup","apps/innounp-unicode/current/innounp.exe then apps/innounp/current/innounp.exe under the selected root and the optional global root"},
        {"helper_policy","a separate software dependency of this package mechanism, not a Coop core dependency; Coop detects it and never downloads, installs or bundles it"},
        {"arguments","-x -d<destination> <setup.exe> -y -c<selection>, exactly as Scoop 0.6.0's Expand-InnoArchive"},
        {"selection","-c{app} when no extract_dir is declared, -c{app}\\<extract_dir> for a relative extract_dir, and the declared {path} when extract_dir starts with '{'"},
        {"installer_executed",false},
        {"elevation","not requested: innounp unpacks files into the selected root and the vendor installer never runs"},
        {"reboot","not required: no vendor installer process is started, so its reboot scheduling cannot run"},
        {"installer_effects","not executed: the vendor installer's [Run], [Registry], services, Start Menu entries and uninstall registration are outside this extraction"},
        {"layout","the files below the selected Inno directory, then the declared extract_dir/extract_to; file contents and timestamps are what innounp writes"},
        {"limitations","encrypted installers need a password Coop does not supply, and an Inno Setup version the installed innounp cannot read fails with a named non-zero error before a version is published"}};
}
Json package_json(const Context& context, const Package& package) {
    Json result = {{"name",package.name},{"bucket",package.bucket},{"version",package.version},{"architecture",package.architecture},
        {"manifest_path",path_text(package.manifest_path)},{"manifest_sha256",package.manifest_sha256},
        {"commands",Json::array()},{"shortcuts",Json::array()},{"persistence",Json::array()},
        {"environment",Json::array()},{"path_entries",Json::array()},{"scripts",Json::array()}};
    for (const auto& item : package.commands) result["commands"].push_back({{"target",path_text(item.target)},{"name",item.name},{"arguments",item.arguments},{"launcher",command_launcher_name(item.target)}});
    for (const auto& item : package.shortcuts) result["shortcuts"].push_back({{"target",path_text(item.target)},{"name",item.name},{"arguments",item.arguments},{"icon",path_text(item.icon)}});
    for (const auto& item : package.persistence) result["persistence"].push_back({{"source",path_text(item.source)},{"target",path_text(item.target)}});
    for (const auto& item : package.environment) result["environment"].push_back({{"name",item.name},{"value",item.value}});
    for (const auto& item : package.path_entries) result["path_entries"].push_back(path_text(item));
    const auto host = script_host();
    for (const auto& script : package.scripts) {
        Json entry = {{"phase",script_phase_name(script.phase)},{"text",script.text},
            {"host","real PowerShell child process"},
            {"declared_by",script.declared_by},
            {"side_effects","trusted Manifest script text; effects outside the managed package and persist roots cannot be predicted or rolled back, and a failed hook is never re-run automatically"}};
        result["scripts"].push_back(std::move(entry));
    }
    result["script_support"] = {{"phases",Json::array({"pre_install","installer","post_install","pre_uninstall","uninstaller","post_uninstall"})},
        {"context",Json::array({"$app","$bucket","$version","$architecture","$fname","$dir","$original_dir","$persist_dir","$bucketsdir","$scoopdir","$cachedir","$global","$manifest","$purge (uninstall only)"})},
        {"undefined_context",Json::array({"$cmd (Scoop 0.6.0 never defines it, so `if ($cmd -eq 'uninstall')` blocks behave identically)"})},
        {"host","real PowerShell child process that loads the pinned Scoop compatibility library; no embedded interpreter and no script-text whitelist"},
        {"working_directory","the hook child inherits the invoking Coop process directory, like Scoop's in-process hooks; scripts must address the package through $dir"},
        {"library_version",host.library_version},
        {"library_path",host.library ? path_text(*host.library) : std::string{}},
        {"interpreter",host.interpreter ? path_text(*host.interpreter) : std::string{}},
        {"problem",host.problem}};
    result["external_tools"] = external_tools_json(context,package);
    if (has_msi_artifact(package)) result["msi_extraction"] = msi_extraction_json();
    if (has_inno_artifact(package)) result["inno_setup"] = inno_setup_json(context);
    result["dependencies"] = package.dependencies;
    // Installer/uninstaller programs run through the same real PowerShell host and pinned Scoop
    // library as hook scripts, calling upstream Invoke-Installer. The preview therefore names the
    // declared program, its substitution context, what happens to the program file, and which
    // effects cannot be recovered.
    const auto process_json = [](const InstallerProcess& process) {
        return Json{{"file",path_text(process.file)},{"arguments",process.arguments},{"keep",process.keep},
            {"host","real PowerShell host that loads the pinned Scoop compatibility library and calls upstream Invoke-Installer with the installer/uninstaller hook script suppressed"},
            {"arguments_context",Json::array({"$dir","$global","$version"})},
            {"program_removal",process.keep ?
                "kept in the version directory after the run (keep=true)" :
                "removed after a successful run, matching Scoop's default"},
            {"side_effects","external program; effects outside the managed package and persist roots cannot be predicted or rolled back, and the program is never re-run automatically"}};
    };
    result["installer"] = package.installer ? process_json(*package.installer) : Json(nullptr);
    result["uninstaller"] = package.uninstaller ? process_json(*package.uninstaller) : Json(nullptr);
    return result;
}
// Preview reports the same expanded bin/shortcut arguments that execution writes into the shared
// launcher metadata and shortcut, so a displayed plan cannot describe raw Scoop variables.
void expand_package_arguments(const Context& context, const std::string& name, Json& package, const fs::path& base) {
    if (package.contains("commands") && package.at("commands").is_array())
        for (auto& item : package.at("commands"))
            if (item.is_object() && item.contains("arguments") && item.at("arguments").is_string())
                item["arguments"] = expand_exposure_arguments(context,name,base,item.at("arguments").get<std::string>());
    if (package.contains("shortcuts") && package.at("shortcuts").is_array())
        for (auto& item : package.at("shortcuts"))
            if (item.is_object() && item.contains("arguments") && item.at("arguments").is_string())
                item["arguments"] = expand_exposure_arguments(context,name,base,item.at("arguments").get<std::string>());
}
}
bool equal_name(const std::string& a, const std::string& b) {
    const auto left = wide(a), right = wide(b);
    return CompareStringOrdinal(left.c_str(),-1,right.c_str(),-1,TRUE) == CSTR_EQUAL;
}
bool same_identity(const fs::path& a, const fs::path& b) {
    if (equal_name(path_text(a),path_text(b))) return true;
    std::error_code error;
    const bool equivalent = fs::equivalent(a,b,error);
    return !error && equivalent;
}
std::string dependency_package_name(const std::string& specified) {
    auto value = trim_text(specified);
    if (const auto at = value.find('@'); at != std::string::npos) value.resize(at);
    if (const auto slash = value.find('/'); slash != std::string::npos) value.erase(0,slash+1);
    return value;
}
Plan make_plan(const Context& context, Action action, const std::string& request, const std::string& architecture) {
    Plan plan;
    plan.action = action;
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
        if (action == Action::update && plan.previous && !same_persistence(*plan.previous,plan.package))
            plan.diagnostics.push_back({DiagnosticKind::verification,"persist-change-unverified",
                "Persist mapping differs from the installed version; data migration is not verified, so the update is refused"});
    } else {
        plan.package = read_installed();
        if (!version.empty() && version != plan.package.version)
            plan.diagnostics.push_back({DiagnosticKind::environment,"installed-version-mismatch","Requested version is not the current local installation"});
        if (action == Action::adopt) {
            for (const auto& candidate : catalog(context)) {
                if (!equal_name(candidate.at("name"),name) || !equal_name(candidate.at("bucket"),plan.package.bucket)) continue;
                plan.update_candidate = parse_package(fs::path(wide(candidate.at("path"))),name,plan.package.bucket,plan.package.architecture);
                plan.preconditions.push_back({plan.update_candidate->manifest_path,plan.update_candidate->manifest_sha256});
                for (const auto& diagnostic : plan.update_candidate->diagnostics)
                    plan.diagnostics.push_back({diagnostic.kind,"future-update-"+diagnostic.code,diagnostic.message});
                break;
            }
        }
    }
    if (action == Action::install || action == Action::update || action == Action::adopt) {
        // The IR planner resolves the declared dependency graph once. The plan carries the ordered
        // result, so preview, execution and the saved evidence cannot disagree about it.
        auto resolution = resolve_package_dependencies(context,plan.package,action != Action::install);
        plan.dependencies = std::move(resolution.dependencies);
        for (const auto& diagnostic : resolution.diagnostics)
            plan.diagnostics.push_back({diagnostic_kind(diagnostic.layer),diagnostic.code,diagnostic.message});
        for (const auto& dependency : plan.dependencies) {
            if (dependency.installed) continue;
            plan.preconditions.push_back({fs::path(wide(dependency.package.manifest_path)),dependency.package.manifest_digest});
            // A dependency whose own IR has unresolved problems must not make the root plan look
            // executable. Execution refuses that dependency's plan, so preview reports the same
            // diagnostics at the parent level.
            for (const auto& diagnostic : dependency.diagnostics)
                plan.diagnostics.push_back({diagnostic_kind(diagnostic.layer),diagnostic.code,diagnostic.message});
        }
    }
    if (action == Action::install) append_ir_plan(plan,ir::Action::install,true);
    else if (action == Action::update) append_ir_plan(plan,ir::Action::update,true);
    else if (action == Action::uninstall) append_ir_plan(plan,ir::Action::uninstall,false);
    else if (action == Action::adopt) append_ir_plan(plan,ir::Action::adopt,false);
    if (action == Action::update || action == Action::uninstall) {
        const auto& installed_facts = action == Action::update && plan.previous ? *plan.previous : plan.package;
        std::vector<std::string> names;
        for (const auto& command : installed_facts.commands) names.push_back(command.name);
        plan.scoop_entry_wrappers = scoop_entry_wrappers(context,installed_facts.name,names);
        for (const auto& wrapper : plan.scoop_entry_wrappers)
            plan.preconditions.push_back({wrapper,sha256_file(wrapper)});
    }
    plan.preconditions.push_back({plan.package.manifest_path,plan.package.manifest_sha256});
    const auto registry = context.root/L".coop"/L"buckets.json";
    if (fs::exists(registry)) plan.preconditions.push_back({registry,sha256_file(registry)});
    plan.diagnostics.insert(plan.diagnostics.end(),plan.package.diagnostics.begin(),plan.package.diagnostics.end());
    if (action == Action::adopt) {
        plan.adoption = assess_adoption(context,plan);
        plan.diagnostics.insert(plan.diagnostics.end(),plan.adoption->diagnostics.begin(),plan.adoption->diagnostics.end());
        if (plan.adoption->eligibility == AdoptionEligibility::eligible) {
            // Plan preconditions compare raw file bytes with SHA256; the artifact's declared digest
            // algorithm is separate evidence and may be SHA512, SHA1 or MD5.
            plan.preconditions.push_back({plan.local.directory/wide(plan.package.artifacts.front().filename),
                sha256_file(plan.local.directory/wide(plan.package.artifacts.front().filename))});
            for (const auto& command : plan.adoption->commands) {
                plan.preconditions.push_back(command.executable);
                plan.preconditions.push_back(command.metadata);
            }
            for (const auto& shortcut : plan.adoption->shortcuts) plan.preconditions.push_back({shortcut.path,shortcut.sha256});
        }
    }
    if (action == Action::uninstall) {
        for (const auto& item : installed_packages(context)) {
            const auto dependent_name = item_text(item,"name");
            const auto scope = item_text(item,"scope");
            if (dependent_name.empty() || (scope == "user" && equal_name(dependent_name,plan.package.name))) continue;
            fs::path root = context.root;
            if (scope == "global" && context.global_root) root = *context.global_root;
            const auto current = root/L"apps"/wide(dependent_name)/L"current";
            const auto manifest = installed_record(current,L"manifest");
            if (fs::is_regular_file(manifest)) plan.preconditions.push_back({manifest,sha256_file(manifest)});
            if (scope == "user") {
                const auto record = context.root/L".coop"/L"packages"/(wide(dependent_name)+L".json");
                if (fs::is_regular_file(record)) plan.preconditions.push_back({record,sha256_file(record)});
            }
        }
        collect_reverse_dependencies(context,plan);
    }
    plan.execution_available = execution_blocker(context,plan).empty();
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
static Json describe_plan(const Context& context, const Plan& plan) {
    const auto action = plan.action;
    const fs::path argument_base = context.root/L"apps"/wide(plan.package.name)/L"current";
    auto package_description = package_json(context,plan.package);
    expand_package_arguments(context,plan.package.name,package_description,argument_base);
    Json result = {{"action",action_name(action)},{"package",std::move(package_description)},
        {"manifest_sha256",plan.package.manifest_sha256},{"execution_available",plan.execution_available},
        {"external_tools",external_tools_json(context,plan.package)},
        {"artifacts",Json::array()},{"operations",Json::array()},{"preconditions",Json::array()},{"diagnostics",Json::array()}};
    result["local_facts"] = {{"current",path_text(plan.local.current)},{"exists",plan.local.exists},{"current_directory",path_text(plan.local.directory)}};
    result["scoop_entry_wrappers"] = Json::array();
    for (const auto& wrapper : plan.scoop_entry_wrappers)
        result["scoop_entry_wrappers"].push_back(path_text(wrapper));
    const auto persistence_directory = (action == Action::install || action == Action::update)
        ? context.root/L"apps"/wide(plan.package.name)/wide(plan.package.version) : plan.local.directory;
    result["persistence"] = persistence_plan_json(context,plan.package,persistence_directory);
    if (action == Action::update || action == Action::uninstall)
        result["retained_versions"] = retained_versions(context,plan.package.name,plan.package.version);
    Json purge = {{"requested",plan.purge},{"status",plan.purge ? "planned" : "not-requested"},{"scope",Json::array()}};
    if (plan.purge && action != Action::uninstall) {
        purge["status"] = "blocked";
        purge["reason"] = "--purge is only supported by uninstall";
    } else if (plan.purge) {
        try {
            const auto record = context.root/L".coop"/L"packages"/(wide(plan.package.name)+L".json");
            if (!fs::is_regular_file(record)) throw std::runtime_error("Package is unadopted; purge is refused");
            const auto managed = read_json(record);
            purge["scope"] = purge_scope(context,plan.package,plan.local.directory,
                managed.value("persistence",Json::array()));
        } catch (const std::exception& error) {
            purge["status"] = "blocked";
            purge["reason"] = error.what();
        }
    }
    result["purge"] = std::move(purge);
    result["blocking_dependents"] = plan.blocking_dependents;
    result["unverified_dependents"] = plan.unverified_dependents;
    result["dependency_order"] = Json::array();
    const auto steps_json = [](const std::vector<ir::Step>& steps) {
        Json result = Json::array();
        for (const auto& step : steps)
            result.push_back({{"operation",ir::operation_name(step.operation)},{"index",step.index},
                {"previous_package",step.previous},{"effect",step.effect}});
        return result;
    };
    const auto declared_json = [](const std::vector<ir::Dependency>& dependencies) {
        Json result = Json::array();
        for (const auto& dependency : dependencies) result.push_back(dependency.source);
        return result;
    };
    for (const auto& item : plan.dependencies) {
        Json dependency = {{"package",item.name},{"request",item.request},{"bucket",item.bucket},{"version",item.version},
            {"installed",item.installed},{"status",item.installed ? "satisfied" : "planned"},
            {"dependencies",declared_json(item.package.dependencies)},{"ir_operations",steps_json(item.steps)},
            {"diagnostics",Json::array()}};
        if (item.installed) dependency["installed_version"] = item.installed_version;
        if (item.installed) dependency["installed_bucket"] = item.installed_bucket;
        for (const auto& diagnostic : item.diagnostics)
            dependency["diagnostics"].push_back({{"layer",ir::layer_name(diagnostic.layer)},{"code",diagnostic.code},{"message",diagnostic.message}});
        result["dependency_order"].push_back(std::move(dependency));
    }
    // Installation previews keep the historical shape where the requested package appears last in
    // dependency_order. It is reported from the same plan and its own IR steps, not re-derived.
    if (action == Action::install) {
        Json requested = {{"package",plan.package.name},
            {"request",plan.package.bucket.empty() ? plan.package.name : plan.package.bucket+"/"+plan.package.name},
            {"bucket",plan.package.bucket},{"version",plan.package.version},{"installed",plan.local.exists},
            {"status",plan.local.exists ? "satisfied" : "planned"},{"requested",true},
            {"dependencies",declared_json(plan.package.definition ? plan.package.definition->dependencies : std::vector<ir::Dependency>{})},
            {"ir_operations",steps_json(plan.ir_steps)},{"diagnostics",Json::array()}};
        result["dependency_order"].push_back(std::move(requested));
    }
    Json planned = Json::array();
    for (const auto& item : plan.dependencies)
        if (!item.installed) planned.push_back(item.name);
    if (action == Action::install && !plan.local.exists) planned.push_back(plan.package.name);
    result["planned_dependencies"] = std::move(planned);
    const fs::path exposure_base = (action == Action::install || action == Action::update)
        ? context.root/L"apps"/wide(plan.package.name)/L"current"
        : action == Action::adopt ? plan.local.current : plan.local.directory;
    result["exposure"] = exposure_plan_json(context,plan.package,exposure_base);
    if (plan.adoption) {
        Json adopted = Json::array();
        for (const auto& shortcut : plan.adoption->shortcuts)
            adopted.push_back({{"name",shortcut.name},{"path",path_text(shortcut.path)},{"sha256",shortcut.sha256}});
        result["exposure"]["adopted_shortcuts"] = adopted;
    }
    if ((action == Action::update || action == Action::uninstall) && plan.local.exists) {
        Json missing = Json::array();
        for (const auto& shortcut : plan.package.shortcuts)
            if (!fs::is_regular_file(shortcut_link_path(context,shortcut.name))) missing.push_back(shortcut.name);
        result["exposure"]["missing_shortcuts"] = missing;
    }
    result["lifecycle_checks"] = {{"install","unverified"},{"update","unverified"},{"uninstall","unverified"}};
    if (action == Action::adopt && !plan.update_candidate) result["lifecycle_checks"]["update"] = "missing-local-manifest";
    if (plan.update_candidate) {
        result["update_candidate"] = package_json(context,*plan.update_candidate);
        expand_package_arguments(context,plan.update_candidate->name,result["update_candidate"],
            context.root/L"apps"/wide(plan.update_candidate->name)/L"current");
        if (!plan.update_candidate->diagnostics.empty()) result["lifecycle_checks"]["update"] = "known-unsupported-or-invalid";
    }
    if (!plan.package.diagnostics.empty()) {
        result["lifecycle_checks"]["install"] = "known-unsupported-or-invalid";
        result["lifecycle_checks"]["uninstall"] = "known-unsupported-or-invalid";
    }
    if (!plan.package.scripts.empty()) {
        const auto host = script_host();
        if (!host.problem.empty()) {
            result["lifecycle_checks"]["install"] = "known-unsupported-or-invalid";
            result["lifecycle_checks"]["uninstall"] = "known-unsupported-or-invalid";
        } else {
            result["lifecycle_checks"]["hooks"] = "real PowerShell host with the pinned Scoop compatibility library (script text is not whitelisted)";
        }
    }
    if (plan.previous && !plan.previous->scripts.empty() && !script_host().problem.empty())
        result["lifecycle_checks"]["update"] = "known-unsupported-or-invalid";
    if (has_msi_artifact(plan.package) || (plan.previous && has_msi_artifact(*plan.previous)))
        result["lifecycle_checks"]["msi_extraction"] = "read-only Windows Installer database plus the Windows cabinet decompression API; no elevation, reboot, msiexec process or machine-cache write";
    if (has_inno_artifact(plan.package) || (plan.previous && has_inno_artifact(*plan.previous))) {
        const auto helper = inno_helper(context);
        result["lifecycle_checks"]["inno_setup"] = helper.path.empty() ? helper.problem :
            "declared external innounp helper "+path_text(helper.path)+
            " with Scoop's Expand-InnoArchive arguments; the vendor installer is never run and no elevation or reboot is requested";
    }
    if (plan.update_candidate && !plan.update_candidate->scripts.empty() && !script_host().problem.empty())
        result["lifecycle_checks"]["update"] = "known-unsupported-or-invalid";
    if (std::any_of(plan.package.commands.begin(),plan.package.commands.end(),[](const CommandExposure& command) {
            return !launcher_kind(command.target);
        })) {
        result["lifecycle_checks"]["install"] = "known-unsupported-or-invalid";
        result["lifecycle_checks"]["uninstall"] = "known-unsupported-or-invalid";
    }
    if (plan.previous) {
        result["previous_package"] = package_json(context,*plan.previous);
        expand_package_arguments(context,plan.previous->name,result["previous_package"],
            context.root/L"apps"/wide(plan.previous->name)/L"current");
    }
    if (plan.adoption) {
        static const char* states[] = {"eligible","already-managed","unsupported","untested","inconsistent"};
        result["eligibility"] = states[static_cast<int>(plan.adoption->eligibility)];
        result["backup_scope"] = "Original installation metadata and Scoop command entries; installed programs and user data are left in place";
        if (plan.adoption->eligibility == AdoptionEligibility::eligible) {
            result["lifecycle_checks"]["update"] = "supported-path";
            result["lifecycle_checks"]["uninstall"] = "supported-path";
        }
    }
    for (const auto& item : plan.package.artifacts) {
        Json artifact = {{"archive",archive_name(item.archive)},{"url",item.url},{"filename",item.filename},
            {"algorithm",ir::digest_algorithm_name(item.algorithm)},{"digest",item.digest},
            {"hash",std::string(ir::digest_algorithm_name(item.algorithm))+":"+item.digest},
            {"renamed",item.renamed},{"extract_dir",path_text(item.extract_directory)},
            {"extract_to",path_text(item.extract_destination)}};
        if (item.archive == ArchiveKind::msi) {
            artifact["extraction"] = "read-only-msi-image";
            artifact["requires_elevation"] = false;
            artifact["reboot_required"] = false;
        } else if (item.archive == ArchiveKind::inno_setup) {
            artifact["extraction"] = "external-innounp";
            artifact["requires_elevation"] = false;
            artifact["reboot_required"] = false;
            artifact["vendor_installer_executed"] = false;
            artifact["inno_selection"] = "-c"+inno_selection(path_text(item.extract_directory));
        }
        // Keep the historical key only for genuine SHA256 artifacts. A SHA512 value must never be
        // labelled sha256.
        if (item.algorithm == ir::DigestAlgorithm::sha256) artifact["sha256"] = item.digest;
        result["artifacts"].push_back(std::move(artifact));
    }
    for (const auto& item : plan.steps) result["operations"].push_back({{"kind",step_name(item.kind)},{"index",item.index},{"previous_package",item.previous_package},{"detail",item.detail}});
    // The same IR operations the plan carries, with the effect each one has. Kept beside the legacy
    // operation list while both paths coexist; a transition can be checked by comparing the two.
    result["ir_operations"] = Json::array();
    for (const auto& step : plan.ir_steps)
        result["ir_operations"].push_back({{"operation",ir::operation_name(step.operation)},{"index",step.index},
            {"previous_package",step.previous},{"effect",step.effect}});
    Json capabilities = Json::array();
    if (plan.package.definition) for (const auto& item : plan.package.definition->capabilities)
        capabilities.push_back({{"id",item.id},{"supported",item.supported},{"detail",item.detail}});
    result["capabilities"] = std::move(capabilities);
    for (const auto& item : plan.preconditions) result["preconditions"].push_back({{"path",path_text(item.path)},{"sha256",item.sha256}});
    static const char* categories[] = {"syntax","adapter","ir","environment","capability","verification"};
    for (const auto& item : plan.diagnostics) result["diagnostics"].push_back({{"category",categories[static_cast<int>(item.kind)]},{"code",item.code},{"message",item.message}});
    const auto blocker = execution_blocker(context,plan);
    if (!blocker.empty()) result["diagnostics"].push_back({{"category","capability"},{"code","execution-blocked"},{"message",blocker}});
    result["diagnostics"].push_back({{"category","verification"},{"code","lifecycle-verification"},{"message","Native lifecycle coverage: single-file, multi-artifact, renamed-artifact, ZIP, tar, 7z, MSI and Inno Setup archive packages, including packages that combine pre_install/installer/post_install scripts with declared installer/uninstaller programs; MSI artifacts are extracted from a read-only Windows Installer database view with the Windows cabinet decompression API (administrative image layout, no msiexec process, no product registration, no elevation, no reboot and no %WINDIR%\\Installer machine-cache write; external cabinets are reported as unsupported); Inno Setup .exe artifacts are unpacked by the separately installed innounp helper with Scoop's Expand-InnoArchive arguments and layout (the vendor installer is never executed, the helper is detected and never downloaded, and its own [Run]/[Registry]/service/shortcut effects are outside the extraction); declared SHA256, SHA512, SHA1 and MD5 digests, architecture-specific Manifest sections, persist mappings, installed dependencies, EXE/COM/BAT/CMD/PS1/JAR command entries with argument forwarding, Windows shortcuts and declared environment exposure in the current user's persistent environment plus Coop command processes are supported, while persist mapping changes remain unverified; every declared lifecycle hook (pre_install, installer, post_install, pre_uninstall, uninstaller, post_uninstall) runs as trusted script text in a real PowerShell host that loads the pinned Scoop compatibility library (v0.6.0) with the Scoop context and helpers, so script text is not whitelisted and a legitimate Manifest edit still executes, while declared installer/uninstaller programs run through the same real PowerShell host and pinned Scoop Invoke-Installer with the $dir/$global/$version argument substitution, keep semantics and external side effects Coop never claims to roll back"}});
    return result;
}
struct PackageOutcome {
    bool failed = false;
    std::string status;
    std::string reason;
    Json value = Json::object();
};
std::string first_diagnostic(const std::vector<Diagnostic>& diagnostics) {
    return diagnostics.empty() ? std::string{} : diagnostics.front().message;
}
void print_json(const Json& value) {
    std::cout << value.dump(2,' ',false,Json::error_handler_t::replace) << '\n';
}
PackageOutcome install_preview(const Context& context, const std::string& request, const std::string& architecture) {
    PackageOutcome outcome;
    try {
        auto plan = make_plan(context,Action::install,request,architecture);
        outcome.failed = !plan.diagnostics.empty();
        outcome.status = outcome.failed ? "blocked" : "planned";
        outcome.reason = first_diagnostic(plan.diagnostics);
        outcome.value = describe_plan(context,plan);
    } catch (const std::exception& error) {
        outcome.failed = true;
        outcome.status = "blocked";
        outcome.reason = error.what();
        outcome.value = Json{{"action","install"},{"package",request},{"status","blocked"},{"error",error.what()}};
    }
    return outcome;
}
// Build the execution plan for one resolved dependency from the parent plan. The dependency's IR
// steps are already the ones the preview displayed; this only binds the current paths and the
// parent's resolved order as its precondition context.
Plan dependency_execution_plan(const Context& context, const ir::DependencyPlan& item,
                               const std::vector<ir::DependencyPlan>& order) {
    Plan plan;
    plan.action = Action::install;
    plan.package = project_package(item.package);
    plan.dependencies = order;
    plan.local.current = context.root/L"apps"/wide(item.name)/L"current";
    plan.ir_steps = item.steps;
    for (const auto& step : item.steps)
        plan.steps.push_back({legacy_step(step.operation),step.index,step.previous,step.effect});
    plan.preconditions.push_back({plan.package.manifest_path,plan.package.manifest_sha256});
    for (const auto& diagnostic : item.diagnostics)
        plan.diagnostics.push_back({diagnostic_kind(diagnostic.layer),diagnostic.code,diagnostic.message});
    plan.execution_available = execution_blocker(context,plan).empty();
    return plan;
}
PackageOutcome install_execute_plan(const Context& context, const Plan& plan, const std::string& request) {
    PackageOutcome outcome;
    Json packages = Json::array();
    Json root_result;
    const auto blocker = execution_blocker(context,plan);
    if (!blocker.empty()) {
        outcome.failed = true;
        outcome.status = "failed";
        outcome.reason = blocker;
        outcome.value = Json{{"package",request},{"action","install"},{"status","failed"},{"reason",blocker}};
        return outcome;
    }
    for (const auto& item : plan.dependencies) {
        if (item.installed) {
            packages.push_back({{"package",item.name},{"bucket",item.bucket},{"version",item.version},
                {"status","skipped"},{"reason","already-installed"},{"requested",false}});
            continue;
        }
        try {
            auto result = execute_plan_result(context,dependency_execution_plan(context,item,plan.dependencies));
            result["requested"] = false;
            packages.push_back(result);
        } catch (const std::exception& error) {
            outcome.failed = true;
            outcome.status = "failed";
            outcome.reason = error.what();
            packages.push_back({{"package",item.name},{"bucket",item.bucket},{"version",item.version},
                {"status","failed"},{"reason",error.what()},{"requested",false}});
            break;
        }
    }
    if (!outcome.failed) try {
        auto result = execute_plan_result(context,plan);
        result["requested"] = true;
        packages.push_back(result);
        root_result = result;
    } catch (const std::exception& error) {
        outcome.failed = true;
        outcome.status = "failed";
        outcome.reason = error.what();
        packages.push_back({{"package",plan.package.name},{"bucket",plan.package.bucket},{"version",plan.package.version},
            {"status","failed"},{"reason",error.what()},{"requested",true}});
    }
    if (root_result.is_null() || root_result.empty()) {
        root_result = Json{{"package",plan.package.name},{"action","install"},
            {"status",outcome.failed ? "failed" : "success"}};
        if (outcome.failed && !outcome.reason.empty()) root_result["reason"] = outcome.reason;
    }
    root_result["packages"] = packages;
    root_result["transaction_scope"] = "per-package; completed dependency installs are not rolled back when a later package fails";
    if (!outcome.failed) outcome.status = "success";
    outcome.value = root_result;
    return outcome;
}
PackageOutcome install_execute(const Context& context, const std::string& request, const std::string& architecture) {
    PackageOutcome outcome;
    try { return install_execute_plan(context,make_plan(context,Action::install,request,architecture),request); }
    catch (const std::exception& error) {
        outcome.failed = true;
        outcome.status = "failed";
        outcome.reason = error.what();
        outcome.value = Json{{"package",request},{"action","install"},{"status","failed"},{"reason",error.what()}};
        return outcome;
    }
}
Plan prepared_simple_plan(const Context& context, Action action, const std::string& request, const std::string& architecture) {
    return make_plan(context,action,request,architecture);
}
PackageOutcome simple_preview(const Context& context, Action action, const std::string& request, const std::string& architecture, bool purge = false) {
    PackageOutcome outcome;
    try {
        auto plan = prepared_simple_plan(context,action,request,architecture);
        plan.purge = purge;
        plan.execution_available = execution_blocker(context,plan).empty();
        outcome.failed = !plan.diagnostics.empty();
        outcome.status = outcome.failed ? "blocked" : "planned";
        outcome.reason = first_diagnostic(plan.diagnostics);
        outcome.value = describe_plan(context,plan);
        if (purge && outcome.value.value("purge",Json::object()).value("status",std::string{}) == "blocked") {
            outcome.failed = true;
            outcome.status = "blocked";
            outcome.reason = outcome.value.at("purge").value("reason",std::string{"Persistent data purge cannot be verified"});
        }
    } catch (const std::exception& error) {
        outcome.failed = true;
        outcome.status = "blocked";
        outcome.reason = error.what();
        outcome.value = Json{{"action",action_name(action)},{"package",request},{"status","blocked"},{"error",error.what()}};
    }
    return outcome;
}
PackageOutcome simple_execute(const Context& context, Action action, const std::string& request, const std::string& architecture, bool purge = false) {
    PackageOutcome outcome;
    try {
        auto plan = prepared_simple_plan(context,action,request,architecture);
        plan.purge = purge;
        const auto blocker = execution_blocker(context,plan);
        if (!blocker.empty()) {
            outcome.failed = true;
            outcome.status = "failed";
            outcome.reason = blocker;
            outcome.value = Json{{"package",plan.package.name},{"action",action_name(action)},{"status","failed"},{"reason",outcome.reason}};
            return outcome;
        }
        auto result = execute_plan_result(context,plan);
        const auto partial = result.value("status",std::string{}) == "partial";
        outcome.failed = partial;
        outcome.status = (action == Action::adopt && result.value("status",std::string{}) == "already-managed") ? "skipped" :
            partial ? "partial" : "success";
        if (partial) outcome.reason = result.value("reason",result.value("purge",Json::object()).value("reason",std::string("Persistent data deletion was incomplete")));
        outcome.value = result;
    } catch (const std::exception& error) {
        outcome.failed = true;
        outcome.status = "failed";
        outcome.reason = error.what();
        outcome.value = Json{{"package",request},{"action",action_name(action)},{"status","failed"},{"reason",error.what()}};
    }
    return outcome;
}
int install_single(const Context& context, const std::string& request, const std::string& architecture, bool dry_run) {
    if (dry_run) {
        const auto outcome = install_preview(context,request,architecture);
        print_json(outcome.value);
        return outcome.failed ? 1 : 0;
    }
    auto plan = make_plan(context,Action::install,request,architecture);
    const auto blocker = execution_blocker(context,plan);
    if (!blocker.empty()) throw std::runtime_error(blocker);
    if (plan.dependencies.empty()) return execute_plan(context,plan);
    const auto outcome = install_execute_plan(context,plan,request);
    if (context.json_output) print_json(outcome.value);
    else {
        for (const auto& item : outcome.value.at("packages"))
            std::cout << item.value("package",std::string{}) << ": " << item.value("status",std::string{}) << '\n';
        if (outcome.failed) std::cerr << "coop: " << outcome.reason << '\n';
        else std::cout << "Completed packages keep separate transactions; no global transaction is claimed\n";
    }
    return outcome.failed ? 1 : 0;
}
int install_batch(const Context& context, const std::vector<std::wstring>& names, const std::string& architecture, bool dry_run) {
    Json results = Json::array();
    bool failed = false;
    for (const auto& name : names) {
        const auto request = utf8(name);
        const auto outcome = dry_run ? install_preview(context,request,architecture) : install_execute(context,request,architecture);
        Json item = {{"package",request},{"action","install"},{"status",outcome.status}};
        if (!outcome.reason.empty()) item["reason"] = outcome.reason;
        item[dry_run ? "plan" : "result"] = outcome.value;
        if (!dry_run) item["transaction_scope"] = "per-package; completed operations are not rolled back when a later package fails";
        results.push_back(std::move(item));
        failed = failed || outcome.failed;
    }
    if (context.json_output) print_json(results);
    else for (const auto& item : results) {
        std::cout << item.value("package",std::string{}) << ": " << item.value("status",std::string{}) << '\n';
        if (item.contains("reason")) std::cerr << "coop: " << item.at("reason").get<std::string>() << '\n';
    }
    return failed ? 1 : 0;
}
int simple_single(const Context& context, Action action, const std::string& request, const std::string& architecture, bool dry_run, bool purge = false) {
    if (dry_run) {
        const auto outcome = simple_preview(context,action,request,architecture,purge);
        print_json(outcome.value);
        return outcome.failed ? 1 : 0;
    }
    auto plan = prepared_simple_plan(context,action,request,architecture);
    plan.purge = purge;
    const auto blocker = execution_blocker(context,plan);
    if (!blocker.empty()) throw std::runtime_error(blocker);
    return execute_plan(context,plan);
}
int simple_batch(const Context& context, Action action, const std::vector<std::wstring>& names, const std::string& architecture, bool dry_run, bool purge = false) {
    Json results = Json::array();
    bool failed = false;
    for (const auto& name : names) {
        const auto request = utf8(name);
        const auto outcome = dry_run ? simple_preview(context,action,request,architecture,purge) : simple_execute(context,action,request,architecture,purge);
        Json item = {{"package",request},{"action",action_name(action)},{"status",outcome.status}};
        if (!outcome.reason.empty()) item["reason"] = outcome.reason;
        item[dry_run ? "plan" : "result"] = outcome.value;
        if (!dry_run) item["transaction_scope"] = "per-package; completed operations are not rolled back when a later package fails";
        results.push_back(std::move(item));
        failed = failed || outcome.failed;
    }
    if (context.json_output) print_json(results);
    else for (const auto& item : results) {
        std::cout << item.value("package",std::string{}) << ": " << item.value("status",std::string{}) << '\n';
        if (item.contains("reason")) std::cerr << "coop: " << item.at("reason").get<std::string>() << '\n';
    }
    return failed ? 1 : 0;
}
int package_command(const Context& context, const std::wstring& command, const std::vector<std::wstring>& args, const std::string& architecture) {
    if (command == L"adopt" && args.size() == 1 && args[0] == L"--dry-run") {
        Json result = Json::array();
        for (const auto& item : installed_packages(context)) {
            if (item.at("scope") == "global") {
                result.push_back({{"package",item},{"eligibility","unsupported"},{"diagnostics",{"System-level roots are read-only"}}});
                continue;
            }
            try { result.push_back(describe_plan(context,make_plan(context,Action::adopt,item.at("name"),architecture))); }
            catch (const std::exception& error) { result.push_back({{"package",item},{"eligibility","inconsistent"},{"diagnostics",{error.what()}}}); }
        }
        print_json(result);
        return 0;
    }
    bool dry_run = false;
    bool purge = false;
    std::vector<std::wstring> names;
    for (const auto& arg : args) {
        if (arg == L"--dry-run") {
            if (dry_run) throw std::runtime_error("--dry-run was specified more than once");
            dry_run = true;
        } else if (arg == L"--purge") {
            if (purge) throw std::runtime_error("--purge was specified more than once");
            purge = true;
        } else if (arg.starts_with(L"--")) throw std::runtime_error("Unknown package option");
        else names.push_back(arg);
    }
    if (command == L"cleanup") {
        if (purge) throw std::runtime_error("--purge is only supported by uninstall");
        return cleanup_command(context,names,dry_run);
    }
    if (purge && command != L"uninstall") throw std::runtime_error("--purge is only supported by uninstall");
    if (names.empty()) throw std::runtime_error("Use one or more packages [--dry-run]");
    if (purge && names.size() > 1) throw std::runtime_error("--purge accepts one package at a time");
    const auto action = command == L"install" ? Action::install : command == L"update" ? Action::update : command == L"adopt" ? Action::adopt : Action::uninstall;
    if (action == Action::install) return names.size() > 1
        ? install_batch(context,names,architecture,dry_run)
        : install_single(context,utf8(names.front()),architecture,dry_run);
    if (names.size() > 1) return simple_batch(context,action,names,architecture,dry_run,purge);
    return simple_single(context,action,utf8(names.front()),architecture,dry_run,purge);
}
}
