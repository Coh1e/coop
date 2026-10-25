#include "package.hpp"
#include "data.hpp"
#include <windows.h>
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
        const auto current_blocker = package_execution_blocker(plan.package);
        if (!current_blocker.empty()) {
            reject(AdoptionEligibility::unsupported,DiagnosticKind::capability,"adoption-lifecycle-unsupported",current_blocker); return result;
        }
        if (!plan.update_candidate) {
            reject(AdoptionEligibility::untested,DiagnosticKind::verification,"missing-update-manifest","No same-source local Manifest to assess future updates"); return result;
        }
        const auto future_blocker = package_execution_blocker(*plan.update_candidate);
        if (!future_blocker.empty()) {
            reject(AdoptionEligibility::unsupported,DiagnosticKind::capability,"future-update-unsupported",future_blocker); return result;
        }
        const auto expected = context.root/L"apps"/wide(plan.package.name)/wide(plan.package.version);
        if (!fs::exists(expected) || !fs::equivalent(expected,plan.local.directory)) throw std::runtime_error("Current does not identify its recorded version directory");
        const auto artifact = expected/wide(plan.package.artifacts.front().filename);
        if (sha256_file(artifact) != plan.package.artifacts.front().sha256) throw std::runtime_error("Installed executable SHA256 differs from original Manifest");
        verify_program(artifact,plan.package.architecture);
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
            if (fs::file_size(legacy.metadata.path) > 16384) throw std::runtime_error("Scoop shim metadata exceeds size limit");
            legacy.metadata.sha256 = sha256_file(legacy.metadata.path);
            std::ifstream input(legacy.metadata.path,std::ios::binary);
            std::string line, target, arguments;
            std::set<std::string> keys;
            while (std::getline(input,line)) {
                if (line.starts_with("\xef\xbb\xbf")) line.erase(0,3);
                line = trim(line);
                if (line.empty() || line.starts_with('#') || line.starts_with(';') || line.starts_with("//")) continue;
                const auto equal = line.find('=');
                if (equal == std::string::npos) throw std::runtime_error("Invalid Scoop shim metadata line");
                const auto key = trim(line.substr(0,equal));
                const auto value = trim(line.substr(equal+1));
                if (!keys.insert(key).second) throw std::runtime_error("Duplicate Scoop shim metadata key");
                if (key == "path") target = value;
                else if (key == "args") arguments = value;
                else { reject(AdoptionEligibility::untested,DiagnosticKind::verification,"untested-shim-option","Unvalidated Scoop shim option: "+key); return result; }
            }
            if (target.size() >= 2 && target.front() == '"' && target.back() == '"') target = target.substr(1,target.size()-2);
            if (target.empty() || !fs::exists(fs::path(wide(target))) || !fs::equivalent(fs::path(wide(target)),expected/command.target) || arguments != command.arguments)
                throw std::runtime_error("Existing Scoop command entry points to a different package or arguments");
            result.commands.push_back(std::move(legacy));
        }
        result.eligibility = AdoptionEligibility::eligible;
    } catch (const std::exception& error) {
        reject(AdoptionEligibility::inconsistent,DiagnosticKind::environment,"adoption-evidence-mismatch",error.what());
    }
    return result;
}
int commit_adoption(const Context& context, const Plan& plan) {
    const auto& package = plan.package;
    const auto state = context.root/L".coop";
    const auto record = state/L"packages"/(wide(package.name)+L".json");
    if (plan.adoption->eligibility == AdoptionEligibility::already_managed) {
        std::cout << Json{{"package",package.name},{"status","already-managed"}}.dump() << '\n'; return 0;
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
            {"scope","Installation metadata and command entries only; installed program and user data are unchanged"},{"inputs",Json::array()}};
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
        Json legacy = Json::object();
        for (const auto& command : plan.adoption->commands) legacy[command.name] = {
            {"executable_sha256",command.executable.sha256},{"metadata_sha256",command.metadata.sha256}};
        const Json managed = {{"name",package.name},{"version",package.version},{"architecture",package.architecture},{"bucket",package.bucket},
            {"directory",path_text(plan.local.directory)},{"manifest_sha256",package.manifest_sha256},{"status","ready"},
            {"origin","scoop"},{"shim_format","scoop"},{"legacy_shims",legacy},{"adoption_backup",path_text(backup)}};
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
    std::cout << Json{{"package",package.name},{"version",package.version},{"status","adopted"},{"backup",path_text(backup)}}.dump(2) << '\n';
    return 0;
}
bool recover_adoption(const Context& context, const Plan& plan, const fs::path& journal_path) {
    const auto journal = read_json(journal_path);
    if (journal.value("action",std::string{}) != "adopt" || !equal_name(journal.value("package",std::string{}),plan.package.name)) return false;
    const auto state = context.root/L".coop";
    const auto record = state/L"packages"/(wide(plan.package.name)+L".json");
    const auto backup = state/L"backups"/wide(plan.package.name)/journal_path.parent_path().filename();
    if (!same_identity(fs::path(wide(journal.at("record").get<std::string>())),record) ||
        !same_identity(fs::path(wide(journal.at("backup").get<std::string>())),backup))
        throw std::runtime_error("Pending adoption journal has inconsistent owned paths");
    for (const auto& path : {journal_path,record,backup}) {
        auto current = state;
        for (const auto& part : path.lexically_relative(state)) {
            validate_component(path_text(part)); current /= part;
            const auto attributes = GetFileAttributesW(current.c_str());
            if (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) throw std::runtime_error("Pending adoption state path contains a reparse point");
        }
    }
    auto resolved = journal;
    if (fs::exists(record)) {
        if (!journal.contains("record_sha256") || sha256_file(record) != journal.at("record_sha256").get<std::string>() ||
            sha256_file(backup/L"evidence.json") != journal.at("backup_sha256").get<std::string>()) throw std::runtime_error("Pending adoption commit cannot be verified");
        resolved["state"] = "committed";
    } else {
        // Adoption only copies evidence and publishes this one management record.
        // Without that record, preserving the partial backup completes the rollback.
        resolved["state"] = "rolled-back";
    }
    write_json(journal_path,resolved);
    return true;
}
}
