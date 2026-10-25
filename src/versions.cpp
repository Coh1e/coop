#include "versions.hpp"
#include "package.hpp"
#include <windows.h>
#include <algorithm>
#include <iostream>
#include <map>
#include <set>
#include <stdexcept>

namespace coop {
namespace {
std::string version_text(const Json& value) {
    return value.is_string() ? value.get<std::string>() : std::string{};
}

bool is_under(const fs::path& path, const fs::path& base) {
    const auto relative = path.lexically_relative(base);
    if (relative.empty() || relative.is_absolute() || relative == L".") return false;
    return *relative.begin() != L"..";
}

Json pending_transactions(const Context& context) {
    Json result = Json::array();
    const auto directory = context.root/L".coop"/L"transactions";
    if (!fs::is_directory(directory)) return result;
    for (const auto& entry : fs::directory_iterator(directory)) {
        if (!entry.is_directory()) continue;
        const auto journal = entry.path()/L"journal.json";
        if (!fs::is_regular_file(journal)) continue;
        try {
            if (read_json(journal).value("state",std::string{}) == "pending")
                result.push_back(path_text(journal));
        } catch (const std::exception&) {
            // A malformed journal does not hide old versions from query output, but cleanup
            // cannot prove that no recovery needs them. Treat it as pending evidence.
            result.push_back(path_text(journal));
        }
    }
    return result;
}

Json normalize_versions(const Json& value) {
    Json result = Json::array();
    if (!value.is_array()) return result;
    for (const auto& entry : value) {
        if (!entry.is_object()) continue;
        const auto version = version_text(entry.value("version",Json{}));
        const auto directory = version_text(entry.value("directory",Json{}));
        if (version.empty() || directory.empty()) continue;
        Json normalized = {{"version",version},{"directory",directory},
            {"manifest_sha256",version_text(entry.value("manifest_sha256",Json{}))},
            {"install_record_sha256",version_text(entry.value("install_record_sha256",Json{}))},
            {"tree_stamp",version_text(entry.value("tree_stamp",Json{}))},
            {"provenance",version_text(entry.value("provenance",Json{}))}};
        result.push_back(std::move(normalized));
    }
    return result;
}

Json read_versions_file(const fs::path& path) {
    if (!fs::is_regular_file(path)) return Json::array();
    try { return normalize_versions(read_json(path).value("versions",Json::array())); }
    catch (const std::exception&) { return Json::array(); }
}

std::string lower_key(const std::string& value) {
    std::string result = value;
    for (auto& character : result)
        character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    return result;
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
    if (attributes & FILE_ATTRIBUTE_DIRECTORY) {
        for (const auto& entry : fs::directory_iterator(path)) erase_tree(entry.path());
    }
    if (!fs::remove(path)) throw std::runtime_error("Cannot remove managed path");
}

void save_journal(const fs::path& path, const Json& journal) {
    write_json(path,journal);
}

// A cleanup crash can leave moved version directories inside its transaction. Finishing that
// operation is idempotent: if the version is still held, put it back where it came from.
void recover_cleanup_transactions(const Context& context) {
    const auto directory = context.root/L".coop"/L"transactions";
    if (!fs::is_directory(directory)) return;
    for (const auto& entry : fs::directory_iterator(directory)) {
        if (!entry.is_directory()) continue;
        const auto journal_path = entry.path()/L"journal.json";
        if (!fs::is_regular_file(journal_path)) continue;
        auto journal = read_json(journal_path);
        if (journal.value("state",std::string{}) != "pending" || journal.value("action",std::string{}) != "cleanup") continue;
        for (auto& candidate : journal.at("candidates")) {
            const fs::path from(wide(candidate.at("from").get<std::string>()));
            const fs::path trash(wide(candidate.at("trash").get<std::string>()));
            if (GetFileAttributesW(trash.c_str()) != INVALID_FILE_ATTRIBUTES) {
                try { erase_tree(trash); }
                catch (const std::exception&) {
                    if (GetFileAttributesW(from.c_str()) != INVALID_FILE_ATTRIBUTES ||
                        !MoveFileExW(trash.c_str(),from.c_str(),MOVEFILE_WRITE_THROUGH))
                        throw std::runtime_error("Interrupted cleanup cannot be completed: "+path_text(trash));
                }
            }
        }
        journal["state"] = "committed";
        save_journal(journal_path,journal);
    }
}

Json filter_versions(const Json& record, const std::set<std::string>& deleted) {
    if (!record.is_object()) return record;
    auto result = record;
    if (!result.contains("versions") || !result.at("versions").is_array()) return result;
    Json versions = Json::array();
    for (const auto& entry : result.at("versions"))
        if (!entry.is_object() || !deleted.contains(lower_key(version_text(entry.value("version",Json{})))))
            versions.push_back(entry);
    result["versions"] = std::move(versions);
    return result;
}

struct CleanupResult {
    Json value;
    bool failed = false;
};

bool has_current_problem(const Json& inventory) {
    return std::any_of(inventory.begin(),inventory.end(),[](const Json& entry) {
        const auto status = entry.value("status",std::string{});
        return status == "current-missing" || status == "current-mismatch";
    });
}

CleanupResult cleanup_package(const Context& context, const std::string& package_name, bool dry_run) {
    CleanupResult outcome;
    const auto managed_path = context.root/L".coop"/L"packages"/(wide(package_name)+L".json");
    const auto retained_path = context.root/L".coop"/L"retained"/(wide(package_name)+L".json");
    if (!fs::is_regular_file(managed_path) && !fs::is_regular_file(retained_path)) {
        outcome.failed = true;
        outcome.value = {{"package",package_name},{"action","cleanup"},{"status","blocked"},
            {"reason","Package has no Coop management or retained-version evidence"}};
        return outcome;
    }
    const auto managed_hash = fs::is_regular_file(managed_path) ? sha256_file(managed_path) : std::string{};
    const auto retained_hash = fs::is_regular_file(retained_path) ? sha256_file(retained_path) : std::string{};
    auto inventory = version_cleanup_inventory(context,package_name,std::string{});
    Json pending = pending_transactions(context);
    Json cleanable = Json::array();
    Json unmanageable = Json::array();
    for (const auto& entry : inventory) {
        if (entry.value("status",std::string{}) == "cleanable") cleanable.push_back(entry);
        else if (entry.value("status",std::string{}) != "already-absent") unmanageable.push_back(entry);
    }
    Json result = {{"package",package_name},{"action","cleanup"},
        {"versions",inventory},{"removable",cleanable},{"unmanageable",unmanageable},
        {"pending_transactions",pending}};
    if (has_current_problem(inventory)) {
        result["status"] = "blocked";
        result["removable"] = Json::array();
        result["reason"] = "The management record's current version or current link is missing or inconsistent; cleanup is blocked until the installation is repaired";
        outcome.failed = true;
        outcome.value = std::move(result);
        return outcome;
    }
    if (dry_run) {
        result["status"] = !pending.empty() ? "blocked" : cleanable.empty() && unmanageable.empty() ? "nothing-to-clean" :
            unmanageable.empty() ? "planned" : "partial";
        if (!pending.empty()) result["reason"] = "A pending transaction requires recovery before cleanup";
        outcome.failed = !pending.empty() || !unmanageable.empty();
        outcome.value = std::move(result);
        return outcome;
    }
    RootLock lock(context.root);
    recover_cleanup_transactions(context);
    pending = pending_transactions(context);
    if (!pending.empty()) {
        result["status"] = "blocked";
        result["reason"] = "A pending transaction requires recovery before cleanup: "+pending.front().get<std::string>();
        outcome.failed = true;
        outcome.value = std::move(result);
        return outcome;
    }
    inventory = version_cleanup_inventory(context,package_name,std::string{});
    cleanable = Json::array();
    unmanageable = Json::array();
    for (const auto& entry : inventory) {
        if (entry.value("status",std::string{}) == "cleanable") cleanable.push_back(entry);
        else if (entry.value("status",std::string{}) != "already-absent") unmanageable.push_back(entry);
    }
    result["versions"] = inventory;
    result["removable"] = cleanable;
    result["unmanageable"] = unmanageable;
    if (has_current_problem(inventory)) {
        result["status"] = "blocked";
        result["removable"] = Json::array();
        result["reason"] = "The management record's current version or current link is missing or inconsistent; cleanup is blocked until the installation is repaired";
        outcome.failed = true;
        outcome.value = std::move(result);
        return outcome;
    }
    if (cleanable.empty()) {
        result["status"] = unmanageable.empty() ? "nothing-to-clean" : "partial";
        outcome.failed = !unmanageable.empty();
        outcome.value = std::move(result);
        return outcome;
    }
    const auto verify_evidence = [&]() {
        if (!managed_hash.empty() && (!fs::is_regular_file(managed_path) || sha256_file(managed_path) != managed_hash))
            throw std::runtime_error("Management record changed during cleanup; no version was deleted");
        if (!retained_hash.empty() && (!fs::is_regular_file(retained_path) || sha256_file(retained_path) != retained_hash))
            throw std::runtime_error("Retained-version evidence changed during cleanup; no version was deleted");
    };
    verify_evidence();
    const auto transaction = context.root/L".coop"/L"transactions"/
        (L"cleanup-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));
    Json journal = {{"state","pending"},{"action","cleanup"},{"package",package_name},{"candidates",Json::array()}};
    std::set<std::string> deleted;
    Json removed = Json::array();
    Json kept = Json::array();
    try {
        fs::create_directories(transaction);
        save_journal(transaction/L"journal.json",journal);
        for (std::size_t index = 0; index < cleanable.size(); ++index) {
            const auto entry = cleanable[index];
            const auto version = entry.at("version").get<std::string>();
            const fs::path from(wide(entry.at("directory").get<std::string>()));
            const auto current = version_evidence(from,version);
            const auto expected_stamp = entry.value("tree_stamp",std::string{});
            std::string current_stamp;
            try { current_stamp = version_tree_stamp(from); }
            catch (const std::exception&) { current_stamp = "unreadable"; }
            if (current.value("status",std::string{}) != "retained" ||
                current.value("manifest_sha256",std::string{}) != entry.value("manifest_sha256",std::string{}) ||
                (!expected_stamp.empty() && current_stamp != expected_stamp)) {
                auto changed = entry; changed["status"] = "modified";
                changed["reason"] = "Version evidence changed after preview; it was not moved";
                kept.push_back(changed); unmanageable.push_back(changed);
                continue;
            }
            verify_evidence();
            const auto trash = transaction/(std::to_wstring(index)+L"-"+wide(version));
            journal["candidates"].push_back({{"version",version},{"from",path_text(from)},
                {"trash",path_text(trash)},{"moved",false},{"recovery",false}});
            save_journal(transaction/L"journal.json",journal);
            if (!MoveFileExW(from.c_str(),trash.c_str(),MOVEFILE_WRITE_THROUGH)) {
                const auto error = GetLastError();
                auto skipped = entry;
                skipped["status"] = "in-use";
                skipped["reason"] = "Version directory cannot be moved without forcing a running program (Windows error "+
                    std::to_string(error)+")";
                kept.push_back(skipped); unmanageable.push_back(skipped);
                journal["candidates"].back()["error"] = error;
                save_journal(transaction/L"journal.json",journal);
                continue;
            }
            journal["candidates"].back()["moved"] = true;
            save_journal(transaction/L"journal.json",journal);
        }
        for (std::size_t index = 0; index < journal.at("candidates").size(); ++index) {
            auto& candidate = journal["candidates"][index];
            if (!candidate.value("moved",false)) continue;
            const fs::path from(wide(candidate.at("from").get<std::string>()));
            const fs::path trash(wide(candidate.at("trash").get<std::string>()));
            const auto version = candidate.at("version").get<std::string>();
            try { erase_tree(trash); }
            catch (const std::exception& error) {
                if (GetFileAttributesW(from.c_str()) == INVALID_FILE_ATTRIBUTES &&
                    MoveFileExW(trash.c_str(),from.c_str(),MOVEFILE_WRITE_THROUGH)) {
                    auto skipped = Json{{"version",version},{"directory",path_text(from)},{"status","in-use"},
                        {"reason",std::string("Version is in use; it was restored after deletion failed: ")+error.what()}};
                    kept.push_back(skipped); unmanageable.push_back(skipped);
                    candidate["moved"] = false;
                    save_journal(transaction/L"journal.json",journal);
                    continue;
                }
                candidate["recovery"] = true;
                save_journal(transaction/L"journal.json",journal);
                throw std::runtime_error("Cleanup of "+version+" needs recovery at "+path_text(trash)+": "+error.what());
            }
            deleted.insert(lower_key(version));
            removed.push_back({{"version",version},{"directory",path_text(from)},{"status","deleted"}});
            candidate["moved"] = false;
            candidate["deleted"] = true;
            save_journal(transaction/L"journal.json",journal);
        }
        journal["state"] = "committed";
        save_journal(transaction/L"journal.json",journal);
    } catch (const std::exception&) {
        result["versions"] = inventory;
        result["unmanageable"] = unmanageable;
        result["removed"] = removed;
        result["retained"] = kept;
        result["status"] = "partial";
        result["reason"] = "Cleanup stopped before all old versions were removed; inspect the cleanup journal";
        outcome.failed = true;
        outcome.value = std::move(result);
        return outcome;
    }
    if (!deleted.empty()) {
        try {
            if (fs::is_regular_file(managed_path)) {
                if (sha256_file(managed_path) != managed_hash)
                    throw std::runtime_error("Management record changed before deletion evidence could be updated");
                auto record = read_json(managed_path);
                record = filter_versions(record,deleted);
                write_json(managed_path,record);
            }
            if (fs::is_regular_file(retained_path)) {
                if (sha256_file(retained_path) != retained_hash)
                    throw std::runtime_error("Retained-version evidence changed before it could be updated");
                auto record = read_json(retained_path);
                record = filter_versions(record,deleted);
                if (!record.value("versions",Json::array()).empty()) write_json(retained_path,record);
                else fs::remove(retained_path);
            }
        } catch (const std::exception& error) {
            result["removed"] = removed;
            result["retained"] = kept;
            result["status"] = "partial";
            result["reason"] = std::string("Old versions were removed, but version evidence could not be updated: ")+error.what();
            outcome.failed = true;
            outcome.value = std::move(result);
            return outcome;
        }
    }
    try { erase_tree(transaction); } catch (const std::exception&) { /* Committed cleanup evidence may be pruned later. */ }
    result["removed"] = removed;
    result["retained"] = kept;
    result["unmanageable"] = unmanageable;
    result["status"] = unmanageable.empty() ? "success" : "partial";
    if (!unmanageable.empty()) result["reason"] = "Some local old-version directories are not safely cleanable";
    outcome.failed = !unmanageable.empty();
    outcome.value = std::move(result);
    return outcome;
}

std::vector<std::string> known_packages(const Context& context) {
    std::set<std::string> names;
    for (const auto& directory : {context.root/L".coop"/L"packages",context.root/L".coop"/L"retained"}) {
        if (!fs::is_directory(directory)) continue;
        for (const auto& entry : fs::directory_iterator(directory)) {
            if (!entry.is_regular_file() || entry.path().extension() != L".json") continue;
            names.insert(path_text(entry.path().stem()));
        }
    }
    return std::vector<std::string>(names.begin(),names.end());
}
}
Json version_evidence(const fs::path& directory, const std::string& version) {
    Json result = {{"version",version},{"directory",path_text(directory)},{"status","unmanageable"},
        {"reason","unknown"},{"manifest_present",false},{"install_record_present",false},
        {"manifest_path",Json(nullptr)},{"manifest_sha256",Json(nullptr)},
        {"install_record_path",Json(nullptr)},{"install_record_sha256",Json(nullptr)},
        {"manifest_version",Json(nullptr)},{"download_url",Json(nullptr)}};
    const auto attributes = GetFileAttributesW(directory.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES) {
        result["status"] = "already-absent";
        result["reason"] = "Version directory is missing";
        return result;
    }
    if (attributes & FILE_ATTRIBUTE_REPARSE_POINT) {
        result["status"] = "unsafe-reparse-point";
        result["reason"] = "Version directory is a reparse point; it is not followed or deleted";
        return result;
    }
    if (!(attributes & FILE_ATTRIBUTE_DIRECTORY)) {
        result["status"] = "unmanageable";
        result["reason"] = "Version path is not a directory";
        return result;
    }
    const auto manifest = installed_record(directory,L"manifest");
    const auto install = installed_record(directory,L"install");
    result["manifest_path"] = path_text(manifest);
    result["install_record_path"] = path_text(install);
    result["manifest_present"] = fs::is_regular_file(manifest);
    result["install_record_present"] = fs::is_regular_file(install);
    if (!fs::is_regular_file(manifest)) {
        result["reason"] = "Historical Manifest is missing; no download URL is guessed";
        return result;
    }
    result["manifest_sha256"] = sha256_file(manifest);
    if (fs::is_regular_file(install)) result["install_record_sha256"] = sha256_file(install);
    try {
        const auto parsed = read_json(manifest);
        const auto manifest_version = parsed.value("version",std::string{});
        result["manifest_version"] = manifest_version;
        if (manifest_version.empty() || !equal_name(manifest_version,version)) {
            result["reason"] = "Manifest version does not match the local version directory";
            return result;
        }
        if (parsed.contains("url") && parsed.at("url").is_string())
            result["download_url"] = parsed.at("url").get<std::string>();
    } catch (const std::exception& error) {
        result["reason"] = std::string("Manifest cannot be read: ")+error.what();
        return result;
    }
    if (!fs::is_regular_file(install)) {
        result["reason"] = "Installation record is missing; ownership of this version cannot be verified";
        return result;
    }
    result["status"] = "retained";
    result["reason"] = "Local version evidence is available";
    return result;
}
void collect_tree_stamp(const fs::path& directory, const fs::path& base, std::vector<std::string>& entries) {
    for (const auto& entry : fs::directory_iterator(directory)) {
        const auto attributes = GetFileAttributesW(entry.path().c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES) throw std::runtime_error("Cannot read version entry attributes");
        const auto relative = path_text(entry.path().lexically_relative(base));
        if (attributes & FILE_ATTRIBUTE_REPARSE_POINT) {
            entries.push_back(relative+"|reparse");
            continue;
        }
        if (attributes & FILE_ATTRIBUTE_DIRECTORY) {
            entries.push_back(relative+"|dir");
            collect_tree_stamp(entry.path(),base,entries);
            continue;
        }
        WIN32_FILE_ATTRIBUTE_DATA data{};
        if (!GetFileAttributesExW(entry.path().c_str(),GetFileExInfoStandard,&data))
            throw std::runtime_error("Cannot read version file attributes");
        ULARGE_INTEGER size{};
        size.LowPart = data.nFileSizeLow;
        size.HighPart = data.nFileSizeHigh;
        entries.push_back(relative+"|file|"+std::to_string(size.QuadPart)+"|"+
            std::to_string(data.ftLastWriteTime.dwHighDateTime)+":"+std::to_string(data.ftLastWriteTime.dwLowDateTime));
    }
}
std::string version_tree_stamp(const fs::path& directory) {
    const auto attributes = GetFileAttributesW(directory.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
        !(attributes & FILE_ATTRIBUTE_DIRECTORY))
        throw std::runtime_error("Version directory cannot be stamped");
    std::vector<std::string> entries;
    collect_tree_stamp(directory,directory,entries);
    std::sort(entries.begin(),entries.end());
    std::string material;
    for (const auto& entry : entries) { material += entry; material += '\n'; }
    return sha256_text(material);
}
Json scan_version_evidence(const fs::path& app_directory) {
    Json result = Json::array();
    if (!fs::is_directory(app_directory)) return result;
    for (const auto& entry : fs::directory_iterator(app_directory)) {
        if (entry.path().filename() == L"current") continue;
        const auto version = path_text(entry.path().filename());
        if (version.empty()) continue;
        auto evidence = version_evidence(entry.path(),version);
        if (evidence.value("status",std::string{}) == "retained") {
            try { evidence["tree_stamp"] = version_tree_stamp(entry.path()); }
            catch (const std::exception&) { /* Cleanup reports unreadable trees instead of trusting them. */ }
        }
        result.push_back(std::move(evidence));
    }
    std::sort(result.begin(),result.end(),[](const Json& a, const Json& b) {
        return a.at("version").get<std::string>() < b.at("version").get<std::string>();
    });
    return result;
}
Json recorded_version_evidence(const Context& context, const std::string& package_name) {
    const auto app = context.root/L"apps"/wide(package_name);
    const auto managed_path = context.root/L".coop"/L"packages"/(wide(package_name)+L".json");
    const auto retained_path = context.root/L".coop"/L"retained"/(wide(package_name)+L".json");
    Json managed = Json::array();
    if (fs::is_regular_file(managed_path)) {
        try { managed = normalize_versions(read_json(managed_path).value("versions",Json::array())); }
        catch (const std::exception&) { managed = Json::array(); }
    }
    Json retained = read_versions_file(retained_path);
    Json result = Json::array();
    std::set<std::string> seen;
    for (const auto& source : {managed,retained}) for (const auto& entry : source) {
        const auto version = entry.at("version").get<std::string>();
        const auto key = lower_key(version);
        if (seen.contains(key)) continue;
        const fs::path directory(wide(entry.at("directory").get<std::string>()));
        if (!directory.is_absolute() || !is_under(directory,app)) continue;
        seen.insert(key);
        result.push_back(entry);
    }
    return result;
}
Json version_cleanup_inventory(const Context& context, const std::string& package_name,
                               const std::string& current_version) {
    const auto app = context.root/L"apps"/wide(package_name);
    const auto managed_path = context.root/L".coop"/L"packages"/(wide(package_name)+L".json");
    std::string managed_version;
    fs::path managed_directory;
    if (fs::is_regular_file(managed_path)) {
        try {
            const auto managed = read_json(managed_path);
            if (managed.contains("version") && managed.at("version").is_string())
                managed_version = managed.at("version").get<std::string>();
            if (managed.contains("directory") && managed.at("directory").is_string())
                managed_directory = fs::path(wide(managed.at("directory").get<std::string>()));
        } catch (const std::exception&) {
            // A malformed management record cannot prove which version is current. Cleanup
            // will not delete anything unless the normal current link and evidence agree.
        }
    }
    const bool has_managed_current = !managed_version.empty() || !managed_directory.empty();
    const auto recorded = recorded_version_evidence(context,package_name);
    const auto actual = scan_version_evidence(app);
    const auto pending = pending_transactions(context);
    const bool recovery_protected = !pending.empty();
    const auto current = app/L"current";
    const bool current_exists = fs::is_directory(current);
    Json result = Json::array();
    std::set<std::string> actual_versions;
    for (auto entry : actual) {
        const auto version = entry.at("version").get<std::string>();
        actual_versions.insert(lower_key(version));
        const fs::path directory = app/wide(version);
        const bool protected_by_version = (!current_version.empty() && equal_name(version,current_version)) ||
            (!managed_version.empty() && equal_name(version,managed_version));
        const bool protected_by_directory = !managed_directory.empty() && same_identity(directory,managed_directory);
        const bool published_current = current_exists && same_identity(directory,current);
        if (protected_by_version || protected_by_directory) {
            const bool record_points_at_current = managed_directory.empty() ? published_current :
                same_identity(current,managed_directory);
            if (published_current && record_points_at_current) continue;
            entry["recorded"] = true;
            entry["status"] = current_exists ? "current-mismatch" : "current-missing";
            entry["reason"] = current_exists ?
                "Management record names a current version that is not the published current link; cleanup is blocked" :
                "Management record names this version as current but the current link is missing or dangling; cleanup is blocked";
            result.push_back(std::move(entry));
            continue;
        }
        if (published_current) continue;
        entry["recorded"] = false;
        if (entry.at("status").get<std::string>() == "retained") {
            try { entry["tree_stamp"] = version_tree_stamp(app/wide(version)); }
            catch (const std::exception& error) {
                entry["status"] = "unmanageable";
                entry["reason"] = std::string("Version contents cannot be inspected: ")+error.what();
            }
        }
        const auto record = std::find_if(recorded.begin(),recorded.end(),[&](const Json& item) {
            return equal_name(item.at("version").get<std::string>(),version);
        });
        if (record == recorded.end()) {
            if (entry.at("status").get<std::string>() == "retained") entry["status"] = "no-coop-version-record";
            entry["reason"] = "No Coop version record exists for this local directory; ownership is unverified";
            result.push_back(std::move(entry));
            continue;
        }
        entry["recorded"] = true;
        entry["provenance"] = record->value("provenance",std::string{});
        const fs::path recorded_directory(wide(record->at("directory").get<std::string>()));
        if (!same_identity(recorded_directory,app/wide(version))) {
            entry["status"] = "recorded-path-changed";
            entry["reason"] = "Recorded version directory no longer matches this local path";
            result.push_back(std::move(entry));
            continue;
        }
        if (entry.at("status").get<std::string>() != "retained") {
            result.push_back(std::move(entry));
            continue;
        }
        const auto expected_manifest = record->value("manifest_sha256",std::string{});
        const auto expected_install = record->value("install_record_sha256",std::string{});
        const auto expected_stamp = record->value("tree_stamp",std::string{});
        if (!expected_stamp.empty() && entry.value("tree_stamp",std::string{}) != expected_stamp) {
            entry["status"] = "modified";
            entry["reason"] = "Version contents changed after Coop recorded them; refusing to delete them";
        } else if (!expected_manifest.empty() && entry.value("manifest_sha256",std::string{}) != expected_manifest) {
            entry["status"] = "modified";
            entry["reason"] = "Manifest changed after Coop recorded this version; refusing to delete it";
        } else if (!expected_install.empty() && entry.value("install_record_sha256",std::string{}) != expected_install) {
            entry["status"] = "modified";
            entry["reason"] = "Installation record changed after Coop recorded this version; refusing to delete it";
        } else if (recovery_protected) {
            entry["status"] = "recovery-protected";
            entry["reason"] = "A pending transaction may need this version for recovery";
        } else {
            entry["status"] = "cleanable";
            entry["reason"] = "Recorded local version is not current and has no pending recovery dependency";
        }
        result.push_back(std::move(entry));
    }
    for (const auto& record : recorded) {
        const auto version = record.at("version").get<std::string>();
        if (actual_versions.contains(lower_key(version))) continue;
        const fs::path directory(wide(record.at("directory").get<std::string>()));
        const bool protected_by_version = (!current_version.empty() && equal_name(version,current_version)) ||
            (!managed_version.empty() && equal_name(version,managed_version));
        const bool protected_by_directory = !managed_directory.empty() && same_identity(directory,managed_directory);
        if (protected_by_version || protected_by_directory) {
            if (has_managed_current) result.push_back({{"version",version},{"directory",record.at("directory").get<std::string>()},
                {"status",current_exists ? "current-mismatch" : "current-missing"},
                {"reason",current_exists ? "Management record names a current version that is not published" :
                    "Management record names this version as current but the version directory is missing; cleanup is blocked"},
                {"manifest_present",false},{"install_record_present",false},{"recorded",true},
                {"provenance",record.value("provenance",std::string{})}});
            continue;
        }
        if (current_exists && same_identity(directory,current)) continue;
        result.push_back({{"version",version},{"directory",record.at("directory").get<std::string>()},
            {"status","already-absent"},{"reason","Recorded old version is no longer present"},
            {"manifest_present",false},{"install_record_present",false},{"recorded",true},
            {"provenance",record.value("provenance",std::string{})}});
    }
    std::sort(result.begin(),result.end(),[](const Json& a, const Json& b) {
        return a.at("version").get<std::string>() < b.at("version").get<std::string>();
    });
    return result;
}
int cleanup_command(const Context& context, const std::vector<std::wstring>& names, bool dry_run) {
    Json results = Json::array();
    std::vector<std::string> packages;
    for (const auto& name : names) packages.push_back(utf8(name));
    if (packages.empty()) packages = known_packages(context);
    bool failed = false;
    for (const auto& name : packages) {
        const auto outcome = cleanup_package(context,name,dry_run);
        results.push_back(outcome.value);
        failed = failed || outcome.failed;
    }
    if (context.json_output) std::cout << results.dump(2,' ',false,Json::error_handler_t::replace) << '\n';
    else {
        for (const auto& item : results) {
            std::cout << item.value("package",std::string{}) << ": " << item.value("status",std::string{}) << '\n';
            for (const auto& entry : item.value("removed",Json::array())) std::cout << "  removed " << entry.value("version",std::string{}) << '\n';
            if (item.contains("reason")) std::cerr << "coop: " << item.at("reason").get<std::string>() << '\n';
            for (const auto& entry : item.value("unmanageable",Json::array()))
                std::cerr << "coop: " << item.value("package",std::string{}) << " " <<
                    entry.value("version",std::string{}) << ": " << entry.value("reason",std::string{}) << '\n';
        }
    }
    return failed ? 1 : 0;
}
}
