#include "package.hpp"
#include "data.hpp"
#include "native.hpp"
#include "archive.hpp"
#include "persist.hpp"
#include "versions.hpp"
#include "exposure.hpp"
#include "script.hpp"
#include <windows.h>
#include <array>
#include <cctype>
#include <iostream>
#include <stdexcept>
#include <algorithm>
#include <iterator>

namespace coop {
namespace {
void ordinary_parents(const fs::path& root, const fs::path& path) {
    const auto relative = path.lexically_relative(root);
    if (relative.empty() || relative.is_absolute()) throw std::runtime_error("Operation outside selected root");
    auto current = root;
    for (const auto& part : relative) {
        validate_component(path_text(part));
        current /= part;
        const auto attributes = GetFileAttributesW(current.c_str());
        if (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_REPARSE_POINT))
            throw std::runtime_error("Managed destination contains a reparse point");
    }
}
void erase_tree(const fs::path& path) {
    const auto attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES) return;
    if (attributes & FILE_ATTRIBUTE_REPARSE_POINT) {
        if (attributes & FILE_ATTRIBUTE_DIRECTORY) {
            if (!RemoveDirectoryW(path.c_str())) throw std::runtime_error("Cannot unlink managed junction");
        } else if (!DeleteFileW(path.c_str())) throw std::runtime_error("Cannot unlink managed file");
        return;
    }
    if (attributes & FILE_ATTRIBUTE_DIRECTORY) for (const auto& entry : fs::directory_iterator(path)) erase_tree(entry.path());
    if (!fs::remove(path)) throw std::runtime_error("Cannot remove managed path");
}
void require_capabilities(const Package& package) {
    if (!package.diagnostics.empty()) throw std::runtime_error("Manifest has unsupported or invalid requirements; inspect --dry-run");
    if (package.artifacts.empty()) throw std::runtime_error("Package has no install artifacts");
    if (package.installer || package.uninstaller)
        throw std::runtime_error("installer/uninstaller process declarations (installer.file/args) are not enabled; no fixed sample requires them, and a failed external program cannot be rolled back safely");
    const auto scripts = check_package_scripts(package);
    if (!scripts.compatible()) {
        const auto messages = scripts.messages();
        throw std::runtime_error("Lifecycle hook script is outside the proven PowerShell subset: "+
            (messages.empty() ? std::string("unknown script capability") : messages.front()));
    }
    if (!package.scripts.empty() && !powershell_interpreter())
        throw std::runtime_error("A PowerShell runtime (pwsh.exe or Windows PowerShell) is required for lifecycle hook scripts");
    const auto lower_name = [](std::string value) {
        for (auto& character : value) character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
        return value;
    };
    for (const auto& artifact : package.artifacts) {
        switch (artifact.archive) {
        case ArchiveKind::none:
        case ArchiveKind::zip:
            break;
        case ArchiveKind::tar: {
            const auto name = lower_name(artifact.filename);
            const bool supported = name.ends_with(".tar") || name.ends_with(".tar.gz") || name.ends_with(".tgz") ||
                name.ends_with(".tar.xz") || name.ends_with(".txz");
            if (!supported) throw std::runtime_error("This tar compression is not supported; only .tar, .tar.gz, .tgz, .tar.xz and .txz are enabled");
            break;
        }
        case ArchiveKind::seven_zip:
            break;
        case ArchiveKind::msi:
            if (!msi_installer())
                throw std::runtime_error("MSI extraction requires Windows Installer (msiexec.exe), which was not found; Coop does not download or install external tools automatically. MSI administrative extraction is also blocked because Windows Installer writes its machine cache under %WINDIR%\\Installer outside the selected project root");
            throw std::runtime_error("MSI administrative extraction is blocked because Windows Installer writes its machine cache under %WINDIR%\\Installer outside the selected project root; an isolated extraction mechanism needs explicit human approval");
        }
    }
    for (const auto& command : package.commands)
        if (!launcher_kind(command.target))
            throw std::runtime_error("Command entry target type is not supported: "+path_text(command.target)+
                "; supported entries are EXE, COM, BAT, CMD, PS1 and JAR");
}
fs::path record_relative_path(const std::string& value) {
    fs::path path(wide(value));
    if (path.empty() || path.is_absolute() || path.has_root_name() || path.has_root_directory())
        throw std::runtime_error("Managed command target is not a package-relative path");
    for (const auto& part : path) validate_component(path_text(part));
    return path.lexically_normal();
}
void verify_installed_files(const Json& managed, const fs::path& directory, const Package& installed) {
    if (managed.contains("command_targets") && managed.at("command_targets").is_array()) {
        for (const auto& command : installed.commands) {
            const auto entry = std::find_if(managed.at("command_targets").begin(),managed.at("command_targets").end(),[&](const Json& item) {
                return item.is_object() && equal_name(item.value("path",std::string{}),path_text(command.target));
            });
            if (entry == managed.at("command_targets").end()) throw std::runtime_error("Managed command target record is missing");
            const auto target = directory/record_relative_path(entry->at("path").get<std::string>());
            if (!fs::is_regular_file(target)) throw std::runtime_error("Managed command target is missing");
            if (sha256_file(target) != entry->at("sha256").get<std::string>()) throw std::runtime_error("Managed command target changed; refusing operation");
        }
        return;
    }
    const auto artifact = directory/wide(installed.artifacts.front().filename);
    if (sha256_file(artifact) != installed.artifacts.front().sha256) throw std::runtime_error("Installed executable changed; refusing operation");
}
bool verify_shortcut_ownership(const Json& managed, const ShortcutExposure& shortcut, const fs::path& link, bool legacy) {
    std::string expected;
    fs::path recorded;
    if (legacy) {
        if (!managed.contains("legacy_shortcuts") || !managed.at("legacy_shortcuts").is_object() ||
            !managed.at("legacy_shortcuts").contains(shortcut.name))
            throw std::runtime_error("Managed legacy shortcut record is missing");
        const auto& entry = managed.at("legacy_shortcuts").at(shortcut.name);
        recorded = fs::path(wide(entry.at("path").get<std::string>()));
        expected = entry.at("sha256").get<std::string>();
    } else {
        const auto entries = managed.value("shortcuts",Json::array());
        const auto found = std::find_if(entries.begin(),entries.end(),[&](const Json& item) {
            return item.is_object() && equal_name(item.value("name",std::string{}),shortcut.name);
        });
        if (found == entries.end()) throw std::runtime_error("Managed shortcut record is missing");
        recorded = fs::path(wide(found->at("path").get<std::string>()));
        expected = found->at("sha256").get<std::string>();
    }
    // A shortcut removed outside Coop is already revoked: there is nothing left to own or
    // protect, so update/uninstall records the observation and continues. A shortcut that is
    // still present but changed is still refused below.
    if (!fs::is_regular_file(link)) return false;
    if (!same_identity(recorded,link)) throw std::runtime_error("Managed shortcut path changed");
    if (sha256_file(link) != expected)
        throw std::runtime_error("Shortcut was modified externally; refusing to remove or replace it: "+path_text(link));
    return true;
}
void prune_empty_shortcut_directories(const Context& context, const std::vector<fs::path>& links) {
    const auto base = shortcut_directory(context).lexically_normal();
    for (const auto& link : links) {
        auto directory = link.parent_path().lexically_normal();
        for (;;) {
            const auto relative = directory.lexically_relative(base);
            if (relative.empty() || relative.is_absolute() || relative == L".") break;
            if (relative.begin() != relative.end() && *relative.begin() == L"..") break;
            std::error_code error;
            if (!fs::is_directory(directory,error) || error) break;
            if (!fs::is_empty(directory,error) || error) break;
            if (!fs::remove(directory,error) || error) break;
            directory = directory.parent_path();
        }
    }
}
void publish_new(const fs::path& source, const fs::path& destination) {
    DWORD error = ERROR_SUCCESS;
    // Antivirus scanners and just-exited programs can hold a published file briefly. Retry
    // within a bounded window instead of killing a user process or claiming a false success.
    for (int attempt = 0; attempt < 15; ++attempt) {
        if (MoveFileExW(source.c_str(),destination.c_str(),MOVEFILE_WRITE_THROUGH)) return;
        error = GetLastError();
        if (error != ERROR_SHARING_VIOLATION && error != ERROR_LOCK_VIOLATION && error != ERROR_ACCESS_DENIED) break;
        Sleep(200);
    }
    throw std::runtime_error("Destination cannot be published (Windows error "+std::to_string(error)+"); close the program and retry");
}
bool path_is_under(const fs::path& path, const fs::path& base) {
    const auto normalized = path.lexically_normal();
    const auto normalized_base = base.lexically_normal();
    auto entry = normalized.begin();
    for (auto base_entry = normalized_base.begin(); base_entry != normalized_base.end(); ++base_entry,++entry) {
        if (entry == normalized.end() ||
            CompareStringOrdinal(entry->c_str(),-1,base_entry->c_str(),-1,TRUE) != CSTR_EQUAL) return false;
    }
    return entry != normalized.end();
}
// Journal paths are absolute. Recovery accepts only Coop's root and the isolated shortcut
// directory, rejects parent reparse points, and permits a reparse point only as the final
// managed junction (for example apps/<package>/current).
bool recovery_path_allowed(const Context& context, const fs::path& path) {
    if (path.empty() || !path.is_absolute()) return false;
    // Journal paths are only trusted inside the managed subtrees that the execution protocol
    // writes. Requiring the expected depth prevents a corrupt journal from naming "apps" or a
    // whole package directory as a created path and deleting more than one transaction owns.
    const std::vector<std::pair<fs::path,std::size_t>> roots = {
        {context.root/L"apps",2},
        {context.root/L"shims",1},
        {context.root/L".coop"/L"packages",1},
        {context.root/L".coop"/L"transactions",2},
        {context.root/L".coop"/L"retained",1},
        {shortcut_directory(context),1}};
    fs::path base;
    std::size_t minimum = 0;
    std::size_t best = 0;
    for (const auto& [root,depth] : roots) {
        if (!path_is_under(path,root)) continue;
        const auto normalized_root = root.lexically_normal();
        const auto size = static_cast<std::size_t>(std::distance(normalized_root.begin(),normalized_root.end()));
        if (base.empty() || size > best) { base = root; best = size; minimum = depth; }
    }
    if (base.empty()) return false;
    const auto normalized = path.lexically_normal();
    const auto normalized_base = base.lexically_normal();
    auto entry = normalized.begin();
    for (auto base_entry = normalized_base.begin(); base_entry != normalized_base.end(); ++base_entry) ++entry;
    if (static_cast<std::size_t>(std::distance(entry,normalized.end())) < minimum) return false;
    auto current = base;
    for (; entry != normalized.end(); ++entry) {
        validate_component(path_text(*entry));
        current /= *entry;
        const auto attributes = GetFileAttributesW(current.c_str());
        if (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_REPARSE_POINT) &&
            std::next(entry) != normalized.end()) return false;
    }
    return true;
}
bool same_path_text(const fs::path& a, const fs::path& b) {
    const auto left = a.lexically_normal().wstring();
    const auto right = b.lexically_normal().wstring();
    return CompareStringOrdinal(left.c_str(),-1,right.c_str(),-1,TRUE) == CSTR_EQUAL;
}
}
std::string package_execution_blocker(const Package& package) {
    try { require_capabilities(package); } catch (const std::exception& error) { return error.what(); }
    return {};
}
std::string execution_blocker(const Context& context, const Plan& plan) {
    if (plan.action == Action::adopt) {
        if (plan.adoption && plan.adoption->eligibility == AdoptionEligibility::already_managed) return {};
        for (const auto& dependency : plan.package.dependencies)
            if (!dependency_is_installed(context,dependency))
                return "Declared dependency is not installed: "+dependency;
        if (!plan.adoption || plan.adoption->eligibility != AdoptionEligibility::eligible)
            return "Package is not eligible for in-place adoption; inspect --dry-run";
        return {};
    }
    if (plan.action != Action::install && plan.action != Action::uninstall && plan.action != Action::update) return "This action is not executable yet";
    try {
        require_capabilities(plan.package);
        if (plan.previous) require_capabilities(*plan.previous);
    } catch (const std::exception& error) { return error.what(); }
    if (plan.action == Action::update && plan.previous && !same_persistence(*plan.previous,plan.package))
        return "Persistence mapping changes are not verified; refusing to update declared data";
    if (plan.action == Action::update || plan.action == Action::uninstall) {
        try { verify_persistence(context,plan.action == Action::update ? *plan.previous : plan.package,plan.local.directory); }
        catch (const std::exception& error) { return std::string("Managed persistence state cannot be verified: ")+error.what(); }
    }
    if (plan.purge) {
        if (plan.action != Action::uninstall) return "--purge is only supported by uninstall";
        const auto record = context.root/L".coop"/L"packages"/(wide(plan.package.name)+L".json");
        if (!fs::is_regular_file(record)) return "Package is unadopted; purge is refused";
        try {
            const auto managed = read_json(record);
            purge_scope(context,plan.package,plan.local.directory,managed.value("persistence",Json::array()));
        } catch (const std::exception& error) {
            return std::string("Purge scope cannot be verified: ")+error.what();
        }
    }
    if (plan.action == Action::install || plan.action == Action::update) {
        for (const auto& dependency : plan.package.dependencies) {
            const auto name = dependency_package_name(dependency);
            const bool planned = std::any_of(plan.planned_dependencies.begin(),plan.planned_dependencies.end(),[&](const std::string& item) {
                return equal_name(item,name) || equal_name(item,dependency);
            });
            if (!planned && !dependency_is_installed(context,dependency))
                return "Declared dependency is not installed: "+dependency;
        }
    }
    if (!plan.blocking_dependents.empty()) return "Installed packages still depend on this package: "+plan.blocking_dependents.front();
    if (!plan.unverified_dependents.empty()) return "Dependency evidence is incomplete for installed packages: "+plan.unverified_dependents.front();
    if (!plan.diagnostics.empty()) return "Plan has unresolved diagnostics";
    if (plan.action == Action::install && plan.local.exists) return "Package already exists; use adoption or update";
    if ((plan.action == Action::uninstall || plan.action == Action::update) && !fs::exists(context.root/L".coop"/L"packages"/(wide(plan.package.name)+L".json")))
        return "Package is unadopted; update/uninstall is refused";
    return {};
}
int execute_plan(const Context& context, const Plan& plan) {
    if (plan.purge && plan.action == Action::uninstall && !context.json_output) {
        try {
            const auto record = context.root/L".coop"/L"packages"/(wide(plan.package.name)+L".json");
            const auto managed = read_json(record);
            const auto scope = purge_scope(context,plan.package,plan.local.directory,
                managed.value("persistence",Json::array()));
            std::cout << "Purge scope (declared persistent data only):\n";
            for (const auto& entry : scope) std::cout << "  " << entry.at("store").get<std::string>() << '\n';
        } catch (const std::exception&) {
            // The execution blocker reports the same verification failure without deleting data.
        }
    }
    const auto result = execute_plan_result(context,plan);
    if (plan.action == Action::adopt) {
        std::cout << result.dump(2) << '\n';
        return 0;
    }
    const bool partial = result.value("status",std::string{}) == "partial";
    if (context.json_output) {
        std::cout << result.dump(2) << '\n';
        return partial ? 1 : 0;
    }
    if (result.value("status",std::string{}) == "up-to-date") {
        std::cout << plan.package.name << ": up-to-date\n";
        return 0;
    }
    if (partial) {
        std::cout << plan.package.name << ": partial\n";
        std::cerr << "coop: " << result.value("reason",std::string("Operation did not fully complete")) << '\n';
        for (const auto& entry : result.value("purge",Json::object()).value("failed",Json::array()))
            std::cerr << "coop: " << entry.value("store",std::string{}) << ": " << entry.value("reason",std::string{}) << '\n';
        return 1;
    }
    std::cout << plan.package.name << ": success\n";
    if (plan.purge) {
        for (const auto& entry : result.value("purge",Json::object()).value("deleted",Json::array()))
            std::cout << "Deleted persisted data: " << entry.get<std::string>() << '\n';
        for (const auto& entry : result.value("purge",Json::object()).value("already_absent",Json::array()))
            std::cout << "Persisted data already absent: " << entry.get<std::string>() << '\n';
    } else {
        const Json persistence = result.contains("persistence") ? result.at("persistence") : Json::array();
        if (persistence.is_array() && !persistence.empty())
            std::cout << "Persistent data retained; old program versions and stored data are reported separately\n";
    }
    return 0;
}
Json execute_plan_result(const Context& context, const Plan& plan) {
    const auto blocker = execution_blocker(context,plan);
    if (!blocker.empty()) throw std::runtime_error(blocker);
    const auto& package = plan.package;
    const bool updating = plan.action == Action::update;
    const auto& installed = updating ? plan.previous.value() : package;
    const auto state = context.root/L".coop";
    const auto record_path = state/L"packages"/(wide(package.name)+L".json");
    const auto app = context.root/L"apps"/wide(package.name);
    const auto version = app/wide(package.version);
    const auto shims = context.root/L"shims";
    ordinary_parents(context.root,state);
    ordinary_parents(context.root,version);
    ordinary_parents(context.root,shims);
    ordinary_parents(context.root,record_path);
    RootLock lock(context.root);
    recheck_plan(plan);
    if (fs::exists(state/L"transactions")) for (const auto& entry : fs::directory_iterator(state/L"transactions")) {
        if (!entry.is_directory()) continue;
        const auto journal_path = entry.path()/L"journal.json";
        if (fs::exists(journal_path) && read_json(journal_path).value("state",std::string{}) == "pending") {
            if (plan.action == Action::adopt && recover_adoption(context,plan,journal_path)) continue;
            throw std::runtime_error("Pending transaction requires recovery: "+path_text(journal_path));
        }
    }
    if (plan.action == Action::adopt) return commit_adoption_result(context,plan);
    Json managed;
    Json persistence = Json::array();
    Json version_history = Json::array();
    Json purge_entries = Json::array();
    std::vector<FilePrecondition> owned_inputs;
    if (plan.action == Action::install) {
        if (plan.local.exists || fs::exists(version) || fs::exists(record_path)) throw std::runtime_error("Package already exists; use adoption or update");
    } else {
        if (!fs::exists(record_path)) throw std::runtime_error("Package is unadopted; update/uninstall is refused");
        managed = read_json(record_path);
        if (!same_identity(fs::path(wide(managed.at("directory").get<std::string>())),plan.local.directory) ||
            managed.at("manifest_sha256") != installed.manifest_sha256)
            throw std::runtime_error("Managed installation changed; refusing operation");
        verify_installed_files(managed,plan.local.directory,installed);
        persistence = verify_persistence(context,installed,plan.local.directory);
        if (plan.purge) purge_entries = purge_scope(context,installed,plan.local.directory,
            managed.value("persistence",Json::array()));
        version_history = managed.value("versions",Json::array());
        if (!version_history.is_array()) version_history = Json::array();
        if (plan.action == Action::update) {
            if (version_history.empty()) version_history = scan_version_evidence(app);
            const bool recorded = std::any_of(version_history.begin(),version_history.end(),[&](const Json& entry) {
                return entry.is_object() && equal_name(entry.value("version",std::string{}),installed.version);
            });
            if (!recorded) {
                const auto install_record = installed_record(plan.local.directory,L"install");
                version_history.push_back({{"version",installed.version},
                    {"directory",path_text(fs::canonical(plan.local.directory))},
                    {"manifest_sha256",installed.manifest_sha256},
                    {"install_record_sha256",fs::is_regular_file(install_record) ? sha256_file(install_record) : std::string{}},
                    {"tree_stamp",version_tree_stamp(plan.local.directory)},
                    {"provenance","previous-current"}});
            }
        }
        owned_inputs.push_back({record_path,sha256_file(record_path)});
        for (const auto& command : installed.commands) {
            const auto target = plan.local.directory/command.target;
            owned_inputs.push_back({target,sha256_file(target)});
        }
    }
    const bool legacy_record = managed.is_object() && managed.value("shim_format",std::string{}) == "scoop";
    for (const auto& command : installed.commands) {
        const auto exe = shims/(wide(command.name)+L".exe");
        const auto metadata = shims/(wide(command.name)+(legacy_record ? L".shim" : L".coop-shim.json"));
        if (plan.action == Action::install) {
            if (fs::exists(exe) || fs::exists(metadata)) throw std::runtime_error("Command entry conflicts with an existing file");
        } else {
            if (!fs::exists(exe) || !fs::exists(metadata)) throw std::runtime_error("Managed command entry is missing");
            ordinary_parents(context.root,exe);
            ordinary_parents(context.root,metadata);
            std::string executable_hash;
            if (legacy_record) {
                const auto& entry = managed.at("legacy_shims").at(command.name);
                executable_hash = entry.at("executable_sha256");
                if (sha256_file(metadata) != entry.at("metadata_sha256").get<std::string>()) throw std::runtime_error("Managed Scoop command metadata changed");
            } else {
                const auto entries = managed.value("commands",Json::array());
                const auto record = std::find_if(entries.begin(),entries.end(),[&](const Json& item) {
                    return item.is_object() && equal_name(item.value("name",std::string{}),command.name);
                });
                if (record == entries.end()) throw std::runtime_error("Managed command record is missing");
                const auto entry = read_json(metadata);
                executable_hash = record->at("launcher_sha256").get<std::string>();
                if (sha256_file(metadata) != record->at("metadata_sha256").get<std::string>()) throw std::runtime_error("Managed command metadata changed");
                if (!equal_name(entry.value("package",std::string{}),package.name) ||
                    !same_identity(fs::path(wide(entry.value("target",std::string{}))),app/L"current"/command.target) ||
                    entry.value("arguments",std::string{}) != command.arguments ||
                    entry.value("launcher",std::string{}) != command_launcher_name(command.target))
                    throw std::runtime_error("Managed command entry ownership changed");
            }
            if (sha256_file(exe) != executable_hash) throw std::runtime_error("Managed command launcher changed");
            owned_inputs.push_back({exe,executable_hash});
            owned_inputs.push_back({metadata,sha256_file(metadata)});
        }
    }
    std::vector<std::string> absent_shortcuts;
    for (const auto& shortcut : installed.shortcuts) {
        const auto link = shortcut_link_path(context,shortcut.name);
        if (plan.action == Action::install) {
            if (fs::exists(link)) throw std::runtime_error("Shortcut conflicts with an existing file: "+path_text(link));
            continue;
        }
        if (!verify_shortcut_ownership(managed,shortcut,link,legacy_record)) {
            absent_shortcuts.push_back(shortcut.name);
            continue;
        }
        owned_inputs.push_back({link,sha256_file(link)});
    }
    if (updating) {
        if (package.version == installed.version && package.manifest_sha256 == installed.manifest_sha256) {
            return Json{{"package",package.name},{"version",package.version},{"status","up-to-date"}};
        }
        if (fs::exists(version)) throw std::runtime_error("Target version already exists; it will not be overwritten");
        for (const auto& command : package.commands) {
            if (std::any_of(installed.commands.begin(),installed.commands.end(),[&](const CommandExposure& old) { return equal_name(old.name,command.name); })) continue;
            if (fs::exists(shims/(wide(command.name)+L".exe")) || fs::exists(shims/(wide(command.name)+L".coop-shim.json")))
                throw std::runtime_error("New command entry conflicts with an existing file");
        }
        for (const auto& shortcut : package.shortcuts) {
            if (std::any_of(installed.shortcuts.begin(),installed.shortcuts.end(),[&](const ShortcutExposure& old) { return equal_name(old.name,shortcut.name); })) continue;
            const auto link = shortcut_link_path(context,shortcut.name);
            if (fs::exists(link)) throw std::runtime_error("New shortcut conflicts with an existing file: "+path_text(link));
        }
    }
    const auto transaction = state/L"transactions"/(std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));
    ordinary_parents(context.root,transaction);
    fs::create_directories(transaction);
    Json journal = {{"state","pending"},{"package",package.name},{"action",updating ? "update" : plan.action == Action::install ? "install" : "uninstall"},
        {"created",Json::array()},{"moves",Json::array()},{"scripts",Json::array()},{"shortcuts_already_absent",absent_shortcuts}};
    const auto shortcut_was_absent = [&](const std::string& name) {
        return std::any_of(absent_shortcuts.begin(),absent_shortcuts.end(),[&](const std::string& item) { return equal_name(item,name); });
    };
    const auto save = [&]() { write_json(transaction/L"journal.json",journal); };
    std::vector<fs::path> owned;
    std::vector<std::pair<fs::path,fs::path>> moved;
    const auto create = [&](const fs::path& path, const auto& operation) {
        journal["created"].push_back({{"path",path_text(path)},{"owned",false}}); save();
        try { operation(); }
        catch (const std::exception& error) {
            journal["created"].back()["error"] = error.what();
            try { save(); } catch (...) { /* Preserve the original failure. */ }
            throw;
        }
        owned.push_back(path);
        journal["created"].back()["owned"] = true; save();
    };
    const auto publish_json = [&](const fs::path& destination, const Json& value) {
        const auto temporary = transaction/(L"json-"+std::to_wstring(journal["created"].size())+L".json");
        write_json(temporary,value);
        create(destination,[&]() { publish_new(temporary,destination); });
    };
    const auto move = [&](const fs::path& from, const fs::path& to) {
        journal["moves"].push_back({{"from",path_text(from)},{"to",path_text(to)},{"moved",false}}); save();
        try { publish_new(from,to); }
        catch (const std::exception& error) {
            journal["moves"].back()["error"] = error.what();
            try { save(); } catch (...) { /* Preserve the original failure. */ }
            throw;
        }
        moved.emplace_back(from,to);
        journal["moves"].back()["moved"] = true; save();
    };
    Json script_runs = Json::array();
    const auto run_scripts = [&](const Package& hooks, ScriptPhase phase, const fs::path& directory,
                                 const fs::path& original_directory, const char* command, bool previous) {
        for (std::size_t index = 0; index < hooks.scripts.size(); ++index) {
            if (hooks.scripts[index].phase != phase) continue;
            journal["scripts"].push_back({{"phase",script_phase_name(phase)},{"index",index},{"package",hooks.name},
                {"previous_package",previous},{"directory",path_text(directory)},{"command",command},{"status","running"},
                {"external_side_effects","unknown; effects outside the managed package and persist roots are not rolled back, and a failed hook is not re-run automatically"}});
            save();
            ScriptRun run;
            try { run = run_package_script(context,hooks,index,directory,original_directory,
                context.root/L"persist"/wide(hooks.name),transaction,command); }
            catch (const std::exception& error) {
                journal["scripts"].back()["status"] = "failed";
                journal["scripts"].back()["error"] = error.what();
                try { save(); } catch (...) { /* Preserve the original failure. */ }
                throw;
            }
            auto& record = journal["scripts"].back();
            record["status"] = run.exit_code == 0 ? "succeeded" : "failed";
            record["exit_code"] = run.exit_code;
            record["interpreter"] = path_text(run.interpreter);
            record["hook"] = path_text(run.hook_path);
            record["stdout_log"] = path_text(run.stdout_path);
            record["stderr_log"] = path_text(run.stderr_path);
            record["stdout_bytes"] = run.stdout_bytes;
            record["stderr_bytes"] = run.stderr_bytes;
            record["stdout_tail"] = script_json_text(run.stdout_tail);
            record["stderr_tail"] = script_json_text(run.stderr_tail);
            save();
            script_runs.push_back(record);
            if (run.exit_code != 0)
                throw std::runtime_error(std::string(script_phase_name(phase))+" hook failed with exit code "+
                    std::to_string(run.exit_code)+"; output was captured in "+path_text(run.stdout_path)+
                    " and "+path_text(run.stderr_path));
        }
    };
    save();
    try {
        if (plan.action == Action::install || updating) {
            const auto stage = transaction/L"payload";
            const auto downloads = transaction/L"downloads";
            fs::create_directories(stage);
            fs::create_directories(downloads);
            journal["stage"] = "downloading"; save();
            std::vector<fs::path> downloaded_files;
            for (std::size_t i = 0; i < package.artifacts.size(); ++i) {
                const auto& artifact = package.artifacts[i];
                const auto downloaded = downloads/(std::to_wstring(i)+L"-"+wide(artifact.filename));
                download_file(artifact.url,downloaded);
                if (sha256_file(downloaded) != artifact.sha256) throw std::runtime_error("Artifact SHA256 mismatch: "+artifact.filename);
                downloaded_files.push_back(downloaded);
            }
            recheck_plan(plan);
            for (const auto& input : owned_inputs)
                if (sha256_file(input.path) != input.sha256) throw std::runtime_error("Managed input changed during preparation; regenerate the plan");
            journal["stage"] = "extracting"; save();
            for (std::size_t i = 0; i < package.artifacts.size(); ++i) {
                const auto& artifact = package.artifacts[i];
                if (artifact.archive == ArchiveKind::none) {
                    const auto target = stage/wide(artifact.filename);
                    if (!fs::copy_file(downloaded_files[i],target,fs::copy_options::none))
                        throw std::runtime_error("Artifact path collides with another package file");
                } else {
                    const auto raw = transaction/(L"extract-"+std::to_wstring(i));
                    extract_archive(downloaded_files[i],raw);
                    const auto destination = artifact.extract_destination.empty() ? stage : stage/artifact.extract_destination;
                    // Fixed Scoop 0.6.0 only applies extract_dir to non-tar archives.
                    const auto extract_directory = artifact.archive == ArchiveKind::tar ? fs::path{} : artifact.extract_directory;
                    merge_archive_tree(raw,extract_directory,destination);
                    erase_tree(raw);
                }
            }
            journal["stage"] = "publishing"; save();
            fs::copy_file(package.manifest_path,stage/L"scoop-manifest.json",fs::copy_options::overwrite_existing);
            write_json(stage/L"scoop-install.json",{{"architecture",package.architecture},{"bucket",package.bucket}});
            Json command_targets = Json::array();
            for (const auto& command : package.commands) {
                const auto target = stage/command.target;
                ordinary_parents(stage,target);
                if (!fs::is_regular_file(target)) throw std::runtime_error("Command entry target is missing after extraction: "+path_text(command.target));
                command_targets.push_back({{"path",path_text(command.target)},{"sha256",sha256_file(target)}});
            }
            fs::create_directories(app);
            if (updating) {
                // Fixed Scoop update order: the old version's uninstall hooks run before its current
                // link and entries are removed, and $cmd stays "update" so hooks that only act on a
                // real uninstall can distinguish an update.
                journal["stage"] = "running-pre-uninstall-hooks"; save();
                run_scripts(installed,ScriptPhase::before_uninstall,plan.local.directory,plan.local.directory,"update",true);
                run_scripts(installed,ScriptPhase::uninstaller,plan.local.directory,plan.local.directory,"update",true);
                move(app/L"current",transaction/L"old-current");
                for (const auto& command : installed.commands) {
                    move(shims/(wide(command.name)+L".exe"),transaction/(wide(command.name)+L".old.exe"));
                    const auto suffix = legacy_record ? L".shim" : L".coop-shim.json";
                    move(shims/(wide(command.name)+suffix),transaction/(wide(command.name)+L".old-metadata"));
                }
                for (std::size_t index = 0; index < installed.shortcuts.size(); ++index)
                    if (!shortcut_was_absent(installed.shortcuts[index].name))
                        move(shortcut_link_path(context,installed.shortcuts[index].name),
                            transaction/(L"old-shortcut-"+std::to_wstring(index)+L".lnk"));
                journal["stage"] = "running-post-uninstall-hooks"; save();
                run_scripts(installed,ScriptPhase::after_uninstall,plan.local.directory,plan.local.directory,"update",true);
                move(record_path,transaction/L"old-managed-record.json");
            }
            journal["stage"] = "publishing-version"; save();
            create(version,[&]() { publish_new(stage,version); });
            // pre_install runs inside the real version directory, not the transaction staging area,
            // because hooks may embed $dir into files that outlive the installation step.
            journal["stage"] = "running-pre-install-hooks"; save();
            run_scripts(package,ScriptPhase::before_install,version,version,updating ? "update" : "install",false);
            // Fixed Scoop order: pre_install, then an installer program (not enabled), then the
            // installer.script hook, all before current, entries and persistence are published.
            journal["stage"] = "running-installer-hooks"; save();
            run_scripts(package,ScriptPhase::installer,version,version,updating ? "update" : "install",false);
            persistence = prepare_persistence(context,package,version);
            make_junction(transaction/L"new-current",version);
            create(app/L"current",[&]() { publish_new(transaction/L"new-current",app/L"current"); });
            persistence = verify_persistence(context,package,version);
            fs::create_directories(shims);
            std::array<wchar_t,32768> module{};
            const auto length = GetModuleFileNameW(nullptr,module.data(),static_cast<DWORD>(module.size()));
            if (!length || length >= module.size()) throw std::runtime_error("Cannot find native command launcher");
            const auto environment = expanded_environment(context,package,app/L"current");
            const auto path_entries = expanded_path_entries(context,package,app/L"current");
            Json command_records = Json::array();
            for (const auto& command : package.commands) {
                const auto kind = launcher_kind(command.target);
                if (!kind) throw std::runtime_error("Command entry target type is not supported: "+path_text(command.target));
                const auto metadata = shims/(wide(command.name)+L".coop-shim.json");
                const auto exe = shims/(wide(command.name)+L".exe");
                const bool gui = *kind == LauncherKind::direct && is_gui_executable(version/command.target);
                publish_json(metadata,{{"package",package.name},{"target",path_text(app/L"current"/command.target)},
                    {"launcher",launcher_text(*kind)},{"arguments",command.arguments},{"gui",gui},
                    {"environment",environment},{"path_entries",path_entries}});
                const auto prepared = transaction/(wide(command.name)+L".prepared.exe");
                fs::copy_file(fs::path(module.data()),prepared);
                if (gui) mark_launcher_gui(prepared);
                const auto launcher_hash = sha256_file(prepared);
                create(exe,[&]() { publish_new(prepared,exe); });
                command_records.push_back({{"name",command.name},{"target",path_text(command.target)},
                    {"arguments",command.arguments},{"launcher",launcher_text(*kind)},{"gui",gui},
                    {"launcher_sha256",launcher_hash},{"metadata_sha256",sha256_file(metadata)}});
            }
            Json shortcut_records = Json::array();
            for (const auto& shortcut : package.shortcuts) {
                const auto link = shortcut_link_path(context,shortcut.name);
                const auto target = app/L"current"/shortcut.target;
                if (!fs::is_regular_file(target)) throw std::runtime_error("Shortcut target is missing after extraction: "+path_text(shortcut.target));
                const auto icon = shortcut.icon.empty() ? fs::path{} : app/L"current"/shortcut.icon;
                if (!icon.empty() && !fs::is_regular_file(icon)) throw std::runtime_error("Shortcut icon is missing after extraction: "+path_text(shortcut.icon));
                std::error_code error;
                fs::create_directories(link.parent_path(),error);
                if (error) throw std::runtime_error("Cannot create the shortcut directory: "+path_text(link.parent_path()));
                const auto temporary = link.parent_path()/(link.filename().wstring()+L".coop-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(shortcut_records.size()));
                write_shortcut(temporary,target,shortcut.arguments,icon);
                try { create(link,[&]() { publish_new(temporary,link); }); }
                catch (...) { DeleteFileW(temporary.c_str()); throw; }
                shortcut_records.push_back({{"name",shortcut.name},{"path",path_text(link)},
                    {"target",path_text(target)},{"arguments",shortcut.arguments},{"sha256",sha256_file(link)}});
            }
            run_scripts(package,ScriptPhase::after_install,app/L"current",version,updating ? "update" : "install",false);
            ordinary_parents(context.root,record_path.parent_path());
            fs::create_directories(record_path.parent_path());
            version_history.erase(std::remove_if(version_history.begin(),version_history.end(),[&](const Json& entry) {
                return entry.is_object() && equal_name(entry.value("version",std::string{}),package.version);
            }),version_history.end());
            const auto installed_record_path = installed_record(version,L"install");
            version_history.push_back({{"version",package.version},{"directory",path_text(fs::canonical(version))},
                {"manifest_sha256",package.manifest_sha256},
                {"install_record_sha256",fs::is_regular_file(installed_record_path) ? sha256_file(installed_record_path) : std::string{}},
                {"tree_stamp",version_tree_stamp(version)},
                {"provenance",updating ? "coop-update" : "coop-install"}});
            publish_json(record_path,{{"name",package.name},{"version",package.version},{"architecture",package.architecture},
                {"bucket",package.bucket},{"directory",path_text(fs::canonical(version))},{"manifest_sha256",package.manifest_sha256},
                {"status","ready"},{"command_targets",command_targets},{"commands",command_records},{"shortcuts",shortcut_records},
                {"environment",environment},{"path_entries",path_entries},
                {"dependencies",package.dependencies},{"persistence",persistence},{"versions",version_history},
                {"origin",updating ? managed.value("origin",std::string("coop")) : std::string("coop")},
                {"adoption_backup",updating ? managed.value("adoption_backup",Json(nullptr)) : Json(nullptr)}});
        } else {
            journal["stage"] = "running-pre-uninstall-hooks"; save();
            run_scripts(package,ScriptPhase::before_uninstall,plan.local.directory,plan.local.directory,"uninstall",false);
            run_scripts(package,ScriptPhase::uninstaller,plan.local.directory,plan.local.directory,"uninstall",false);
            move(app/L"current",transaction/L"current");
            for (const auto& command : package.commands) {
                move(shims/(wide(command.name)+L".exe"),transaction/(wide(command.name)+L".exe"));
                const auto suffix = legacy_record ? L".shim" : L".coop-shim.json";
                move(shims/(wide(command.name)+suffix),transaction/(wide(command.name)+L".old-metadata"));
            }
            for (std::size_t index = 0; index < package.shortcuts.size(); ++index)
                if (!shortcut_was_absent(package.shortcuts[index].name))
                    move(shortcut_link_path(context,package.shortcuts[index].name),
                        transaction/(L"shortcut-"+std::to_wstring(index)+L".lnk"));
            move(version,transaction/L"removed-version");
            journal["stage"] = "running-post-uninstall-hooks"; save();
            run_scripts(package,ScriptPhase::after_uninstall,plan.local.directory,plan.local.directory,"uninstall",false);
            Json kept_versions = Json::array();
            for (const auto& entry : recorded_version_evidence(context,package.name))
                if (!equal_name(entry.value("version",std::string{}),package.version)) kept_versions.push_back(entry);
            if (!kept_versions.empty()) {
                const auto retained_path = state/L"retained"/(wide(package.name)+L".json");
                ordinary_parents(context.root,retained_path);
                fs::create_directories(retained_path.parent_path());
                publish_json(retained_path,{{"package",package.name},
                    {"scope","Old versions kept after uninstall; persistent data is separate"},{"versions",kept_versions}});
            }
            move(record_path,transaction/L"managed-record.json");
        }
        journal["state"] = "committed"; save();
        if (updating || plan.action == Action::uninstall) {
            std::vector<fs::path> revoked;
            for (const auto& shortcut : installed.shortcuts)
                if (!shortcut_was_absent(shortcut.name)) revoked.push_back(shortcut_link_path(context,shortcut.name));
            try { prune_empty_shortcut_directories(context,revoked); }
            catch (...) { /* Empty shortcut folders are cosmetic; committed state remains valid. */ }
        }
    } catch (...) {
        try {
            for (auto entry = owned.rbegin(); entry != owned.rend(); ++entry) erase_tree(*entry);
            for (auto entry = moved.rbegin(); entry != moved.rend(); ++entry) {
                const auto& [from,to] = *entry;
                if (GetFileAttributesW(to.c_str()) == INVALID_FILE_ATTRIBUTES || GetFileAttributesW(from.c_str()) != INVALID_FILE_ATTRIBUTES)
                    throw std::runtime_error("Rollback conflict requires recovery");
                publish_new(to,from);
            }
            journal["state"] = "rolled-back"; save();
        } catch (...) { /* Original failure propagates; pending journal preserves recovery evidence. */ }
        throw;
    }
    if (plan.action == Action::uninstall) {
        erase_tree(transaction/L"current");
        erase_tree(transaction/L"removed-version");
    }
    try { erase_tree(transaction/L"downloads"); } catch (...) { /* Keep the committed journal if temporary downloads cannot be removed. */ }
    Json result = {{"package",package.name},{"version",package.version},{"status","success"},
        {"journal",path_text(transaction/L"journal.json")},{"persistence",persistence},
        {"shortcuts_already_absent",absent_shortcuts},{"scripts",script_runs}};
    if (plan.action == Action::uninstall) {
        result["retained_versions"] = retained_versions(context,package.name,package.version);
        if (!plan.purge) {
            result["purge"] = {{"requested",false},{"status","not-requested"},{"scope",Json::array()}};
            result["data_retained"] = true;
        } else {
            Json purge = {{"requested",true},{"scope",purge_entries},{"deleted",Json::array()},
                {"already_absent",Json::array()},{"failed",Json::array()}};
            for (const auto& entry : purge_entries) {
                const auto store = entry.at("store").get<std::string>();
                try {
                    if (!verify_purge_target(context,package.name,entry)) purge["already_absent"].push_back(store);
                    else {
                        erase_tree(fs::path(wide(store)));
                        purge["deleted"].push_back(store);
                    }
                } catch (const std::exception& error) {
                    purge["failed"].push_back({{"store",store},{"reason",error.what()}});
                }
            }
            if (!purge.at("failed").empty()) {
                purge["status"] = "partial";
                purge["reason"] = "Declared persistent data was not completely deleted: "+
                    purge.at("failed").front().at("store").get<std::string>();
                result["status"] = "partial";
                result["reason"] = purge.at("reason");
                result["data_retained"] = true;
            } else {
                purge["status"] = purge_entries.empty() ? "nothing-to-delete" : "deleted";
                result["data_retained"] = false;
            }
            result["purge"] = std::move(purge);
        }
    } else if (updating) {
        result["retained_versions"] = retained_versions(context,package.name,package.version);
        result["data_rollback"] = "none";
    } else {
        result["retained_versions"] = Json::array();
    }
    return result;
}
Json package_recovery_status(const Context& context, const fs::path& journal_path, bool execute) {
    Json result = {{"journal",path_text(journal_path)},{"mode","manual"},{"status","manual"},
        {"reason","Recovery evidence cannot be verified"},{"actions",Json::array()}};
    bool mutating = false;
    try {
        const auto journal = read_json(journal_path);
        if (!journal.is_object()) throw std::runtime_error("Transaction journal is not an object");
        const auto action = journal.value("action",std::string{});
        const auto package = journal.value("package",std::string{});
        result["action"] = action;
        result["package"] = package;
        if (journal.value("state",std::string{}) != "pending") {
            result["mode"] = "none";
            result["status"] = "not-pending";
            result["reason"] = "Transaction journal is already resolved";
            return result;
        }
        if (action != "install" && action != "update" && action != "uninstall")
            throw std::runtime_error("Transaction action is not a recoverable package operation: "+action);
        if (package.empty()) throw std::runtime_error("Transaction journal does not name a package");
        const auto created = journal.contains("created") && journal.at("created").is_array() ? journal.at("created") : Json::array();
        const auto moves = journal.contains("moves") && journal.at("moves").is_array() ? journal.at("moves") : Json::array();
        const auto scripts = journal.contains("scripts") && journal.at("scripts").is_array() ? journal.at("scripts") : Json::array();
        const bool scripts_started = !scripts.empty();
        result["scripts_started"] = scripts_started;
        if (scripts_started) result["external_side_effects"] =
            "unknown; recovered state does not roll back effects outside Coop's managed paths, and journaled scripts are not re-run";
        Json actions = Json::array();
        std::vector<fs::path> removals;
        std::vector<std::pair<fs::path,fs::path>> restores;
        for (const auto& entry : created) {
            if (!entry.is_object() || !entry.contains("path") || !entry.at("path").is_string())
                throw std::runtime_error("Transaction journal has an unreadable created-path record");
            const fs::path path(wide(entry.at("path").get<std::string>()));
            if (!recovery_path_allowed(context,path))
                throw std::runtime_error("Created path is outside Coop's managed locations or crosses a reparse point: "+path_text(path));
            const bool exists = GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
            const bool owned = entry.value("owned",false);
            if (exists && !owned)
                throw std::runtime_error("Creation ownership was not confirmed for "+path_text(path)+"; refusing to delete it");
            if (exists) {
                removals.push_back(path);
                actions.push_back({{"kind","remove"},{"path",path_text(path)}});
            } else {
                actions.push_back({{"kind","already-absent"},{"path",path_text(path)}});
            }
        }
        for (const auto& entry : moves) {
            if (!entry.is_object() || !entry.contains("from") || !entry.at("from").is_string() ||
                !entry.contains("to") || !entry.at("to").is_string())
                throw std::runtime_error("Transaction journal has an unreadable move record");
            const fs::path from(wide(entry.at("from").get<std::string>()));
            const fs::path to(wide(entry.at("to").get<std::string>()));
            if (!recovery_path_allowed(context,from) || !recovery_path_allowed(context,to))
                throw std::runtime_error("Moved path is outside Coop's managed locations or crosses a reparse point");
            bool from_exists = GetFileAttributesW(from.c_str()) != INVALID_FILE_ATTRIBUTES;
            const bool to_exists = GetFileAttributesW(to.c_str()) != INVALID_FILE_ATTRIBUTES;
            // A created destination at the original path (for example a newly published current
            // junction) is removed before moves are restored, exactly as in-process rollback does.
            for (const auto& removal : removals) if (same_path_text(removal,from)) { from_exists = false; break; }
            if (to_exists && !from_exists) {
                restores.emplace_back(from,to);
                actions.push_back({{"kind","restore"},{"from",path_text(from)},{"to",path_text(to)}});
            } else if (!to_exists && from_exists) {
                actions.push_back({{"kind","already-restored"},{"from",path_text(from)}});
            } else if (!to_exists && !from_exists) {
                throw std::runtime_error("Both endpoints of a journaled move are missing: "+path_text(from));
            } else {
                throw std::runtime_error("Both endpoints of a journaled move exist; recovery would overwrite data: "+path_text(from));
            }
        }
        result["actions"] = std::move(actions);
        result["mode"] = "automatic";
        result["status"] = execute ? "pending" : "recoverable";
        result["reason"] = restores.empty() && removals.empty() ?
            "No published state was changed; the interrupted preparation can be discarded" :
            "Journaled Coop-owned paths and moves can be reverted without guessing";
        if (!execute) return result;
        mutating = true;
        for (auto entry = removals.rbegin(); entry != removals.rend(); ++entry) erase_tree(*entry);
        for (auto entry = restores.rbegin(); entry != restores.rend(); ++entry) publish_new(entry->second,entry->first);
        auto resolved = read_json(journal_path);
        resolved["state"] = "rolled-back";
        resolved["recovered"] = true;
        if (scripts_started) resolved["recovery_external_side_effects"] =
            "unknown; journaled scripts were not re-run and their effects outside Coop's managed paths were not rolled back";
        write_json(journal_path,resolved);
        if (scripts_started) {
            // Script logs are recovery evidence and must not be treated as ordinary cache.
            result["transaction_evidence_retained"] = path_text(journal_path.parent_path());
        } else {
            try {
                for (const auto& entry : fs::directory_iterator(journal_path.parent_path()))
                    if (entry.path().filename() != L"journal.json") erase_tree(entry.path());
            } catch (const std::exception& error) {
                result["cleanup_warning"] = std::string("Recovered state is valid, but transaction staging could not be removed: ")+error.what();
            }
        }
        result["status"] = scripts_started ? "recovered-with-unknown-script-effects" : "recovered";
        result["reason"] = scripts_started ?
            "Interrupted Coop state was reverted; script side effects outside managed paths remain unknown" :
            "Interrupted Coop state was reverted";
        return result;
    } catch (const std::exception& error) {
        result["mode"] = "manual";
        result["status"] = mutating ? "failed" : "manual";
        result["reason"] = error.what();
        return result;
    }
}
}
