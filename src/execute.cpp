#include "package.hpp"
#include "data.hpp"
#include "native.hpp"
#include <windows.h>
#include <array>
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
    if (package.artifacts.size() != 1 || package.artifacts[0].archive != ArchiveKind::none ||
        !package.scripts.empty() || !package.dependencies.empty() || !package.persistence.empty() ||
        !package.shortcuts.empty() || !package.path_entries.empty() || !package.environment.empty() || package.installer || package.uninstaller)
        throw std::runtime_error("Execution currently requires a single file without archives, scripts, dependencies, persistence or environment changes");
    for (const auto& command : package.commands)
        if (command.target.extension() != L".exe" || command.target != fs::path(wide(package.artifacts[0].filename)))
            throw std::runtime_error("Only direct EXE command entries are currently supported");
}
void publish_new(const fs::path& source, const fs::path& destination) {
    if (!MoveFileExW(source.c_str(),destination.c_str(),MOVEFILE_WRITE_THROUGH))
        throw std::runtime_error("Destination cannot be published without replacing existing data");
}
}
std::string execution_blocker(const Context& context, const Plan& plan) {
    if (plan.action != Action::install && plan.action != Action::uninstall && plan.action != Action::update) return "This action is not executable yet";
    try {
        require_capabilities(plan.package);
        if (plan.previous) require_capabilities(*plan.previous);
    } catch (const std::exception& error) { return error.what(); }
    if (!plan.diagnostics.empty()) return "Plan has unresolved diagnostics";
    if (plan.action == Action::install && plan.local.exists) return "Package already exists; use adoption or update";
    if ((plan.action == Action::uninstall || plan.action == Action::update) && !fs::exists(context.root/L".coop"/L"packages"/(wide(plan.package.name)+L".json")))
        return "Package is unadopted; update/uninstall is refused";
    return {};
}
int execute_plan(const Context& context, const Plan& plan) {
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
        if (fs::exists(journal_path) && read_json(journal_path).value("state",std::string{}) == "pending")
            throw std::runtime_error("Pending transaction requires recovery: "+path_text(journal_path));
    }
    Json managed;
    std::vector<FilePrecondition> owned_inputs;
    if (plan.action == Action::install) {
        if (plan.local.exists || fs::exists(version) || fs::exists(record_path)) throw std::runtime_error("Package already exists; use adoption or update");
    } else {
        if (!fs::exists(record_path)) throw std::runtime_error("Package is unadopted; update/uninstall is refused");
        managed = read_json(record_path);
        if (managed.at("directory") != path_text(plan.local.directory) || managed.at("manifest_sha256") != installed.manifest_sha256)
            throw std::runtime_error("Managed installation changed; refusing operation");
        if (sha256_file(plan.local.directory/wide(installed.artifacts.front().filename)) != installed.artifacts.front().sha256)
            throw std::runtime_error("Installed executable changed; refusing operation");
        owned_inputs.push_back({record_path,sha256_file(record_path)});
        owned_inputs.push_back({plan.local.directory/wide(installed.artifacts.front().filename),installed.artifacts.front().sha256});
    }
    const auto same_alias = [](const std::string& left, const std::string& right) {
        const auto a = wide(left), b = wide(right);
        return CompareStringOrdinal(a.c_str(),-1,b.c_str(),-1,TRUE) == CSTR_EQUAL;
    };
    for (const auto& command : installed.commands) {
        const auto exe = shims/(wide(command.name)+L".exe");
        const auto metadata = shims/(wide(command.name)+L".coop-shim.json");
        if (plan.action == Action::install) {
            if (fs::exists(exe) || fs::exists(metadata)) throw std::runtime_error("Command entry conflicts with an existing file");
        } else {
            if (!fs::exists(exe) || !fs::exists(metadata)) throw std::runtime_error("Managed command entry is missing");
            ordinary_parents(context.root,exe);
            ordinary_parents(context.root,metadata);
            const auto entry = read_json(metadata);
            if (entry.value("package",std::string{}) != package.name ||
                entry.value("target",std::string{}) != path_text(app/L"current"/command.target) ||
                entry.value("arguments",std::string{}) != command.arguments ||
                sha256_file(exe) != managed.at("shim_sha256").get<std::string>())
                throw std::runtime_error("Managed command entry ownership changed");
            owned_inputs.push_back({exe,managed.at("shim_sha256").get<std::string>()});
            owned_inputs.push_back({metadata,sha256_file(metadata)});
        }
    }
    if (updating) {
        if (package.version == installed.version && package.manifest_sha256 == installed.manifest_sha256) {
            if (context.json_output) std::cout << Json{{"package",package.name},{"version",package.version},{"status","up-to-date"}}.dump() << '\n';
            else std::cout << package.name << ": up-to-date\n";
            return 0;
        }
        if (fs::exists(version)) throw std::runtime_error("Target version already exists; it will not be overwritten");
        for (const auto& command : package.commands) {
            if (std::any_of(installed.commands.begin(),installed.commands.end(),[&](const CommandExposure& old) { return same_alias(old.name,command.name); })) continue;
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
    bool committed = false;
    try {
        if (plan.action == Action::install || updating) {
            const auto stage = transaction/L"payload";
            fs::create_directories(stage);
            const auto& artifact = package.artifacts.front();
            download_file(artifact.url,stage/wide(artifact.filename));
            if (sha256_file(stage/wide(artifact.filename)) != artifact.sha256) throw std::runtime_error("Artifact SHA256 mismatch");
            recheck_plan(plan);
            for (const auto& input : owned_inputs)
                if (sha256_file(input.path) != input.sha256) throw std::runtime_error("Managed input changed during preparation; regenerate the plan");
            fs::copy_file(package.manifest_path,stage/L"scoop-manifest.json");
            write_json(stage/L"scoop-install.json",{{"architecture",package.architecture},{"bucket",package.bucket}});
            if (updating) {
                move(app/L"current",transaction/L"old-current");
                for (const auto& command : installed.commands) {
                    move(shims/(wide(command.name)+L".exe"),transaction/(wide(command.name)+L".old.exe"));
                    move(shims/(wide(command.name)+L".coop-shim.json"),transaction/(wide(command.name)+L".old-shim.json"));
                }
                move(record_path,transaction/L"old-managed-record.json");
            }
            fs::create_directories(app);
            create(version,[&]() { publish_new(stage,version); });
            make_junction(transaction/L"new-current",version);
            create(app/L"current",[&]() { publish_new(transaction/L"new-current",app/L"current"); });
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
                {"bucket",package.bucket},{"directory",path_text(version)},{"manifest_sha256",package.manifest_sha256},
                {"shim_sha256",sha256_file(fs::path(module.data()))},{"status","ready"}});
        } else {
            move(app/L"current",transaction/L"current");
            for (const auto& command : package.commands) {
                move(shims/(wide(command.name)+L".exe"),transaction/(wide(command.name)+L".exe"));
                move(shims/(wide(command.name)+L".coop-shim.json"),transaction/(wide(command.name)+L".coop-shim.json"));
            }
            move(version,transaction/L"removed-version");
            move(record_path,transaction/L"managed-record.json");
        }
        journal["state"] = "committed"; save(); committed = true;
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
    if (committed) {
        if (plan.action == Action::uninstall) {
            erase_tree(transaction/L"current");
            erase_tree(transaction/L"removed-version");
        }
        if (context.json_output) std::cout << Json{{"package",package.name},{"version",package.version},{"status","success"},{"journal",path_text(transaction/L"journal.json")}}.dump(2) << '\n';
        else std::cout << package.name << ": success\n";
    }
    return 0;
}
}
