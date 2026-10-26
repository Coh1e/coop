#include "package.hpp"
#include "data.hpp"
#include "persist.hpp"
#include "versions.hpp"
#include "exposure.hpp"
#include "script.hpp"
#include "archive.hpp"
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
const char* archive_name(ArchiveKind kind) {
    switch (kind) {
    case ArchiveKind::none: return "none";
    case ArchiveKind::zip: return "zip";
    case ArchiveKind::seven_zip: return "7z";
    case ArchiveKind::tar: return "tar";
    case ArchiveKind::msi: return "msi";
    }
    return "unknown";
}
std::string trim_text(std::string value) {
    const auto first = value.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) return {};
    return value.substr(first,value.find_last_not_of(" \t\r\n")-first+1);
}
std::string lower_text(std::string value) {
    for (auto& character : value) character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    return value;
}
std::string join_text(const std::vector<std::string>& values, const std::string& separator) {
    std::string result;
    for (const auto& value : values) {
        if (!result.empty()) result += separator;
        result += value;
    }
    return result;
}
struct DependencySpec {
    std::string raw;
    std::string bucket;
    std::string name;
    std::string version;
};
DependencySpec parse_dependency_spec(const std::string& raw) {
    DependencySpec spec;
    spec.raw = trim_text(raw);
    auto value = spec.raw;
    if (const auto at = value.find('@'); at != std::string::npos) {
        spec.version = value.substr(at+1);
        value.resize(at);
    }
    const auto slash = value.find('/');
    if (slash != std::string::npos) {
        if (slash == 0) throw std::runtime_error("Invalid dependency name: "+spec.raw);
        spec.bucket = value.substr(0,slash);
        spec.name = value.substr(slash+1);
    } else {
        spec.name = value;
    }
    if (spec.name.empty()) throw std::runtime_error("Invalid dependency name: "+spec.raw);
    validate_component(spec.name);
    if (!spec.bucket.empty()) validate_component(spec.bucket);
    return spec;
}
std::optional<std::vector<std::string>> manifest_dependencies(const Json& manifest, std::string& problem) {
    if (!manifest.is_object()) { problem = "Manifest is not an object"; return std::nullopt; }
    if (!manifest.contains("depends") || manifest.at("depends").is_null()) return std::vector<std::string>{};
    const auto& depends = manifest.at("depends");
    if (depends.is_string()) return std::vector<std::string>{depends.get<std::string>()};
    if (!depends.is_array()) { problem = "depends must be a string or string array"; return std::nullopt; }
    std::vector<std::string> result;
    for (const auto& item : depends) {
        if (!item.is_string()) { problem = "depends contains a non-string value"; return std::nullopt; }
        result.push_back(item.get<std::string>());
    }
    return result;
}
std::string item_text(const Json& item, const char* key) {
    return item.contains(key) && item.at(key).is_string() ? item.at(key).get<std::string>() : std::string{};
}
bool read_dependent_dependencies(const Context& context, const Json& item, std::vector<std::string>& dependencies, std::string& problem) {
    const auto name = item_text(item,"name");
    const auto scope = item_text(item,"scope");
    fs::path root = context.root;
    if (scope == "global") {
        if (!context.global_root) { problem = "Global root is unknown"; return false; }
        root = *context.global_root;
    }
    const auto current = root/L"apps"/wide(name)/L"current";
    try {
        const auto manifest = read_json(installed_record(current,L"manifest"));
        if (const auto declared = manifest_dependencies(manifest,problem)) { dependencies = *declared; return true; }
    } catch (const std::exception& error) { problem = error.what(); }
    if (scope == "user") {
        try {
            const auto record = read_json(context.root/L".coop"/L"packages"/(wide(name)+L".json"));
            if (record.contains("dependencies") && record.at("dependencies").is_array()) {
                std::vector<std::string> saved;
                for (const auto& entry : record.at("dependencies")) {
                    if (!entry.is_string()) throw std::runtime_error("Managed dependency record contains a non-string value");
                    saved.push_back(entry.get<std::string>());
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
        std::vector<std::string> dependencies;
        std::string problem;
        if (!read_dependent_dependencies(context,item,dependencies,problem)) {
            unverified.insert(scope+"/"+name);
            continue;
        }
        for (const auto& dependency : dependencies) {
            const auto dependency_name = dependency_package_name(dependency);
            if (!dependency_name.empty() && equal_name(dependency_name,plan.package.name)) {
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
class DependencyResolver {
public:
    DependencyResolver(const Context& context, std::string architecture, bool require_installed = false)
        : architecture_(architecture.empty() ? std::string("64bit") : std::move(architecture)), require_installed_(require_installed),
          installed_(installed_packages(context)), catalog_(catalog(context)) {
        for (std::size_t index = 0; index < installed_.size(); ++index) {
            const auto& item = installed_[index];
            if (item_text(item,"scope") != "user") continue;
            const auto name = item_text(item,"name");
            if (name.empty() || !fs::is_directory(context.root/L"apps"/wide(name)/L"current")) continue;
            installed_by_name_[lower_text(name)] = index;
        }
        for (const auto& item : catalog_) {
            const auto name = item_text(item,"name");
            if (name.empty()) continue;
            catalog_by_name_[lower_text(name)].emplace_back(item_text(item,"bucket"),fs::path(wide(item_text(item,"path"))));
        }
    }
    std::vector<DependencyItem> resolve_request(const std::string& request) {
        try {
            resolve_spec(parse_dependency_spec(request),"",true);
        } catch (const std::exception& error) {
            diagnostics_.push_back({DiagnosticKind::validation,"dependency-invalid",error.what()});
        }
        return order_;
    }
    std::vector<DependencyItem> resolve_declared(const Package& package) {
        for (const auto& dependency : package.dependencies) {
            try {
                const auto spec = parse_dependency_spec(dependency);
                if (!spec.version.empty()) {
                    diagnostics_.push_back({DiagnosticKind::adapter,"dependency-version","Version-constrained dependency is not supported: "+spec.raw});
                    continue;
                }
                resolve_spec(spec,package.name,false);
            } catch (const std::exception& error) {
                diagnostics_.push_back({DiagnosticKind::validation,"dependency-invalid",error.what()});
            }
        }
        return order_;
    }
    const std::vector<Diagnostic>& diagnostics() const { return diagnostics_; }
private:
    bool claim_name(const DependencySpec& spec, const std::string& key) {
        const auto name_key = lower_text(spec.name);
        const auto found = names_.find(name_key);
        if (found != names_.end() && found->second != key) {
            diagnostics_.push_back({DiagnosticKind::validation,"dependency-conflict",
                "Dependency '"+spec.raw+"' resolves to multiple sources: "+found->second+" and "+key});
            return false;
        }
        names_[name_key] = key;
        return true;
    }
    bool resolve_spec(const DependencySpec& spec, const std::string& required_by, bool root) {
        if (!root && !spec.version.empty()) {
            diagnostics_.push_back({DiagnosticKind::adapter,"dependency-version","Version-constrained dependency is not supported: "+spec.raw});
            return false;
        }
        const auto name_key = lower_text(spec.name);
        if (const auto found = installed_by_name_.find(name_key); found != installed_by_name_.end()) {
            const auto& item = installed_[found->second];
            const auto installed_bucket = item_text(item,"bucket");
            if (!spec.bucket.empty() && !installed_bucket.empty() && !equal_name(spec.bucket,installed_bucket)) {
                diagnostics_.push_back({DiagnosticKind::environment,"dependency-bucket-conflict",
                    "Dependency '"+spec.raw+"' is installed from bucket '"+installed_bucket+"' instead of '"+spec.bucket+"'"});
                return false;
            }
            const auto bucket = installed_bucket.empty() ? spec.bucket : installed_bucket;
            const auto key = lower_text(bucket+"/"+item_text(item,"name"));
            if (!claim_name(spec,key)) return false;
            if (done_.contains(key)) return true;
            done_.insert(key);
            DependencyItem resolved;
            resolved.request = bucket.empty() ? item_text(item,"name") : bucket+"/"+item_text(item,"name");
            resolved.name = item_text(item,"name");
            resolved.bucket = bucket;
            resolved.version = item_text(item,"version");
            resolved.installed = true;
            order_.push_back(std::move(resolved));
            return true;
        }
        const auto matches_it = catalog_by_name_.find(name_key);
        if (require_installed_) {
            diagnostics_.push_back({DiagnosticKind::environment,"dependency-missing",
                "Declared dependency '"+spec.raw+"' is not installed"});
            return false;
        }
        if (matches_it == catalog_by_name_.end()) {
            diagnostics_.push_back({DiagnosticKind::validation,"dependency-missing",
                "Dependency '"+spec.raw+"' required by '"+(required_by.empty()?std::string("the requested package"):required_by)+"' is not available in local buckets"});
            return false;
        }
        std::vector<const std::pair<std::string,fs::path>*> matches;
        for (const auto& candidate : matches_it->second)
            if (spec.bucket.empty() || equal_name(spec.bucket,candidate.first)) matches.push_back(&candidate);
        if (matches.empty()) {
            diagnostics_.push_back({DiagnosticKind::validation,"dependency-missing",
                "Dependency '"+spec.raw+"' required by '"+(required_by.empty()?std::string("the requested package"):required_by)+"' is not available in the selected bucket"});
            return false;
        }
        if (matches.size() > 1) {
            std::vector<std::string> buckets;
            for (const auto* match : matches) buckets.push_back(match->first);
            diagnostics_.push_back({DiagnosticKind::validation,"dependency-ambiguous",
                "Dependency '"+spec.raw+"' matches multiple buckets ("+join_text(buckets,", ")+"); qualify it as bucket/name"});
            return false;
        }
        const auto& [bucket,path] = *matches.front();
        const auto key = lower_text(bucket+"/"+spec.name);
        if (done_.contains(key)) return true;
        if (std::find(stack_.begin(),stack_.end(),key) != stack_.end()) {
            auto chain = stack_;
            chain.push_back(key);
            diagnostics_.push_back({DiagnosticKind::validation,"dependency-cycle","Circular dependency detected: "+join_text(chain," -> ")});
            return false;
        }
        if (!claim_name(spec,key)) return false;
        Package package;
        try {
            package = parse_package(path,spec.name,bucket,architecture_);
        } catch (const std::exception& error) {
            diagnostics_.push_back({DiagnosticKind::validation,"dependency-invalid","Dependency '"+spec.raw+"' cannot be read: "+error.what()});
            return false;
        }
        if (!root) {
            const auto blocker = package_execution_blocker(package);
            if (!blocker.empty()) {
                diagnostics_.push_back({DiagnosticKind::capability,"dependency-unsupported","Dependency '"+spec.raw+"' cannot be installed: "+blocker});
                return false;
            }
        }
        stack_.push_back(key);
        bool ok = true;
        for (const auto& dependency : package.dependencies) {
            try {
                const auto child = parse_dependency_spec(dependency);
                if (!child.version.empty()) {
                    diagnostics_.push_back({DiagnosticKind::adapter,"dependency-version","Version-constrained dependency is not supported: "+child.raw});
                    ok = false;
                    continue;
                }
                if (!resolve_spec(child,package.name,false)) ok = false;
            } catch (const std::exception& error) {
                diagnostics_.push_back({DiagnosticKind::validation,"dependency-invalid",error.what()});
                ok = false;
            }
        }
        stack_.pop_back();
        if (!ok) return false;
        done_.insert(key);
        DependencyItem resolved;
        resolved.request = bucket+"/"+spec.name;
        resolved.name = spec.name;
        resolved.bucket = bucket;
        resolved.version = package.version;
        resolved.dependencies = package.dependencies;
        order_.push_back(std::move(resolved));
        return true;
    }
    std::string architecture_;
    bool require_installed_ = false;
    Json installed_;
    Json catalog_;
    std::map<std::string,std::size_t> installed_by_name_;
    std::map<std::string,std::vector<std::pair<std::string,fs::path>>> catalog_by_name_;
    std::map<std::string,std::string> names_;
    std::set<std::string> done_;
    std::vector<std::string> stack_;
    std::vector<DependencyItem> order_;
    std::vector<Diagnostic> diagnostics_;
};
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
        plan.steps.push_back({legacy_step(step.operation),step.index,step.previous});
    plan.ir_steps = package_plan.steps;
}
Json external_tools_json(const Package& package) {
    Json result = Json::array();
    for (const auto& tool : package_external_tools(package))
        result.push_back({{"name",tool.name},{"purpose",tool.purpose},{"policy",tool.policy},
            {"available",tool.available},{"enabled",tool.enabled},{"limitation",tool.limitation},
            {"path",path_text(tool.path)}});
    return result;
}
Json package_json(const Package& package) {
    Json result = {{"name",package.name},{"bucket",package.bucket},{"version",package.version},{"architecture",package.architecture},
        {"manifest_path",path_text(package.manifest_path)},{"manifest_sha256",package.manifest_sha256},
        {"commands",Json::array()},{"shortcuts",Json::array()},{"persistence",Json::array()},
        {"environment",Json::array()},{"path_entries",Json::array()},{"scripts",Json::array()}};
    for (const auto& item : package.commands) result["commands"].push_back({{"target",path_text(item.target)},{"name",item.name},{"arguments",item.arguments},{"launcher",command_launcher_name(item.target)}});
    for (const auto& item : package.shortcuts) result["shortcuts"].push_back({{"target",path_text(item.target)},{"name",item.name},{"arguments",item.arguments},{"icon",path_text(item.icon)}});
    for (const auto& item : package.persistence) result["persistence"].push_back({{"source",path_text(item.source)},{"target",path_text(item.target)}});
    for (const auto& item : package.environment) result["environment"].push_back({{"name",item.name},{"value",item.value}});
    for (const auto& item : package.path_entries) result["path_entries"].push_back(path_text(item));
    const auto scripts = check_package_scripts(package);
    for (std::size_t index = 0; index < package.scripts.size(); ++index) {
        const auto& script = package.scripts[index];
        const auto& report = scripts.scripts[index];
        Json entry = {{"phase",script_phase_name(script.phase)},{"text",script.text},
            {"compatible",report.compatible},{"commands",report.commands},{"helpers",report.helpers},
            {"required_tools",report.required_tools},
            {"diagnostics",Json::array()},
            {"side_effects","trusted Manifest script text; effects outside the managed package and persist roots cannot be predicted or rolled back, and a failed hook is never re-run automatically"}};
        for (const auto& diagnostic : report.diagnostics) entry["diagnostics"].push_back({{"code",diagnostic.code},{"message",diagnostic.message}});
        result["scripts"].push_back(std::move(entry));
    }
    result["script_support"] = {{"phases",Json::array({"pre_install","installer","post_install","pre_uninstall","uninstaller"})},
        {"context",Json::array({"$app","$bucket","$version","$architecture","$fname","$dir","$original_dir","$persist_dir","$bucketsdir","$global","$cmd","$_"})},
        {"helpers",Json::array({"ensure","info","warn"})},
        {"commands",Json::array({"Test-Path","Get-Content","Set-Content","New-Item","Copy-Item","Remove-Item","Join-Path","Split-Path","Get-Item","Out-Null","ForEach-Object"})},
        {"host","real PowerShell child process with the proven context; not an embedded PowerShell interpreter"},
        {"scope","path arguments must resolve under $dir, $original_dir, $persist_dir or $bucketsdir; no external commands, environment writes or arbitrary .NET calls are enabled"}};
    result["external_tools"] = external_tools_json(package);
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
bool dependency_is_installed(const Context& context, const std::string& specified) {
    const auto name = dependency_package_name(specified);
    if (name.empty()) return false;
    const auto current = context.root/L"apps"/wide(name)/L"current";
    if (!fs::is_directory(current)) return false;
    auto bucket = trim_text(specified);
    if (const auto at = bucket.find('@'); at != std::string::npos) bucket.resize(at);
    if (const auto slash = bucket.find('/'); slash != std::string::npos) bucket.resize(slash);
    else bucket.clear();
    if (bucket.empty()) return true;
    try {
        const auto install = read_json(installed_record(current,L"install"));
        const auto installed_bucket = item_text(install,"bucket");
        return installed_bucket.empty() || equal_name(bucket,installed_bucket);
    } catch (const std::exception&) { return false; }
}
Plan make_plan(const Context& context, Action action, const std::string& request, const std::string& architecture) {
    Plan plan{action,{},std::nullopt,{},{},{},false,{},std::nullopt,std::nullopt,{}};
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
    if (action == Action::install) append_ir_plan(plan,ir::Action::install,true);
    else if (action == Action::update) append_ir_plan(plan,ir::Action::update,true);
    else if (action == Action::uninstall) append_ir_plan(plan,ir::Action::uninstall,false);
    else if (action == Action::adopt) append_ir_plan(plan,ir::Action::adopt,false);
    plan.preconditions.push_back({plan.package.manifest_path,plan.package.manifest_sha256});
    const auto registry = context.root/L".coop"/L"buckets.json";
    if (fs::exists(registry)) plan.preconditions.push_back({registry,sha256_file(registry)});
    plan.diagnostics.insert(plan.diagnostics.end(),plan.package.diagnostics.begin(),plan.package.diagnostics.end());
    if (action == Action::adopt) {
        plan.adoption = assess_adoption(context,plan);
        plan.diagnostics.insert(plan.diagnostics.end(),plan.adoption->diagnostics.begin(),plan.adoption->diagnostics.end());
        if (plan.adoption->eligibility == AdoptionEligibility::eligible) {
            plan.preconditions.push_back({plan.local.directory/wide(plan.package.artifacts.front().filename),plan.package.artifacts.front().sha256});
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
    Json result = {{"action",action_name(action)},{"package",package_json(plan.package)},
        {"manifest_sha256",plan.package.manifest_sha256},{"execution_available",plan.execution_available},
        {"external_tools",external_tools_json(plan.package)},
        {"artifacts",Json::array()},{"operations",Json::array()},{"preconditions",Json::array()},{"diagnostics",Json::array()}};
    result["local_facts"] = {{"current",path_text(plan.local.current)},{"exists",plan.local.exists},{"current_directory",path_text(plan.local.directory)}};
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
    for (const auto& item : plan.dependency_order)
        result["dependency_order"].push_back({{"package",item.name},{"request",item.request},{"bucket",item.bucket},
            {"version",item.version},{"installed",item.installed},{"status",item.installed ? "satisfied" : "planned"},
            {"dependencies",item.dependencies}});
    result["planned_dependencies"] = plan.planned_dependencies;
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
        result["update_candidate"] = package_json(*plan.update_candidate);
        if (!plan.update_candidate->diagnostics.empty()) result["lifecycle_checks"]["update"] = "known-unsupported-or-invalid";
    }
    if (!plan.package.diagnostics.empty()) {
        result["lifecycle_checks"]["install"] = "known-unsupported-or-invalid";
        result["lifecycle_checks"]["uninstall"] = "known-unsupported-or-invalid";
    }
    const auto package_scripts = check_package_scripts(plan.package);
    if (!package_scripts.compatible()) {
        result["lifecycle_checks"]["install"] = "known-unsupported-or-invalid";
        result["lifecycle_checks"]["uninstall"] = "known-unsupported-or-invalid";
    } else if (!plan.package.scripts.empty()) {
        result["lifecycle_checks"]["hooks"] = "supported-path; verified with real upstream hook text in tests/hooks.ps1 and real installer/uninstaller script text in tests/installers.ps1";
    }
    if (plan.previous && !check_package_scripts(*plan.previous).compatible())
        result["lifecycle_checks"]["update"] = "known-unsupported-or-invalid";
    if (plan.update_candidate && !check_package_scripts(*plan.update_candidate).compatible())
        result["lifecycle_checks"]["update"] = "known-unsupported-or-invalid";
    if (std::any_of(plan.package.commands.begin(),plan.package.commands.end(),[](const CommandExposure& command) {
            return !launcher_kind(command.target);
        })) {
        result["lifecycle_checks"]["install"] = "known-unsupported-or-invalid";
        result["lifecycle_checks"]["uninstall"] = "known-unsupported-or-invalid";
    }
    if (plan.previous) result["previous_package"] = package_json(*plan.previous);
    if (plan.adoption) {
        static const char* states[] = {"eligible","already-managed","unsupported","untested","inconsistent"};
        result["eligibility"] = states[static_cast<int>(plan.adoption->eligibility)];
        result["backup_scope"] = "Original installation metadata and Scoop command entries; installed programs and user data are left in place";
        if (plan.adoption->eligibility == AdoptionEligibility::eligible) {
            result["lifecycle_checks"]["update"] = "supported-path";
            result["lifecycle_checks"]["uninstall"] = "supported-path";
        }
    }
    for (const auto& item : plan.package.artifacts) result["artifacts"].push_back({{"archive",archive_name(item.archive)},{"url",item.url},{"filename",item.filename},{"sha256",item.sha256},{"extract_dir",path_text(item.extract_directory)},{"extract_to",path_text(item.extract_destination)}});
    for (const auto& item : plan.steps) result["operations"].push_back({{"kind",step_name(item.kind)},{"index",item.index},{"previous_package",item.previous_package}});
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
    result["diagnostics"].push_back({{"category","verification"},{"code","lifecycle-verification"},{"message","Native lifecycle coverage: single-file, ZIP, tar and 7z archive packages without installer or uninstaller processes; declared persist mappings, installed dependencies, EXE/COM/BAT/CMD/PS1/JAR command entries with argument forwarding, Windows shortcuts and declared environment exposure applied to command processes are supported, while persistent user environment changes and persist mapping changes remain unverified; MSI artifacts are detected and their Windows Installer requirement is reported, but administrative extraction remains blocked because msiexec writes the machine cache under %WINDIR%\\Installer outside the selected project root; lifecycle hooks run in the fixed Scoop order only for pre_install, installer, post_install, pre_uninstall and uninstaller scripts that stay inside the context and helpers proven by the sample corpus, and any other script is refused before adoption or execution"}});
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
std::string diagnostics_text(const std::vector<Diagnostic>& diagnostics) {
    std::vector<std::string> messages;
    for (const auto& item : diagnostics) messages.push_back(item.message);
    return join_text(messages,"; ");
}
void print_json(const Json& value) {
    std::cout << value.dump(2,' ',false,Json::error_handler_t::replace) << '\n';
}
PackageOutcome install_preview(const Context& context, const std::string& request, const std::string& architecture) {
    PackageOutcome outcome;
    DependencyResolver resolver(context,architecture);
    auto order = resolver.resolve_request(request);
    try {
        auto plan = make_plan(context,Action::install,request,architecture);
        plan.dependency_order = std::move(order);
        for (const auto& item : plan.dependency_order)
            if (!item.installed) plan.planned_dependencies.push_back(item.name);
        plan.diagnostics.insert(plan.diagnostics.end(),resolver.diagnostics().begin(),resolver.diagnostics().end());
        plan.execution_available = execution_blocker(context,plan).empty();
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
PackageOutcome install_execute(const Context& context, const std::string& request, const std::string& architecture) {
    PackageOutcome outcome;
    DependencyResolver resolver(context,architecture);
    const auto order = resolver.resolve_request(request);
    if (!resolver.diagnostics().empty()) {
        outcome.failed = true;
        outcome.status = "failed";
        outcome.reason = diagnostics_text(resolver.diagnostics());
        outcome.value = Json{{"package",request},{"action","install"},{"status","failed"},{"reason",outcome.reason}};
        return outcome;
    }
    Json packages = Json::array();
    Json root_result;
    try {
        auto root_plan = make_plan(context,Action::install,request,architecture);
        for (const auto& item : order) if (!item.installed) root_plan.planned_dependencies.push_back(item.name);
        const auto blocker = execution_blocker(context,root_plan);
        if (!blocker.empty()) {
            outcome.failed = true;
            outcome.status = "failed";
            outcome.reason = blocker;
            outcome.value = Json{{"package",request},{"action","install"},{"status","failed"},{"reason",blocker}};
            return outcome;
        }
    } catch (const std::exception& error) {
        outcome.failed = true;
        outcome.status = "failed";
        outcome.reason = error.what();
        outcome.value = Json{{"package",request},{"action","install"},{"status","failed"},{"reason",error.what()}};
        return outcome;
    }
    for (std::size_t index = 0; index < order.size(); ++index) {
        const auto& item = order[index];
        const bool requested = index + 1 == order.size();
        if (item.installed) {
            if (requested) {
                outcome.failed = true;
                outcome.status = "failed";
                outcome.reason = "Package already exists; use adoption or update";
                packages.push_back({{"package",item.name},{"bucket",item.bucket},{"version",item.version},
                    {"status","failed"},{"reason",outcome.reason},{"requested",true}});
                break;
            }
            packages.push_back({{"package",item.name},{"bucket",item.bucket},{"version",item.version},
                {"status","skipped"},{"reason","already-installed"},{"requested",false}});
            continue;
        }
        try {
            const auto package_request = requested ? request : item.bucket+"/"+item.name;
            const auto plan = make_plan(context,Action::install,package_request,architecture);
            auto result = execute_plan_result(context,plan);
            result["requested"] = requested;
            packages.push_back(result);
            if (requested) root_result = result;
        } catch (const std::exception& error) {
            outcome.failed = true;
            outcome.status = "failed";
            outcome.reason = error.what();
            packages.push_back({{"package",item.name},{"bucket",item.bucket},{"version",item.version},
                {"status","failed"},{"reason",error.what()},{"requested",requested}});
            break;
        }
    }
    if (root_result.is_null() || root_result.empty()) {
        root_result = Json{{"package",order.empty() ? request : order.back().name},{"action","install"},
            {"status",outcome.failed ? "failed" : "success"}};
        if (outcome.failed && !outcome.reason.empty()) root_result["reason"] = outcome.reason;
    }
    root_result["packages"] = packages;
    root_result["transaction_scope"] = "per-package; completed dependency installs are not rolled back when a later package fails";
    if (!outcome.failed) outcome.status = "success";
    outcome.value = root_result;
    return outcome;
}
Plan prepared_simple_plan(const Context& context, Action action, const std::string& request, const std::string& architecture) {
    auto plan = make_plan(context,action,request,architecture);
    if (action == Action::update) {
        const auto target_architecture = plan.package.architecture.empty() ? (architecture.empty() ? std::string("64bit") : architecture) : plan.package.architecture;
        DependencyResolver resolver(context,target_architecture,true);
        plan.dependency_order = resolver.resolve_declared(plan.package);
        plan.diagnostics.insert(plan.diagnostics.end(),resolver.diagnostics().begin(),resolver.diagnostics().end());
        plan.execution_available = execution_blocker(context,plan).empty();
    }
    return plan;
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
    DependencyResolver resolver(context,architecture);
    const auto order = resolver.resolve_request(request);
    if (!resolver.diagnostics().empty()) throw std::runtime_error(diagnostics_text(resolver.diagnostics()));
    if (order.size() <= 1) return execute_plan(context,make_plan(context,Action::install,request,architecture));
    const auto outcome = install_execute(context,request,architecture);
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
