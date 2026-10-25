#include "package.hpp"
#include "data.hpp"
#include "native.hpp"
#include "archive.hpp"
#include "persist.hpp"
#include <windows.h>
#include <array>
#include <cctype>
#include <iostream>
#include <stdexcept>
#include <algorithm>

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
    if (!package.scripts.empty() ||
        !package.shortcuts.empty() || !package.path_entries.empty() || !package.environment.empty() || package.installer || package.uninstaller)
        throw std::runtime_error("Execution currently requires archives or files without scripts, shortcuts or environment changes; declared persist mappings and dependencies are supported");
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
            throw std::runtime_error("7z archive lifecycle is not enabled; ZIP and tar archives are supported");
        case ArchiveKind::msi:
            throw std::runtime_error("MSI extraction requires external tooling and is not supported natively");
        }
    }
    for (const auto& command : package.commands)
        if (command.target.extension() != L".exe") throw std::runtime_error("Only direct EXE command entries are currently supported");
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
void publish_new(const fs::path& source, const fs::path& destination) {
    DWORD error = ERROR_SUCCESS;
    for (int attempt = 0; attempt < 5; ++attempt) {
        if (MoveFileExW(source.c_str(),destination.c_str(),MOVEFILE_WRITE_THROUGH)) return;
        error = GetLastError();
        if (error != ERROR_SHARING_VIOLATION && error != ERROR_LOCK_VIOLATION && error != ERROR_ACCESS_DENIED) break;
        Sleep(200);
    }
    throw std::runtime_error("Destination cannot be published (Windows error "+std::to_string(error)+"); close the program and retry");
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
    const auto result = execute_plan_result(context,plan);
    if (plan.action == Action::adopt) {
        std::cout << result.dump(2) << '\n';
        return 0;
    }
    if (context.json_output) {
        std::cout << result.dump(2) << '\n';
        return 0;
    }
    if (result.value("status",std::string{}) == "up-to-date") {
        std::cout << plan.package.name << ": up-to-date\n";
        return 0;
    }
    std::cout << plan.package.name << ": success\n";
    const Json persistence = result.contains("persistence") ? result.at("persistence") : Json::array();
    if (persistence.is_array() && !persistence.empty())
        std::cout << "Persistent data retained; old program versions and stored data are reported separately\n";
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
        owned_inputs.push_back({record_path,sha256_file(record_path)});
        for (const auto& command : installed.commands) {
            const auto target = plan.local.directory/command.target;
            owned_inputs.push_back({target,sha256_file(target)});
        }
    }
    for (const auto& command : installed.commands) {
        const auto exe = shims/(wide(command.name)+L".exe");
        const bool legacy = managed.is_object() && managed.value("shim_format",std::string{}) == "scoop";
        const auto metadata = shims/(wide(command.name)+(legacy ? L".shim" : L".coop-shim.json"));
        if (plan.action == Action::install) {
            if (fs::exists(exe) || fs::exists(metadata)) throw std::runtime_error("Command entry conflicts with an existing file");
        } else {
            if (!fs::exists(exe) || !fs::exists(metadata)) throw std::runtime_error("Managed command entry is missing");
            ordinary_parents(context.root,exe);
            ordinary_parents(context.root,metadata);
            std::string executable_hash;
            if (legacy) {
                const auto& entry = managed.at("legacy_shims").at(command.name);
                executable_hash = entry.at("executable_sha256");
                if (sha256_file(metadata) != entry.at("metadata_sha256").get<std::string>()) throw std::runtime_error("Managed Scoop command metadata changed");
            } else {
                const auto entry = read_json(metadata);
                executable_hash = managed.at("shim_sha256");
                if (!equal_name(entry.value("package",std::string{}),package.name) ||
                    !same_identity(fs::path(wide(entry.value("target",std::string{}))),app/L"current"/command.target) ||
                    entry.value("arguments",std::string{}) != command.arguments)
                    throw std::runtime_error("Managed command entry ownership changed");
            }
            if (sha256_file(exe) != executable_hash) throw std::runtime_error("Managed command launcher changed");
            owned_inputs.push_back({exe,executable_hash});
            owned_inputs.push_back({metadata,sha256_file(metadata)});
        }
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
    }
    const auto transaction = state/L"transactions"/(std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));
    ordinary_parents(context.root,transaction);
    fs::create_directories(transaction);
    Json journal = {{"state","pending"},{"package",package.name},{"action",updating ? "update" : plan.action == Action::install ? "install" : "uninstall"},
        {"created",Json::array()},{"moves",Json::array()}};
    const auto save = [&]() { write_json(transaction/L"journal.json",journal); };
    std::vector<fs::path> owned;
    std::vector<std::pair<fs::path,fs::path>> moved;
    const auto create = [&](const fs::path& path, const auto& operation) {
        journal["created"].push_back({{"path",path_text(path)},{"owned",false}}); save();
        operation();
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
        publish_new(from,to);
        moved.emplace_back(from,to);
        journal["moves"].back()["moved"] = true; save();
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
            persistence = prepare_persistence(context,package,stage);
            if (updating) {
                move(app/L"current",transaction/L"old-current");
                for (const auto& command : installed.commands) {
                    move(shims/(wide(command.name)+L".exe"),transaction/(wide(command.name)+L".old.exe"));
                    const auto suffix = managed.value("shim_format",std::string{}) == "scoop" ? L".shim" : L".coop-shim.json";
                    move(shims/(wide(command.name)+suffix),transaction/(wide(command.name)+L".old-metadata"));
                }
                move(record_path,transaction/L"old-managed-record.json");
            }
            fs::create_directories(app);
            create(version,[&]() { publish_new(stage,version); });
            make_junction(transaction/L"new-current",version);
            create(app/L"current",[&]() { publish_new(transaction/L"new-current",app/L"current"); });
            persistence = verify_persistence(context,package,version);
            fs::create_directories(shims);
            std::array<wchar_t,32768> module{};
            const auto length = GetModuleFileNameW(nullptr,module.data(),static_cast<DWORD>(module.size()));
            if (!length || length >= module.size()) throw std::runtime_error("Cannot find native command launcher");
            for (const auto& command : package.commands) {
                const auto metadata = shims/(wide(command.name)+L".coop-shim.json");
                const auto exe = shims/(wide(command.name)+L".exe");
                publish_json(metadata,{{"package",package.name},{"target",path_text(app/L"current"/command.target)},{"arguments",command.arguments}});
                const auto prepared = transaction/(wide(command.name)+L".prepared.exe");
                fs::copy_file(fs::path(module.data()),prepared);
                create(exe,[&]() { publish_new(prepared,exe); });
            }
            ordinary_parents(context.root,record_path.parent_path());
            fs::create_directories(record_path.parent_path());
            publish_json(record_path,{{"name",package.name},{"version",package.version},{"architecture",package.architecture},
                {"bucket",package.bucket},{"directory",path_text(fs::canonical(version))},{"manifest_sha256",package.manifest_sha256},
                {"shim_sha256",sha256_file(fs::path(module.data()))},{"status","ready"},{"command_targets",command_targets},
                {"dependencies",package.dependencies},{"persistence",persistence},
                {"origin",updating ? managed.value("origin",std::string("coop")) : std::string("coop")},
                {"adoption_backup",updating ? managed.value("adoption_backup",Json(nullptr)) : Json(nullptr)}});
        } else {
            move(app/L"current",transaction/L"current");
            for (const auto& command : package.commands) {
                move(shims/(wide(command.name)+L".exe"),transaction/(wide(command.name)+L".exe"));
                const auto suffix = managed.value("shim_format",std::string{}) == "scoop" ? L".shim" : L".coop-shim.json";
                move(shims/(wide(command.name)+suffix),transaction/(wide(command.name)+L".old-metadata"));
            }
            move(version,transaction/L"removed-version");
            move(record_path,transaction/L"managed-record.json");
        }
        journal["state"] = "committed"; save();
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
        {"journal",path_text(transaction/L"journal.json")},{"persistence",persistence}};
    if (plan.action == Action::uninstall) {
        result["retained_versions"] = retained_versions(context,package.name,package.version);
        result["data_retained"] = true;
    } else if (updating) {
        result["retained_versions"] = retained_versions(context,package.name,package.version);
        result["data_rollback"] = "none";
    } else {
        result["retained_versions"] = Json::array();
    }
    return result;
}
}
