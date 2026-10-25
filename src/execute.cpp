#include "package.hpp"
#include "data.hpp"
#include "native.hpp"
#include <windows.h>
#include <array>
#include <iostream>
#include <stdexcept>

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
}
std::string execution_blocker(const Context& context, const Plan& plan) {
    if (plan.action != Action::install && plan.action != Action::uninstall) return "This action is not executable yet";
    try { require_capabilities(plan.package); } catch (const std::exception& error) { return error.what(); }
    if (!plan.diagnostics.empty()) return "Plan has unresolved diagnostics";
    if (plan.action == Action::install && plan.local.exists) return "Package already exists; use adoption or update";
    if (plan.action == Action::uninstall && !fs::exists(context.root/L".coop"/L"packages"/(wide(plan.package.name)+L".json")))
        return "Package is unadopted; update/uninstall is refused";
    return {};
}
int execute_plan(const Context& context, const Plan& plan) {
    const auto blocker = execution_blocker(context,plan);
    if (!blocker.empty()) throw std::runtime_error(blocker);
    const auto& package = plan.package;
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
    if (plan.action == Action::install) {
        if (plan.local.exists || fs::exists(version) || fs::exists(record_path)) throw std::runtime_error("Package already exists; use adoption or update");
    } else {
        if (!fs::exists(record_path)) throw std::runtime_error("Package is unadopted; update/uninstall is refused");
        managed = read_json(record_path);
        if (managed.at("directory") != path_text(plan.local.directory) || managed.at("manifest_sha256") != package.manifest_sha256)
            throw std::runtime_error("Managed installation changed; refusing uninstall");
        if (sha256_file(version/wide(package.artifacts.front().filename)) != package.artifacts.front().sha256)
            throw std::runtime_error("Installed executable changed; refusing uninstall");
    }
    for (const auto& command : package.commands) {
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
        }
    }
    const auto transaction = state/L"transactions"/(std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));
    ordinary_parents(context.root,transaction);
    fs::create_directories(transaction);
    Json journal = {{"state","pending"},{"package",package.name},{"action",plan.action == Action::install ? "install" : "uninstall"},
        {"created",Json::array()},{"moves",Json::array()}};
    const auto save = [&]() { write_json(transaction/L"journal.json",journal); };
    const auto created = [&](const fs::path& path) { journal["created"].push_back(path_text(path)); save(); };
    const auto move = [&](const fs::path& from, const fs::path& to) {
        journal["moves"].push_back({{"from",path_text(from)},{"to",path_text(to)}}); save();
        fs::rename(from,to);
    };
    save();
    bool committed = false;
    try {
        if (plan.action == Action::install) {
            const auto stage = transaction/L"payload";
            fs::create_directories(stage);
            const auto& artifact = package.artifacts.front();
            download_file(artifact.url,stage/wide(artifact.filename));
            if (sha256_file(stage/wide(artifact.filename)) != artifact.sha256) throw std::runtime_error("Artifact SHA256 mismatch");
            recheck_plan(plan);
            fs::copy_file(package.manifest_path,stage/L"scoop-manifest.json");
            write_json(stage/L"scoop-install.json",{{"architecture",package.architecture},{"bucket",package.bucket}});
            fs::create_directories(app);
            created(version); fs::rename(stage,version);
            created(app/L"current"); make_junction(app/L"current",version);
            fs::create_directories(shims);
            std::array<wchar_t,32768> module{};
            const auto length = GetModuleFileNameW(nullptr,module.data(),static_cast<DWORD>(module.size()));
            if (!length || length >= module.size()) throw std::runtime_error("Cannot find native command launcher");
            for (const auto& command : package.commands) {
                const auto metadata = shims/(wide(command.name)+L".coop-shim.json");
                const auto exe = shims/(wide(command.name)+L".exe");
                created(metadata);
                write_json(metadata,{{"package",package.name},{"target",path_text(app/L"current"/command.target)},{"arguments",command.arguments}});
                created(exe);
                fs::copy_file(fs::path(module.data()),exe);
            }
            ordinary_parents(context.root,record_path.parent_path());
            fs::create_directories(record_path.parent_path());
            created(record_path);
            write_json(record_path,{{"name",package.name},{"version",package.version},{"architecture",package.architecture},
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
            for (auto entry = journal["moves"].rbegin(); entry != journal["moves"].rend(); ++entry) {
                const fs::path from(wide(entry->at("from"))), to(wide(entry->at("to")));
                if (fs::exists(to) && !fs::exists(from)) fs::rename(to,from);
            }
            for (auto entry = journal["created"].rbegin(); entry != journal["created"].rend(); ++entry) erase_tree(fs::path(wide(entry->get<std::string>())));
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
