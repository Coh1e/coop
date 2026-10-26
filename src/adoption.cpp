#include "package.hpp"
#include "data.hpp"
#include "persist.hpp"
#include "versions.hpp"
#include "exposure.hpp"
#include "script.hpp"
#include "shim.hpp"
#include <windows.h>
#include <algorithm>
#include <fstream>
#include <set>
#include <array>
#include <sstream>
#include <stdexcept>
#include <iostream>

namespace coop {
namespace {
std::string trim(std::string value) {
    const auto first = value.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) return {};
    return value.substr(first,value.find_last_not_of(" \t\r\n")-first+1);
}
void verify_program(const fs::path& path, const std::string& architecture) {
    std::ifstream file(path,std::ios::binary);
    IMAGE_DOS_HEADER dos{};
    file.read(reinterpret_cast<char*>(&dos),sizeof(dos));
    if (!file || dos.e_magic != IMAGE_DOS_SIGNATURE || dos.e_lfanew < 0 || static_cast<std::uintmax_t>(dos.e_lfanew) > fs::file_size(path)-sizeof(IMAGE_FILE_HEADER)-sizeof(DWORD))
        throw std::runtime_error("Installed file is not a validated Windows executable");
    file.seekg(dos.e_lfanew);
    DWORD signature = 0;
    IMAGE_FILE_HEADER header{};
    file.read(reinterpret_cast<char*>(&signature),sizeof(signature));
    file.read(reinterpret_cast<char*>(&header),sizeof(header));
    const auto machine = architecture == "64bit" ? IMAGE_FILE_MACHINE_AMD64 : architecture == "32bit" ? IMAGE_FILE_MACHINE_I386 : IMAGE_FILE_MACHINE_ARM64;
    if (!file || signature != IMAGE_NT_SIGNATURE || header.Machine != machine)
        throw std::runtime_error("Installed executable architecture differs from installation record");
}
}
AdoptionAssessment assess_adoption(const Context& context, const Plan& plan) {
    AdoptionAssessment result;
    const auto reject = [&](AdoptionEligibility eligibility, DiagnosticKind kind, const std::string& code, const std::string& message) {
        result.eligibility = eligibility;
        result.diagnostics.push_back({kind,code,message});
    };
    try {
        if (context.global_root && fs::exists(*context.global_root) && fs::equivalent(context.root,*context.global_root)) {
            reject(AdoptionEligibility::unsupported,DiagnosticKind::environment,"global-read-only","System-level installation roots are read-only"); return result;
        }
        std::array<wchar_t,32768> program_data{};
        const auto length = GetEnvironmentVariableW(L"ProgramData",program_data.data(),static_cast<DWORD>(program_data.size()));
        if (length && length < program_data.size() && fs::exists(fs::path(program_data.data())/L"scoop") && fs::equivalent(context.root,fs::path(program_data.data())/L"scoop")) {
            reject(AdoptionEligibility::unsupported,DiagnosticKind::environment,"global-read-only","Default system-level Scoop root is read-only"); return result;
        }
        const auto record = context.root/L".coop"/L"packages"/(wide(plan.package.name)+L".json");
        if (fs::exists(record)) {
            const auto managed = read_json(record);
            if (!same_identity(fs::path(wide(managed.at("directory").get<std::string>())),plan.local.directory) ||
                managed.at("manifest_sha256") != plan.package.manifest_sha256)
                throw std::runtime_error("Existing Coop management evidence differs from current installation");
            result.eligibility = AdoptionEligibility::already_managed; return result;
        }
        if (!plan.package.diagnostics.empty()) {
            reject(AdoptionEligibility::inconsistent,DiagnosticKind::validation,"invalid-installation-manifest","Installed Manifest has invalid or unsupported fields"); return result;
        }
        if (!plan.package.scripts.empty()) {
            const auto hooks = check_package_scripts(plan.package);
            if (!hooks.compatible()) {
                const auto messages = hooks.messages();
                reject(AdoptionEligibility::unsupported,DiagnosticKind::capability,"script-adoption-unsupported",
                    "Installed lifecycle hook is outside the proven PowerShell subset: "+(messages.empty() ? std::string("unknown script capability") : messages.front())); return result;
            }
            // Executing supported hooks is verified for fresh installs, updates and uninstalls in
            // tests/hooks.ps1, but taking over a live installation and continuing to update it has
            // not been demonstrated with real package evidence. Do not promote this class yet.
            reject(AdoptionEligibility::untested,DiagnosticKind::verification,"script-adoption-unverified",
                "In-place adoption of a package with lifecycle hooks is not verified; supported hooks can run for install, update and uninstall, but taking over this class needs real-package evidence first"); return result;
        }
        if (std::any_of(plan.package.artifacts.begin(),plan.package.artifacts.end(),[](const Artifact& artifact) { return artifact.archive != ArchiveKind::none; })) {
            reject(AdoptionEligibility::untested,DiagnosticKind::verification,"archive-adoption-unverified","Adoption of archived package layouts is not verified; only direct single-file installations are eligible"); return result;
        }
        const auto current_blocker = package_execution_blocker(plan.package);
        if (!current_blocker.empty()) {
            reject(AdoptionEligibility::unsupported,DiagnosticKind::capability,"adoption-lifecycle-unsupported",current_blocker); return result;
        }
        for (const auto& dependency : plan.dependencies)
            if (!dependency.installed) {
                reject(AdoptionEligibility::inconsistent,DiagnosticKind::environment,"missing-dependency","Declared dependency is not installed: "+dependency.request); return result;
            }
        if (!plan.update_candidate) {
            reject(AdoptionEligibility::untested,DiagnosticKind::verification,"missing-update-manifest","No same-source local Manifest to assess future updates"); return result;
        }
        const auto future_blocker = package_execution_blocker(*plan.update_candidate);
        if (!future_blocker.empty()) {
            reject(AdoptionEligibility::unsupported,DiagnosticKind::capability,"future-update-unsupported",future_blocker); return result;
        }
        if (!plan.update_candidate->scripts.empty()) {
            reject(AdoptionEligibility::untested,DiagnosticKind::verification,"future-update-scripts-unverified",
                "The future update of this package runs lifecycle hooks; adopted-installation hook execution is not verified"); return result;
        }
        if (!same_persistence(plan.package,*plan.update_candidate)) {
            reject(AdoptionEligibility::untested,DiagnosticKind::verification,"persist-update-change-unverified",
                "Future update changes the persist mapping; data migration is not verified"); return result;
        }
        const auto expected = context.root/L"apps"/wide(plan.package.name)/wide(plan.package.version);
        if (!fs::exists(expected) || !fs::equivalent(expected,plan.local.directory)) throw std::runtime_error("Current does not identify its recorded version directory");
        const auto artifact = expected/wide(plan.package.artifacts.front().filename);
        const auto& declared = plan.package.artifacts.front();
        if (digest_file(artifact,declared.algorithm) != declared.digest)
            throw std::runtime_error("Installed executable digest differs from original Manifest");
        verify_program(artifact,plan.package.architecture);
        verify_persistence(context,plan.package,plan.local.directory);
        static const std::set<std::string> known_shims = {
            "140e3801d8adeda639a21b14e62b93a4c7d26b7a758421f43c82be59753be49b",
            "70d4690b8ac3b3f715f537cdea6e07a39fda4bc0347bf6b958e4f3ff2f0e04d4",
            "0116068768fc992fc536738396b33db3dafe6b0cf0e6f54f6d1aa8b0331f3cec"};
        for (const auto& command : plan.package.commands) {
            LegacyCommand legacy{command.name,{context.root/L"shims"/(wide(command.name)+L".exe"),{}},
                {context.root/L"shims"/(wide(command.name)+L".shim"),{}}};
            legacy.executable.sha256 = sha256_file(legacy.executable.path);
            if (!known_shims.contains(legacy.executable.sha256)) {
                reject(AdoptionEligibility::untested,DiagnosticKind::verification,"untested-scoop-shim","Existing command launcher is not a validated Scoop shim"); return result;
            }
            if (fs::exists(context.root/L"shims"/(wide(command.name)+L".coop-shim.json"))) throw std::runtime_error("Existing Coop command metadata conflicts with unadopted package");
            legacy.metadata.sha256 = sha256_file(legacy.metadata.path);
            const auto shim_metadata = read_shim_metadata(legacy.metadata.path);
            if (!shim_metadata.unknown_keys.empty()) {
                reject(AdoptionEligibility::untested,DiagnosticKind::verification,"untested-shim-option",
                    "Unvalidated Scoop shim option: "+shim_metadata.unknown_keys.front()); return result;
            }
            const auto expected_arguments = expand_exposure_arguments(context,plan.package.name,plan.local.current,command.arguments);
            if (!fs::exists(fs::path(wide(shim_metadata.target))) ||
                !fs::equivalent(fs::path(wide(shim_metadata.target)),expected/command.target) ||
                shim_metadata.arguments != expected_arguments)
                throw std::runtime_error("Existing Scoop command entry points to a different package or arguments");
            result.commands.push_back(std::move(legacy));
        }
        for (const auto& shortcut : plan.package.shortcuts) {
            const auto link = shortcut_link_path(context,shortcut.name);
            if (!fs::exists(link)) {
                reject(AdoptionEligibility::untested,DiagnosticKind::verification,"shortcut-evidence-missing",
                    "Existing Scoop shortcut is missing: "+path_text(link)); return result;
            }
            const auto identity = read_shortcut(link);
            if (!identity) {
                reject(AdoptionEligibility::untested,DiagnosticKind::verification,"shortcut-unreadable",
                    "Existing shortcut cannot be read as a Windows shortcut: "+path_text(link)); return result;
            }
            const auto target = expected/shortcut.target;
            if (!same_identity(identity->target,target) && !same_identity(identity->target,plan.local.current/shortcut.target)) {
                reject(AdoptionEligibility::untested,DiagnosticKind::verification,"shortcut-target-mismatch",
                    "Existing shortcut points to a different target: "+path_text(link)); return result;
            }
            const auto expected_arguments = expand_exposure_arguments(context,plan.package.name,plan.local.current,shortcut.arguments);
            if (identity->arguments != expected_arguments) {
                reject(AdoptionEligibility::untested,DiagnosticKind::verification,"shortcut-arguments-mismatch",
                    "Existing shortcut uses different arguments: "+path_text(link)); return result;
            }
            if (!shortcut.icon.empty() && !identity->icon.empty() && !same_identity(identity->icon,expected/shortcut.icon)) {
                reject(AdoptionEligibility::untested,DiagnosticKind::verification,"shortcut-icon-mismatch",
                    "Existing shortcut uses a different icon: "+path_text(link)); return result;
            }
            result.shortcuts.push_back({shortcut.name,link,sha256_file(link)});
        }
        result.eligibility = AdoptionEligibility::eligible;
    } catch (const std::exception& error) {
        reject(AdoptionEligibility::inconsistent,DiagnosticKind::environment,"adoption-evidence-mismatch",error.what());
    }
    return result;
}
Json commit_adoption_result(const Context& context, const Plan& plan) {
    const auto& package = plan.package;
    const auto state = context.root/L".coop";
    const auto record = state/L"packages"/(wide(package.name)+L".json");
    if (plan.adoption->eligibility == AdoptionEligibility::already_managed) {
        return Json{{"package",package.name},{"status","already-managed"}};
    }
    const auto id = std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64());
    const auto transaction = state/L"transactions"/id;
    const auto backup = state/L"backups"/wide(package.name)/id;
    const auto safe_parents = [&](const fs::path& path) {
        auto current = state;
        for (const auto& part : path.lexically_relative(state)) {
            validate_component(path_text(part)); current /= part;
            const auto attributes = GetFileAttributesW(current.c_str());
            if (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) throw std::runtime_error("Adoption state path contains a reparse point");
        }
    };
    safe_parents(transaction); safe_parents(backup); safe_parents(record);
    fs::create_directories(transaction);
    Json journal = {{"state","pending"},{"action","adopt"},{"package",package.name},{"backup",path_text(backup)},{"record",path_text(record)}};
    write_json(transaction/L"journal.json",journal);
    bool published = false;
    std::string record_hash;
    try {
        fs::create_directories(backup);
        Json evidence = {{"current",path_text(plan.local.current)},{"directory",path_text(plan.local.directory)},
            {"scope","Installation metadata and command entries only; installed program, declared persist links and user data are unchanged"},{"inputs",Json::array()}};
        const auto program = plan.local.directory/wide(package.artifacts.front().filename);
        std::size_t index = 0;
        for (const auto& input : plan.preconditions) {
            const bool copy = !fs::equivalent(input.path,program);
            Json item = {{"path",path_text(input.path)},{"sha256",input.sha256},{"backed_up",copy}};
            if (copy) {
                const auto filename = std::to_wstring(index++)+L"-"+input.path.filename().wstring();
                fs::copy_file(input.path,backup/filename);
                if (sha256_file(backup/filename) != input.sha256) throw std::runtime_error("Adoption backup differs from planned input");
                item["backup_file"] = path_text(filename);
            }
            evidence["inputs"].push_back(std::move(item));
        }
        write_json(backup/L"evidence.json",evidence);
        recheck_plan(plan);
        const auto persistence = verify_persistence(context,package,plan.local.directory);
        Json legacy = Json::object();
        for (const auto& command : plan.adoption->commands) legacy[command.name] = {
            {"executable_sha256",command.executable.sha256},{"metadata_sha256",command.metadata.sha256}};
        Json legacy_shortcuts = Json::object();
        for (const auto& shortcut : plan.adoption->shortcuts) legacy_shortcuts[shortcut.name] = {
            {"path",path_text(shortcut.path)},{"sha256",shortcut.sha256}};
        const Json managed = {{"name",package.name},{"version",package.version},{"architecture",package.architecture},{"bucket",package.bucket},
            {"directory",path_text(plan.local.directory)},{"manifest_sha256",package.manifest_sha256},{"status","ready"},
            {"origin","scoop"},{"shim_format","scoop"},{"legacy_shims",legacy},{"legacy_shortcuts",legacy_shortcuts},
            {"environment",expanded_environment(context,package,plan.local.current)},
            {"path_entries",expanded_path_entries(context,package,plan.local.current)},
            {"exposure_scope","Existing user environment values and shortcuts remain external evidence; uninstall removes only command entries and shortcuts whose original contents were verified during adoption"},
            {"dependencies",package.dependencies},{"persistence",persistence},
            {"versions",scan_version_evidence(context.root/L"apps"/wide(package.name))},
            {"adoption_backup",path_text(backup)}};
        write_json(transaction/L"record.json",managed);
        record_hash = sha256_file(transaction/L"record.json");
        journal["record_sha256"] = record_hash;
        journal["backup_sha256"] = sha256_file(backup/L"evidence.json");
        write_json(transaction/L"journal.json",journal);
        fs::create_directories(record.parent_path());
        if (!MoveFileExW((transaction/L"record.json").c_str(),record.c_str(),MOVEFILE_WRITE_THROUGH)) throw std::runtime_error("Adoption management record conflicts with existing data");
        published = true;
        journal["state"] = "committed"; write_json(transaction/L"journal.json",journal);
    } catch (...) {
        try {
            if (published) {
                if (sha256_file(record) != record_hash) throw std::runtime_error("Adoption record changed during rollback");
                fs::remove(record);
            }
            journal["state"] = "rolled-back"; write_json(transaction/L"journal.json",journal);
        } catch (...) { /* Preserve pending evidence if controlled rollback cannot complete. */ }
        throw;
    }
    return Json{{"package",package.name},{"version",package.version},{"status","adopted"},{"backup",path_text(backup)},
        {"persistence",verify_persistence(context,package,plan.local.directory)}};
}
Json adoption_recovery_status(const Context& context, const fs::path& journal_path, bool execute) {
    Json result = {{"journal",path_text(journal_path)},{"mode","manual"},{"status","manual"},
        {"reason","Adoption recovery cannot be verified"}};
    try {
        const auto journal = read_json(journal_path);
        if (!journal.is_object()) throw std::runtime_error("Adoption journal is not an object");
        const auto package_name = journal.value("package",std::string{});
        result["action"] = journal.value("action",std::string{});
        result["package"] = package_name;
        if (journal.value("state",std::string{}) != "pending") {
            result["mode"] = "none";
            result["status"] = "not-pending";
            result["reason"] = "Adoption journal is already resolved";
            return result;
        }
        if (journal.value("action",std::string{}) != "adopt" || package_name.empty())
            throw std::runtime_error("Adoption journal has no package identity");
        const auto state = context.root/L".coop";
        const auto record = state/L"packages"/(wide(package_name)+L".json");
        const auto backup = state/L"backups"/wide(package_name)/journal_path.parent_path().filename();
        if (!journal.contains("record") || !journal.at("record").is_string() ||
            !journal.contains("backup") || !journal.at("backup").is_string() ||
            !same_identity(fs::path(wide(journal.at("record").get<std::string>())),record) ||
            !same_identity(fs::path(wide(journal.at("backup").get<std::string>())),backup))
            throw std::runtime_error("Pending adoption journal has inconsistent owned paths");
        for (const auto& path : {journal_path,record,backup}) {
            auto current = state;
            for (const auto& part : path.lexically_relative(state)) {
                validate_component(path_text(part)); current /= part;
                const auto attributes = GetFileAttributesW(current.c_str());
                if (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_REPARSE_POINT))
                    throw std::runtime_error("Pending adoption state path contains a reparse point");
            }
        }
        std::string resolution;
        if (fs::exists(record)) {
            if (!journal.contains("record_sha256") || !journal.at("record_sha256").is_string() ||
                !journal.contains("backup_sha256") || !journal.at("backup_sha256").is_string() ||
                sha256_file(record) != journal.at("record_sha256").get<std::string>() ||
                sha256_file(backup/L"evidence.json") != journal.at("backup_sha256").get<std::string>())
                throw std::runtime_error("Pending adoption commit cannot be verified");
            resolution = "committed";
        } else {
            // Adoption only copies evidence and publishes this one management record.
            // Without that record, preserving the partial backup completes the rollback.
            resolution = "rolled-back";
        }
        result["mode"] = "automatic";
        result["status"] = execute ? resolution : "recoverable";
        result["reason"] = resolution == "committed" ?
            "The adoption management record was published before the interruption" :
            "No adoption management record was published; the partial backup is retained as evidence";
        if (execute) {
            auto resolved = journal;
            resolved["state"] = resolution;
            resolved["recovered"] = true;
            write_json(journal_path,resolved);
        }
        return result;
    } catch (const std::exception& error) {
        result["mode"] = "manual";
        result["status"] = "manual";
        result["reason"] = error.what();
        return result;
    }
}
bool recover_adoption(const Context& context, const Plan& plan, const fs::path& journal_path) {
    const auto journal = read_json(journal_path);
    if (journal.value("action",std::string{}) != "adopt" || !equal_name(journal.value("package",std::string{}),plan.package.name)) return false;
    const auto status = adoption_recovery_status(context,journal_path,true);
    if (status.value("mode",std::string{}) != "automatic" || status.value("status",std::string{}) == "manual")
        throw std::runtime_error(status.value("reason",std::string{"Pending adoption cannot be recovered"}));
    return true;
}
}
