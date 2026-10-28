#include "package.hpp"
#include "data.hpp"
#include "persist.hpp"
#include "versions.hpp"
#include "exposure.hpp"
#include "script.hpp"
#include "shim.hpp"
#include "archive.hpp"
#include "inno.hpp"
#include "nsis.hpp"
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
const char* action_name(ir::Action action) {
    switch (action) {
    case ir::Action::install: return "install";
    case ir::Action::update: return "update";
    case ir::Action::uninstall: return "uninstall";
    case ir::Action::reset: return "reset";
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
// Saved dependent manifests are read through the IR adapter, so reverse-dependency evidence uses
// the same normalized identity as forward dependency planning. Coop's own record is only a fallback
// when the shared manifest is missing or unreadable.
bool read_dependent_dependencies(const Context& context, const ir::InstalledFact& fact,
                                 std::vector<ir::Dependency>& dependencies, std::string& problem) {
    (void)context;
    try {
        const auto manifest = installed_record(fact.directory,L"manifest");
        const auto definition = ir::adapt_manifest(manifest,fact.name,fact.bucket,
            fact.architecture.empty() ? std::string("64bit") : fact.architecture);
        for (const auto& diagnostic : definition.diagnostics)
            if (diagnostic.code == "manifest-json" || diagnostic.code == "manifest-shape") {
                problem = diagnostic.message;
                throw std::runtime_error(diagnostic.message);
            }
        dependencies = definition.dependencies;
        return true;
    } catch (const std::exception& error) { problem = error.what(); }
    try {
        const auto record = read_json(context.root/L".coop"/L"packages"/(wide(fact.name)+L".json"));
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
    return false;
}
void collect_reverse_dependencies(const Context& context, Plan& plan) {
    std::set<std::string> blocking, unverified;
    const auto collect = [&](const fs::path& root, const std::string& scope) {
        for (const auto& fact : ir::read_installations(root)) {
            if (fact.name.empty()) continue;
            if (scope == "user" && equal_name(fact.name,plan.package.name)) continue;
            if (!fs::is_directory(root/L"apps"/wide(fact.name)/L"current")) continue;
            std::vector<ir::Dependency> dependencies;
            std::string problem;
            if (!read_dependent_dependencies(context,fact,dependencies,problem)) {
                unverified.insert(scope+"/"+fact.name);
                continue;
            }
            for (const auto& dependency : dependencies) {
                if (!dependency.name.empty() && equal_name(dependency.name,plan.package.name)) {
                    blocking.insert(fact.name);
                    break;
                }
            }
        }
    };
    collect(context.root,"user");
    if (context.global_root) collect(*context.global_root,"global");
    plan.blocking_dependents.assign(blocking.begin(),blocking.end());
    plan.unverified_dependents.assign(unverified.begin(),unverified.end());
    if (!plan.blocking_dependents.empty())
        plan.diagnostics.push_back({ir::Layer::verification,"blocked-by-dependents",
            "Installed packages still depend on this package: "+join_text(plan.blocking_dependents,", ")+"; uninstall is refused and no dependent is removed automatically"});
    if (!plan.unverified_dependents.empty())
        plan.diagnostics.push_back({ir::Layer::verification,"dependency-evidence-incomplete",
            "Saved dependency evidence cannot be read for: "+join_text(plan.unverified_dependents,", ")+"; missing evidence does not prove that no package depends on this one"});
}
// The IR planner resolves the package graph. This adapter supplies local catalogue identity and
// normalized package IR; it does not decide order, cycles or source conflicts itself.
ir::DependencyResolution resolve_package_dependencies(const Context& context, const ir::Package& package,
                                                      bool require_installed) {
    const auto index = catalogue(context);
    ir::DependencySource source;
    source.buckets = [index](const std::string& name) {
        std::vector<std::string> buckets;
        for (const auto& item : index)
            if (equal_name(item.name,name)) buckets.push_back(item.bucket);
        return buckets;
    };
    source.load = [index,architecture = package.architecture](const std::string& bucket, const std::string& name) {
        for (const auto& item : index)
            if (equal_name(item.name,name) && equal_name(item.bucket,bucket)) {
                auto definition = ir::adapt_manifest(item.manifest_path,name,bucket,
                    architecture.empty() ? std::string("64bit") : architecture);
                ir::validate(definition);
                return definition;
            }
        throw std::runtime_error("Package not found in local buckets");
    };
    const ir::DependencyBlocker blocker = [&context](const ir::Package& definition) {
        return capability_blocker(context,definition);
    };
    return ir::resolve_dependencies(package,ir::read_installations(context.root),require_installed,
        source,blocker);
}
Json external_tools_json(const Context& context, const ir::Package& package) {
    Json result = Json::array();
    for (const auto& tool : package_external_tools(context,package))
        result.push_back({{"name",tool.name},{"purpose",tool.purpose},{"policy",tool.policy},
            {"available",tool.available},{"enabled",tool.enabled},{"limitation",tool.limitation},
            {"path",path_text(tool.path)}});
    return result;
}
bool has_format(const ir::Package& package, ir::ArchiveFormat format) {
    return std::any_of(package.downloads.begin(),package.downloads.end(),[format](const ir::Download& artifact) {
        return artifact.format == format;
    });
}
bool has_msi_artifact(const ir::Package& package) { return has_format(package,ir::ArchiveFormat::msi); }
bool has_inno_artifact(const ir::Package& package) { return has_format(package,ir::ArchiveFormat::inno_setup); }
bool has_nsis_payload(const ir::Package& package) {
    return std::any_of(package.downloads.begin(),package.downloads.end(),[](const ir::Download& artifact) {
        return artifact.installer_payload;
    });
}
bool declares_environment(const ir::Package& package) { return !package.environment.empty(); }
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
// An NSIS installer payload is a self-extracting executable that the Manifest declares as an
// archive (Scoop's `#/dl.7z` idiom). The declared suffix cannot decide the real container, so the
// plan states the content-detection rule and the helper the backend would use. Every ordinary
// archive keeps the native reader.
Json nsis_extraction_json(const Context& context) {
    const auto helper = nsis_helper(context);
    return {{"mechanism","external 7-Zip helper using Scoop's Expand-7zipArchive arguments"},
        {"payload","an executable self-extractor declared as an archive payload (for example `#/dl.7z`)"},
        {"content_detection","after digest verification Coop inspects the payload bytes: only an NSIS installer uses the helper, every other payload stays with the native archive reader"},
        {"signature","NSIS FirstHeader magic DE AD BE EF followed by the ASCII marker NullsoftInst; the byte offset is recorded in the transaction journal"},
        {"helper",path_text(helper.path)},
        {"helper_available",!helper.path.empty()},
        {"helper_problem",helper.problem},
        {"helper_lookup","apps/7zip/current/7z.exe under the selected root and the optional global root"},
        {"helper_policy","a separate 7-Zip software dependency of this package mechanism, not a Coop core dependency; Coop detects it and never downloads, installs or bundles it"},
        {"arguments","x <payload> -o<destination> -xr!*.nsis -y, plus -ir!<extract_dir>\\* when extract_dir is declared, exactly as Scoop 0.6.0's Expand-7zipArchive"},
        {"installer_executed",false},
        {"elevation","not requested: 7-Zip unpacks files into the selected root and the vendor setup.exe never runs"},
        {"reboot","not required: no vendor setup.exe process is started, so its reboot scheduling cannot run"},
        {"installer_effects","not executed: the vendor setup.exe's install directory, registry, services, Start Menu entries, [Run] steps and uninstall registration are outside this extraction"},
        {"layout","the whole extracted NSIS payload, or the declared extract_dir selection, then the declared extract_to; file contents and timestamps are what 7-Zip writes"},
        {"limitations","the helper is used only when the verified content is an NSIS installer, so preview cannot promise that the payload needs it; a missing helper, a non-NSIS payload 7-Zip cannot read, or a non-zero helper exit fails with a named non-zero error before a version is published"}};
}
Json package_json(const Context& context, const ir::Package& package) {
    Json result = {{"name",package.name},{"bucket",package.bucket},{"version",package.version},{"architecture",package.architecture},
        {"manifest_path",package.manifest_path},{"manifest_sha256",package.manifest_digest},
        {"commands",Json::array()},{"shortcuts",Json::array()},{"persistence",Json::array()},
        {"environment",Json::array()},{"path_entries",Json::array()},{"scripts",Json::array()},
        {"notes",package.notes},{"suggest",Json::array()}};
    for (const auto& [feature,candidates] : package.suggestions)
        result["suggest"].push_back({{"feature",feature},{"candidates",candidates}});
    for (const auto& item : package.entries) {
        const auto target = fs::path(wide(item.target));
        result["commands"].push_back({{"target",item.target},{"name",item.alias},{"arguments",item.arguments},
            {"launcher",command_launcher_name(target)}});
    }
    for (const auto& item : package.shortcuts)
        result["shortcuts"].push_back({{"target",item.target},{"name",item.name},{"arguments",item.arguments},{"icon",item.icon}});
    for (const auto& item : package.persistence)
        result["persistence"].push_back({{"source",item.source},{"target",item.target}});
    for (const auto& item : package.environment) {
        if (item.path_entry) result["path_entries"].push_back(item.value);
        else result["environment"].push_back({{"name",item.variable},{"value",item.value}});
    }
    if (package.psmodule) result["psmodule"] = {{"name",package.psmodule->name}};
    const auto host = script_host();
    for (const auto& script : package.hooks) {
        Json entry = {{"phase",ir::hook_stage_name(script.stage)},{"text",script.text},
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
    if (has_nsis_payload(package)) result["nsis_extraction"] = nsis_extraction_json(context);
    result["dependencies"] = Json::array();
    for (const auto& dependency : package.dependencies) result["dependencies"].push_back(dependency.source);
    // Installer/uninstaller programs run through the same real PowerShell host and pinned Scoop
    // library as hook scripts, calling upstream Invoke-Installer. The preview therefore names the
    // declared program, its substitution context, what happens to the program file, and which
    // effects cannot be recovered.
    const auto process_json = [](const ir::InstallerProgram& process) {
        return Json{{"file",process.file},{"arguments",process.arguments},{"keep",process.keep},
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
ir::Package parse_package(const fs::path& path, const std::string& name, const std::string& bucket,
                          const std::string& architecture) {
    return ir::adapt_manifest(path,name,bucket,architecture);
}
Plan make_plan(const Context& context, ir::Action action, const std::string& request, const std::string& architecture,
               bool purge) {
    Plan plan;
    plan.action = action;
    // --purge is part of the request the verdict describes, so it is attached before the blocker is
    // computed at the end of this function.
    plan.purge = purge;
    auto name = request;
    std::string bucket, version;
    const auto at = name.find('@');
    if (at != std::string::npos) { version = name.substr(at+1); name.resize(at); validate_component(version); }
    const auto slash = name.find('/');
    if (slash != std::string::npos) { bucket = name.substr(0,slash); name.erase(0,slash+1); validate_component(bucket); }
    validate_component(name);
    plan.local.current = context.root/L"apps"/wide(name)/L"current";
    plan.local.exists = fs::is_directory(plan.local.current);
    if (plan.local.exists) plan.local.directory = operating_path(fs::canonical(plan.local.current));
    // The system-level root is a read-only source of installation facts. A request that names a
    // package installed only there must not be reinterpreted as a user-scope change: update,
    // uninstall and reset would otherwise silently target a different installation than the one
    // the user can see in `list`. A fresh user-scope install remains available and never writes to
    // the global root.
    if (!plan.local.exists && context.global_root) {
        const auto global_current = *context.global_root/L"apps"/wide(name)/L"current";
        if (fs::is_directory(global_current)) {
            std::error_code error;
            const auto canonical = fs::weakly_canonical(global_current,error);
            plan.global_installation = operating_path(error ? global_current : canonical);
            if (action != ir::Action::install)
                throw std::runtime_error("global-scope-readonly: package '"+name+"' is installed only in the "
                    "read-only system-level root "+path_text(*context.global_root)+
                    "; Coop does not update or remove system-level installations");
        }
    }
    const auto read_installed = [&]() {
        if (!plan.local.exists) throw std::runtime_error("No usable local current installation");
        // The shared install record is decoded by the IR adapter. A missing or corrupt record is
        // reported as an adapter diagnostic instead of a planner-owned JSON read.
        ir::InstalledFact fact;
        for (const auto& candidate : ir::read_installations(context.root))
            if (equal_name(candidate.name,name)) { fact = candidate; break; }
        for (const auto& diagnostic : fact.diagnostics)
            plan.diagnostics.push_back(diagnostic);
        const auto manifest = installed_record(plan.local.current,L"manifest");
        const auto install_path = installed_record(plan.local.current,L"install");
        plan.preconditions.push_back({install_path,sha256_file(install_path)});
        auto package = parse_package(manifest,name,fact.bucket,
            fact.architecture.empty() ? (architecture.empty() ? std::string("64bit") : architecture) : fact.architecture);
        ir::validate(package);
        plan.preconditions.push_back({manifest,package.manifest_digest});
        if (!bucket.empty() && !equal_name(bucket,package.bucket))
            plan.diagnostics.push_back({ir::Layer::environment,"installed-bucket-mismatch","Installed package has a different bucket"});
        return package;
    };
    auto target_architecture = architecture.empty() ? std::string("64bit") : architecture;
    if (action == ir::Action::update) {
        plan.previous = read_installed();
        if (bucket.empty()) bucket = plan.previous->bucket;
        if (architecture.empty()) target_architecture = plan.previous->architecture;
        plan.diagnostics.insert(plan.diagnostics.end(),plan.previous->diagnostics.begin(),plan.previous->diagnostics.end());
    }
    if (action == ir::Action::reset) {
        // A rollback is resolved only from a local version directory with its saved Manifest and
        // installation record. Remote history is never consulted and no URL is reconstructed.
        plan.previous = read_installed();
        if (version.empty())
            throw std::runtime_error("reset requires an installed version, for example "+name+"@<version>");
        const auto app = context.root/L"apps"/wide(name);
        const auto directory = app/wide(version);
        const auto evidence = version_evidence(directory,version);
        if (evidence.value("status",std::string{}) != "retained")
            throw std::runtime_error("Local version cannot be used for rollback: "+
                evidence.value("reason",std::string{"version evidence is unavailable"}));
        const auto install_record = fs::path(wide(evidence.at("install_record_path").get<std::string>()));
        const auto install = read_json(install_record);
        auto target_bucket = install.value("bucket",plan.previous->bucket);
        auto target_arch = install.value("architecture",plan.previous->architecture);
        if (target_arch.empty()) target_arch = target_architecture;
        if (!architecture.empty() && !equal_name(architecture,target_arch))
            throw std::runtime_error("Requested architecture does not match the local version's installation record");
        if (!bucket.empty() && !equal_name(bucket,target_bucket))
            throw std::runtime_error("Requested bucket does not match the local version's installation record");
        plan.package = parse_package(fs::path(wide(evidence.at("manifest_path").get<std::string>())),
            name,target_bucket,target_arch);
        ir::validate(plan.package);
        plan.preconditions.push_back({install_record,sha256_file(install_record)});
        if (!equal_name(plan.package.version,version))
            throw std::runtime_error("Saved Manifest version does not match the requested local version");
        if (equal_name(version,plan.previous->version))
            throw std::runtime_error("Requested version is already current; nothing would be reset");
        for (const auto& record : recorded_version_evidence(context,name)) {
            if (!equal_name(record.value("version",std::string{}),version)) continue;
            const auto expected_manifest = record.value("manifest_sha256",std::string{});
            const auto expected_install = record.value("install_record_sha256",std::string{});
            const auto expected_stamp = record.value("tree_stamp",std::string{});
            if (!expected_manifest.empty() && expected_manifest != evidence.value("manifest_sha256",std::string{}))
                plan.diagnostics.push_back({ir::Layer::verification,"retained-version-modified",
                    "Retained Manifest changed after Coop recorded this version; rollback is refused"});
            if (!expected_install.empty() && expected_install != evidence.value("install_record_sha256",std::string{}))
                plan.diagnostics.push_back({ir::Layer::verification,"retained-version-modified",
                    "Retained installation record changed after Coop recorded this version; rollback is refused"});
            if (!expected_stamp.empty()) {
                try {
                    if (version_tree_stamp(directory) != expected_stamp)
                        plan.diagnostics.push_back({ir::Layer::verification,"retained-version-modified",
                            "Retained version contents changed after Coop recorded them; rollback is refused"});
                } catch (const std::exception& error) {
                    plan.diagnostics.push_back({ir::Layer::verification,"retained-version-modified",
                        std::string("Retained version contents cannot be inspected: ")+error.what()});
                }
            }
            break;
        }
        if (!same_persistence(*plan.previous,plan.package))
            plan.diagnostics.push_back({ir::Layer::verification,"persist-change-unverified",
                "Persist mapping differs from the current version; data rollback is not verified, so the reset is refused"});
        plan.diagnostics.insert(plan.diagnostics.end(),plan.previous->diagnostics.begin(),plan.previous->diagnostics.end());
    }
    if (action == ir::Action::install || action == ir::Action::update) {
        std::vector<ir::CatalogueEntry> matches;
        for (const auto& entry : catalogue(context))
            if (equal_name(entry.name,name) && (bucket.empty() || equal_name(entry.bucket,bucket))) matches.push_back(entry);
        if (matches.size() != 1) throw std::runtime_error(matches.empty() ? "Package not found in local buckets" : "Ambiguous package; qualify it with its bucket");
        const auto& entry = matches.front();
        plan.package = parse_package(entry.manifest_path,entry.name,entry.bucket,target_architecture);
        ir::validate(plan.package);
        if (!version.empty() && plan.package.version != version)
            plan.diagnostics.push_back({ir::Layer::environment,"version-unavailable","Requested version is absent locally; no URL will be guessed"});
        if (action == ir::Action::update && plan.previous && !same_persistence(*plan.previous,plan.package))
            plan.diagnostics.push_back({ir::Layer::verification,"persist-change-unverified",
                "Persist mapping differs from the installed version; data migration is not verified, so the update is refused"});
    } else if (action != ir::Action::reset) {
        plan.package = read_installed();
        if (!version.empty() && version != plan.package.version)
            plan.diagnostics.push_back({ir::Layer::environment,"installed-version-mismatch","Requested version is not the current local installation"});
    }
    if (action != ir::Action::uninstall) {
        // The IR planner resolves the declared dependency graph once. The plan carries the ordered
        // result, so preview, execution and the saved evidence cannot disagree about it.
        auto resolution = resolve_package_dependencies(context,plan.package,action != ir::Action::install);
        plan.dependencies = std::move(resolution.dependencies);
        for (const auto& diagnostic : resolution.diagnostics)
            plan.diagnostics.push_back(diagnostic);
        for (const auto& dependency : plan.dependencies) {
            if (dependency.installed) continue;
            plan.preconditions.push_back({fs::path(wide(dependency.package.manifest_path)),dependency.package.manifest_digest});
            // A dependency whose own IR has unresolved problems must not make the root plan look
            // executable. Execution refuses that dependency's plan, so preview reports the same
            // diagnostics at the parent level.
            for (const auto& diagnostic : dependency.diagnostics)
                plan.diagnostics.push_back(diagnostic);
        }
    }
    switch (action) {
    case ir::Action::install: plan.steps = ir::plan(ir::Action::install,plan.package,nullptr,true).steps; break;
    case ir::Action::update: plan.steps = ir::plan(ir::Action::update,plan.package,plan.previous ? &*plan.previous : nullptr,true).steps; break;
    case ir::Action::uninstall: plan.steps = ir::plan(ir::Action::uninstall,plan.package,nullptr,false).steps; break;
    case ir::Action::reset: plan.steps = ir::plan(ir::Action::reset,plan.package,plan.previous ? &*plan.previous : nullptr,true).steps; break;
    }
    if (plan.steps.empty()) {
        // An empty sequence is a contract violation, not a successful no-op: refuse it here so no
        // caller can present or execute a plan that carries no operations.
        plan.diagnostics.push_back({ir::Layer::validation,"empty-plan",
            "The IR planner produced no operation for this request; the plan cannot be executed"});
    }
    if (action == ir::Action::update || action == ir::Action::uninstall || action == ir::Action::reset) {
        const auto& installed_facts = (action == ir::Action::update || action == ir::Action::reset) && plan.previous ? *plan.previous : plan.package;
        std::vector<std::string> names;
        for (const auto& command : installed_facts.entries) names.push_back(command.alias);
        plan.scoop_entry_wrappers = scoop_entry_wrappers(context,installed_facts.name,names);
        // Entry files an older Coop build published for script aliases (its own launcher metadata
        // and the .shim view it used to write) are retired by this operation. They are added here
        // so the preview lists them and the preconditions cover them, instead of the executor
        // discovering them behind the plan's back.
        for (const auto& command : installed_facts.entries) {
            if (launcher_kind(fs::path(wide(command.target))) == LauncherKind::direct) continue;
            const bool shares_alias_with_direct = std::any_of(installed_facts.entries.begin(),installed_facts.entries.end(),
                [&](const ir::Entry& other) {
                    return equal_name(other.alias,command.alias) &&
                        launcher_kind(fs::path(wide(other.target))) == LauncherKind::direct;
                });
            for (const auto& suffix : {std::wstring(L".shim"),std::wstring(L".coop-shim.json"),std::wstring(L".coop-shim")}) {
                // The .shim of a shared alias belongs to the executable family and is removed as
                // that entry's metadata, not as a script wrapper.
                if (suffix == L".shim" && shares_alias_with_direct) continue;
                const auto legacy = context.root/L"shims"/(wide(command.alias)+suffix);
                std::error_code error;
                if (!fs::is_regular_file(legacy,error) || error) continue;
                if (!scoop_wrapper_belongs_to_package(legacy,installed_facts.name)) continue;
                plan.scoop_entry_wrappers.push_back(legacy);
            }
        }
        for (const auto& wrapper : plan.scoop_entry_wrappers)
            plan.preconditions.push_back({wrapper,sha256_file(wrapper)});
    }
    plan.preconditions.push_back({fs::path(wide(plan.package.manifest_path)),plan.package.manifest_digest});
    const auto registry = context.root/L".coop"/L"buckets.json";
    if (fs::exists(registry)) plan.preconditions.push_back({registry,sha256_file(registry)});
    plan.diagnostics.insert(plan.diagnostics.end(),plan.package.diagnostics.begin(),plan.package.diagnostics.end());
    if (action == ir::Action::uninstall) {
        collect_reverse_dependencies(context,plan);
        for (const auto& fact : ir::read_installations(context.root)) {
            if (equal_name(fact.name,plan.package.name)) continue;
            const auto manifest = installed_record(fact.directory,L"manifest");
            if (fs::is_regular_file(manifest)) plan.preconditions.push_back({manifest,sha256_file(manifest)});
            const auto record = context.root/L".coop"/L"packages"/(wide(fact.name)+L".json");
            if (fs::is_regular_file(record)) plan.preconditions.push_back({record,sha256_file(record)});
        }
    }
    // The version directory `current` publishes is the installed version, so the comparison needs no
    // second record: the same name on disk means the request would change nothing.
    plan.already_installed = action == ir::Action::install && plan.local.exists &&
        plan.local.directory.filename().wstring() == wide(plan.package.version);
    plan.blocker = execution_blocker(context,plan);
    return plan;
}
void recheck_plan(const Plan& plan) {
    for (const auto& input : plan.preconditions)
        if (input.sha256.empty() || sha256_file(input.path) != input.sha256)
            throw std::runtime_error("Plan input changed; generate a new plan");
    if (fs::is_directory(plan.local.current) != plan.local.exists ||
        (plan.local.exists && operating_path(fs::canonical(plan.local.current)) != plan.local.directory))
        throw std::runtime_error("Current installation changed; generate a new plan");
}
static Json describe_plan(const Context& context, const Plan& plan) {
    const auto action = plan.action;
    const fs::path argument_base = context.root/L"apps"/wide(plan.package.name)/L"current";
    auto package_description = package_json(context,plan.package);
    expand_package_arguments(context,plan.package.name,package_description,argument_base);
    Json result = {{"action",action_name(action)},{"package",std::move(package_description)},
        {"manifest_sha256",plan.package.manifest_digest},{"execution_available",plan.executable()},
        {"external_tools",external_tools_json(context,plan.package)},
        {"artifacts",Json::array()},{"preconditions",Json::array()},
        {"diagnostics",Json::array()},{"warnings",Json::array()}};
    result["local_facts"] = {{"current",path_text(plan.local.current)},{"exists",plan.local.exists},{"current_directory",path_text(plan.local.directory)}};
    // The preview states the no-op verdict too, so --dry-run never promises a write that install
    // would refuse to perform.
    result["already_installed"] = plan.already_installed;
    if (plan.already_installed) result["status"] = "already-installed";
    if (plan.global_installation) result["global_installation"] = {{"scope","global"},{"read_only",true},
        {"directory",path_text(*plan.global_installation)}};
    result["scoop_entry_wrappers"] = Json::array();
    for (const auto& wrapper : plan.scoop_entry_wrappers)
        result["scoop_entry_wrappers"].push_back(path_text(wrapper));
    const auto persistence_directory = (action == ir::Action::install || action == ir::Action::update || action == ir::Action::reset)
        ? context.root/L"apps"/wide(plan.package.name)/wide(plan.package.version) : plan.local.directory;
    result["persistence"] = persistence_plan_json(context,plan.package.name,plan.package.persistence,persistence_directory);
    if (action == ir::Action::update || action == ir::Action::uninstall)
        result["retained_versions"] = retained_versions(context,plan.package.name,plan.package.version);
    if (action == ir::Action::reset) {
        result["current_version"] = plan.previous ? plan.previous->version : std::string{};
        result["retained_versions"] = retained_versions(context,plan.package.name,plan.package.version);
        result["local_version_reference"] = {{"directory",path_text(persistence_directory)},
            {"manifest",plan.package.manifest_path},{"network","none"},
            {"download_url_guessed",false},{"lifecycle_hooks","not-run"},{"declared_installer_program","not-run"},
            {"data_rollback","none"}};
    }
    Json purge = {{"requested",plan.purge},{"status",plan.purge ? "planned" : "not-requested"},{"scope",Json::array()}};
    if (plan.purge && action != ir::Action::uninstall) {
        purge["status"] = "blocked";
        purge["reason"] = "--purge is only supported by uninstall";
    } else if (plan.purge) {
        // The purge scope comes from the installed package's own declarations and the verified
        // links; a Coop private record is not a precondition for removing declared data.
        try {
            purge["scope"] = purge_scope(context,plan.package,plan.local.directory);
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
    if (action == ir::Action::install) {
        Json requested = {{"package",plan.package.name},
            {"request",plan.package.bucket.empty() ? plan.package.name : plan.package.bucket+"/"+plan.package.name},
            {"bucket",plan.package.bucket},{"version",plan.package.version},{"installed",plan.local.exists},
            {"status",plan.local.exists ? "satisfied" : "planned"},{"requested",true},
            {"dependencies",declared_json(plan.package.dependencies)},
            {"ir_operations",steps_json(plan.steps)},{"diagnostics",Json::array()}};
        result["dependency_order"].push_back(std::move(requested));
    }
    Json planned = Json::array();
    for (const auto& item : plan.dependencies)
        if (!item.installed) planned.push_back(item.name);
    if (action == ir::Action::install && !plan.local.exists) planned.push_back(plan.package.name);
    result["planned_dependencies"] = std::move(planned);
    const fs::path exposure_base = (action == ir::Action::install || action == ir::Action::update)
        ? context.root/L"apps"/wide(plan.package.name)/L"current"
        : action == ir::Action::reset ? context.root/L"apps"/wide(plan.package.name)/wide(plan.package.version)
        : plan.local.directory;
    result["exposure"] = exposure_plan_json(context,plan.package,exposure_base);
    // A psmodule package exposes one shared module link. An update that drops the declaration (or
    // an uninstall) plans the removal instead, so the preview never hides what will disappear.
    const ir::Package* psmodule_package = nullptr;
    if (plan.package.psmodule) psmodule_package = &plan.package;
    else if (plan.previous && plan.previous->psmodule) psmodule_package = &*plan.previous;
    if (psmodule_package) {
        const bool removal = action == ir::Action::uninstall || !plan.package.psmodule;
        result["ps_module"] = ps_module_plan_json(context,psmodule_package->psmodule->name,
            context.root/L"apps"/wide(psmodule_package->name)/L"current",removal);
    } else {
        result["ps_module"] = Json(nullptr);
    }
    if ((action == ir::Action::update || action == ir::Action::uninstall) && plan.local.exists) {
        Json missing = Json::array();
        for (const auto& shortcut : plan.package.shortcuts)
            if (!fs::is_regular_file(shortcut_link_path(context,shortcut.name))) missing.push_back(shortcut.name);
        result["exposure"]["missing_shortcuts"] = missing;
    }
    result["lifecycle_checks"] = {{"install","unverified"},{"update","unverified"},{"uninstall","unverified"}};
    if (!plan.package.diagnostics.empty()) {
        result["lifecycle_checks"]["install"] = "known-unsupported-or-invalid";
        result["lifecycle_checks"]["uninstall"] = "known-unsupported-or-invalid";
    }
    if (!plan.package.hooks.empty()) {
        const auto host = script_host();
        if (!host.problem.empty()) {
            result["lifecycle_checks"]["install"] = "known-unsupported-or-invalid";
            result["lifecycle_checks"]["uninstall"] = "known-unsupported-or-invalid";
        } else {
            result["lifecycle_checks"]["hooks"] = "real PowerShell host with the pinned Scoop compatibility library (script text is not whitelisted)";
        }
    }
    if (plan.previous && !plan.previous->hooks.empty() && !script_host().problem.empty())
        result["lifecycle_checks"]["update"] = "known-unsupported-or-invalid";
    if (has_msi_artifact(plan.package) || (plan.previous && has_msi_artifact(*plan.previous)))
        result["lifecycle_checks"]["msi_extraction"] = "read-only Windows Installer database plus the Windows cabinet decompression API; no elevation, reboot, msiexec process or machine-cache write";
    if (has_inno_artifact(plan.package) || (plan.previous && has_inno_artifact(*plan.previous))) {
        const auto helper = inno_helper(context);
        result["lifecycle_checks"]["inno_setup"] = helper.path.empty() ? helper.problem :
            "declared external innounp helper "+path_text(helper.path)+
            " with Scoop's Expand-InnoArchive arguments; the vendor installer is never run and no elevation or reboot is requested";
    }
    if (has_nsis_payload(plan.package) || (plan.previous && has_nsis_payload(*plan.previous))) {
        const auto helper = nsis_helper(context);
        result["lifecycle_checks"]["nsis_extraction"] = helper.path.empty() ? helper.problem :
            "declared external 7-Zip helper "+path_text(helper.path)+
            " with Scoop's Expand-7zipArchive arguments for a content-detected NSIS installer payload; other payloads stay on the native archive reader, the vendor setup.exe is never run and no elevation or reboot is requested";
    }
    if (plan.previous) {
        result["previous_package"] = package_json(context,*plan.previous);
        expand_package_arguments(context,plan.previous->name,result["previous_package"],
            context.root/L"apps"/wide(plan.previous->name)/L"current");
    }
    for (const auto& item : plan.package.downloads) {
        Json artifact = {{"archive",ir::archive_format_name(item.format)},{"url",item.url},{"filename",item.filename},
            {"algorithm",ir::digest_algorithm_name(item.digest.algorithm)},{"digest",item.digest.value},
            {"hash",std::string(ir::digest_algorithm_name(item.digest.algorithm))+":"+item.digest.value},
            {"renamed",item.renamed},{"extract_dir",item.extract_directory},
            {"extract_to",item.extract_destination}};
        if (item.format == ir::ArchiveFormat::msi) {
            artifact["extraction"] = "read-only-msi-image";
            artifact["requires_elevation"] = false;
            artifact["reboot_required"] = false;
        } else if (item.format == ir::ArchiveFormat::inno_setup) {
            artifact["extraction"] = "external-innounp";
            artifact["requires_elevation"] = false;
            artifact["reboot_required"] = false;
            artifact["vendor_installer_executed"] = false;
            artifact["inno_selection"] = "-c"+inno_selection(item.extract_directory);
        } else if (item.installer_payload) {
            artifact["extraction"] = "native-archive-or-external-7zip-nsis";
            artifact["requires_elevation"] = false;
            artifact["reboot_required"] = false;
            artifact["vendor_installer_executed"] = false;
            artifact["payload_check"] = "after digest verification: an NSIS installer payload uses the declared external 7-Zip helper with Scoop's Expand-7zipArchive arguments, and every other payload stays with the native archive reader";
        }
        // Keep the historical key only for genuine SHA256 artifacts. A SHA512 value must never be
        // labelled sha256.
        if (item.digest.algorithm == ir::DigestAlgorithm::sha256) artifact["sha256"] = item.digest.value;
        result["artifacts"].push_back(std::move(artifact));
    }
    Json capabilities = Json::array();
    for (const auto& item : plan.package.capabilities)
        capabilities.push_back({{"id",item.id},{"supported",item.supported},{"detail",item.detail}});
    result["capabilities"] = std::move(capabilities);
    for (const auto& item : plan.preconditions) result["preconditions"].push_back({{"path",path_text(item.path)},{"sha256",item.sha256}});
    // Preview and execution report the same IR operation sequence; there is no second operation
    // list, so a displayed plan cannot drift from the one the executor consumes.
    result["ir_operations"] = steps_json(plan.steps);
    static const char* categories[] = {"syntax","adapter","ir","environment","capability","verification"};
    for (const auto& item : plan.diagnostics) result["diagnostics"].push_back({{"category",categories[static_cast<int>(item.layer)]},{"code",item.code},{"message",item.message}});
    // A warning is a source observation, not a gap: it never changes diagnostics, the exit code or
    // execution_available, but it stays visible wherever a plan is reviewed.
    for (const auto& item : plan.package.warnings)
        result["warnings"].push_back({{"category",categories[static_cast<int>(item.layer)]},{"code",item.code},{"message",item.message}});
    if (!plan.blocker.empty()) result["diagnostics"].push_back({{"category","capability"},{"code","execution-blocked"},{"message",plan.blocker}});
    result["diagnostics"].push_back({{"category","verification"},{"code","lifecycle-verification"},{"message","Native lifecycle coverage: single-file, multi-artifact, renamed-artifact, ZIP, tar, 7z, MSI, Inno Setup and NSIS installer-payload archive packages, including packages that combine pre_install/installer/post_install scripts with declared installer/uninstaller programs; MSI artifacts are extracted from a read-only Windows Installer database view with the Windows cabinet decompression API (administrative image layout, no msiexec process, no product registration, no elevation, no reboot and no %WINDIR%\\Installer machine-cache write; external cabinets are reported as unsupported); Inno Setup .exe artifacts are unpacked by the separately installed innounp helper with Scoop's Expand-InnoArchive arguments and layout (the vendor installer is never executed, the helper is detected and never downloaded, and its own [Run]/[Registry]/service/shortcut effects are outside the extraction); an executable self-extractor declared as an archive payload is inspected by content after verification and, when it is an NSIS installer, unpacked by the separately installed 7-Zip helper with Scoop's Expand-7zipArchive arguments (ordinary 7z, ZIP and tar payloads stay native, the vendor setup.exe is never executed, and the helper is detected and never downloaded); declared SHA256, SHA512, SHA1 and MD5 digests, architecture-specific Manifest sections, persist mappings, installed dependencies, EXE/COM/BAT/CMD/PS1/JAR/PY command entries and Scoop's bash else-branch (extensionless, .config and other targets) with argument forwarding, Windows shortcuts and declared environment exposure in the current user's persistent environment plus Coop command processes are supported, while persist mapping changes remain unverified; every declared lifecycle hook (pre_install, installer, post_install, pre_uninstall, uninstaller, post_uninstall) runs as trusted script text in a real PowerShell host that loads the pinned Scoop compatibility library (v0.6.0) with the Scoop context and helpers, so script text is not whitelisted and a legitimate Manifest edit still executes, while declared installer/uninstaller programs run through the same real PowerShell host and pinned Scoop Invoke-Installer with the $dir/$global/$version argument substitution, keep semantics and external side effects Coop never claims to roll back"}});
    return result;
}
struct PackageOutcome {
    bool failed = false;
    std::string status;
    std::string reason;
    Json value = Json::object();
};
std::string first_diagnostic(const std::vector<ir::Diagnostic>& diagnostics) {
    return diagnostics.empty() ? std::string{} : diagnostics.front().message;
}
// Interactive output keeps the observation visible; JSON consumers read `warnings` instead so the
// machine-readable contract is not mixed with human-readable lines.
void print_warnings(const Context& context, const ir::Package& package) {
    if (context.json_output) return;
    for (const auto& warning : package.warnings) std::cerr << "coop: warning: " << warning.message << '\n';
}
void print_json(const Json& value) {
    std::cout << value.dump(2,' ',false,Json::error_handler_t::replace) << '\n';
}
PackageOutcome install_preview(const Context& context, const std::string& request, const std::string& architecture) {
    PackageOutcome outcome;
    try {
        auto plan = make_plan(context,ir::Action::install,request,architecture);
        print_warnings(context,plan.package);
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
    plan.action = ir::Action::install;
    plan.package = item.package;
    plan.dependencies = order;
    plan.local.current = context.root/L"apps"/wide(item.name)/L"current";
    plan.steps = item.steps;
    plan.preconditions.push_back({fs::path(wide(plan.package.manifest_path)),plan.package.manifest_digest});
    for (const auto& diagnostic : item.diagnostics) plan.diagnostics.push_back(diagnostic);
    plan.blocker = execution_blocker(context,plan);
    return plan;
}
PackageOutcome install_execute_plan(const Context& context, const Plan& plan, const std::string& request) {
    PackageOutcome outcome;
    Json packages = Json::array();
    Json root_result;
    if (!plan.executable()) {
        outcome.failed = true;
        outcome.status = "failed";
        outcome.reason = plan.blocker;
        outcome.value = Json{{"package",request},{"action","install"},{"status","failed"},{"reason",plan.blocker}};
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
    if (plan.global_installation) root_result["global_installation"] = {{"scope","global"},{"read_only",true},
        {"directory",path_text(*plan.global_installation)}};
    root_result["transaction_scope"] = "per-package; completed dependency installs are not rolled back when a later package fails";
    if (!outcome.failed) outcome.status = "success";
    outcome.value = root_result;
    return outcome;
}
PackageOutcome install_execute(const Context& context, const std::string& request, const std::string& architecture) {
    PackageOutcome outcome;
    try { return install_execute_plan(context,make_plan(context,ir::Action::install,request,architecture),request); }
    catch (const std::exception& error) {
        outcome.failed = true;
        outcome.status = "failed";
        outcome.reason = error.what();
        outcome.value = Json{{"package",request},{"action","install"},{"status","failed"},{"reason",error.what()}};
        return outcome;
    }
}
Plan prepared_simple_plan(const Context& context, ir::Action action, const std::string& request, const std::string& architecture, bool purge = false) {
    return make_plan(context,action,request,architecture,purge);
}
PackageOutcome simple_preview(const Context& context, ir::Action action, const std::string& request, const std::string& architecture, bool purge = false) {
    PackageOutcome outcome;
    try {
        auto plan = prepared_simple_plan(context,action,request,architecture,purge);
        print_warnings(context,plan.package);
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
PackageOutcome simple_execute(const Context& context, ir::Action action, const std::string& request, const std::string& architecture, bool purge = false) {
    PackageOutcome outcome;
    try {
        auto plan = prepared_simple_plan(context,action,request,architecture,purge);
        print_warnings(context,plan.package);
        if (!plan.executable()) {
            outcome.failed = true;
            outcome.status = "failed";
            outcome.reason = plan.blocker;
            outcome.value = Json{{"package",plan.package.name},{"action",action_name(action)},{"status","failed"},{"reason",outcome.reason}};
            return outcome;
        }
        auto result = execute_plan_result(context,plan);
        const auto partial = result.value("status",std::string{}) == "partial";
        outcome.failed = partial;
        outcome.status = partial ? "partial" : "success";
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
    auto plan = make_plan(context,ir::Action::install,request,architecture);
    print_warnings(context,plan.package);
    if (!plan.executable()) throw std::runtime_error(plan.blocker);
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
    else {
        for (const auto& item : results) {
            std::cout << item.value("package",std::string{}) << ": " << item.value("status",std::string{}) << '\n';
            if (item.contains("reason")) std::cerr << "coop: " << item.at("reason").get<std::string>() << '\n';
        }
    }
    return failed ? 1 : 0;
}
int simple_single(const Context& context, ir::Action action, const std::string& request, const std::string& architecture, bool dry_run, bool purge = false) {
    if (dry_run) {
        const auto outcome = simple_preview(context,action,request,architecture,purge);
        print_json(outcome.value);
        return outcome.failed ? 1 : 0;
    }
    auto plan = prepared_simple_plan(context,action,request,architecture,purge);
    if (!plan.executable()) throw std::runtime_error(plan.blocker);
    return execute_plan(context,plan);
}
int simple_batch(const Context& context, ir::Action action, const std::vector<std::wstring>& names, const std::string& architecture, bool dry_run, bool purge = false) {
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
        // A batch reports each package as it finishes; a buffered batch looks hung for the whole run.
        if (!context.json_output) {
            std::cout << request << ": " << outcome.status << '\n';
            if (!outcome.reason.empty()) std::cerr << "coop: " << outcome.reason << '\n';
            std::cout.flush();
        }
    }
    if (context.json_output) print_json(results);
    return failed ? 1 : 0;
}
int package_command(const Context& context, const std::wstring& command, const std::vector<std::wstring>& args, const std::string& architecture) {
    bool dry_run = false;
    bool purge = false;
    std::vector<std::wstring> names;
    for (const auto& arg : args) {
        if (arg == L"--dry-run") {
            if (dry_run) throw UsageError("--dry-run was specified more than once");
            dry_run = true;
        } else if (arg == L"--purge") {
            if (purge) throw UsageError("--purge was specified more than once");
            purge = true;
        } else if (arg.starts_with(L"--")) throw UsageError("Unknown package option: "+utf8(arg));
        else names.push_back(arg);
    }
    if (command == L"cleanup") {
        if (purge) throw UsageError("--purge is only supported by uninstall");
        return cleanup_command(context,names,dry_run);
    }
    if (purge && command != L"uninstall") throw UsageError("--purge is only supported by uninstall");
    if (names.empty()) throw UsageError("Use one or more packages [--dry-run]");
    if (purge && names.size() > 1) throw UsageError("--purge accepts one package at a time");
    const auto action = command == L"install" ? ir::Action::install : command == L"update" ? ir::Action::update :
        command == L"reset" ? ir::Action::reset : ir::Action::uninstall;
    if (action == ir::Action::install) return names.size() > 1
        ? install_batch(context,names,architecture,dry_run)
        : install_single(context,utf8(names.front()),architecture,dry_run);
    if (names.size() > 1) return simple_batch(context,action,names,architecture,dry_run,purge);
    return simple_single(context,action,utf8(names.front()),architecture,dry_run,purge);
}
}
