#include "catalog_index.hpp"
#include "data.hpp"
#include "ir.hpp"
#include "persist.hpp"
#include "recovery.hpp"
#include "versions.hpp"
#include <algorithm>
#include <iostream>
#include <stdexcept>
#include <cctype>
#include <map>
#include <set>

namespace coop {
static std::string lowercase(std::string value);
// While an update or uninstall is pending, the old management record may already have been
// moved into the transaction. Readers then use that last committed record instead of the
// partially published current link, so query output never presents an intermediate version as
// the installed fact.
static Json previous_record(const Context& context, const std::string& name, const Json& recovery) {
    const auto action = recovery.value("action",std::string{});
    if (action != "update" && action != "uninstall") return Json();
    const auto journal_path = fs::path(wide(recovery.value("journal",std::string{})));
    if (!fs::is_regular_file(journal_path)) return Json();
    try {
        const auto journal = read_json(journal_path);
        for (const auto& move : journal.value("moves",Json::array())) {
            if (!move.is_object() || !move.contains("to") || !move.at("to").is_string()) continue;
            const fs::path candidate(wide(move.at("to").get<std::string>()));
            const auto filename = candidate.filename().wstring();
            if (filename != L"old-managed-record.json" && filename != L"managed-record.json") continue;
            if (!recovery_record_path_allowed(context,candidate) || !fs::is_regular_file(candidate)) continue;
            const auto record = read_json(candidate);
            if (!record.is_object() || !record.contains("name") || !record.at("name").is_string() ||
                !equal_name(record.at("name").get<std::string>(),name)) continue;
            return record;
        }
    } catch (const std::exception&) { /* The current published record remains the fallback. */ }
    return Json();
}
static void list_scope(Json& result, const Context& context, const fs::path& root, const std::string& scope,
                       bool recovery_protected) {
    // Installation facts come from the shared Scoop layout through the IR adapter. Coop's private
    // records are optional management metadata read separately below, so they can never decide
    // whether an installed package is visible or block a query when they are missing or stale.
    for (const auto& fact : ir::read_installations(root)) {
        Json item = {{"name",fact.name}, {"version",fact.present ? Json(fact.version) : Json(nullptr)},
            {"scope",scope}, {"read_only",scope == "global"}, {"management","unadopted"}, {"diagnostics",Json::array()}};
        Json details = Json::array();
        for (const auto& diagnostic : fact.diagnostics) {
            item["diagnostics"].push_back(diagnostic.message);
            details.push_back({{"layer",ir::layer_name(diagnostic.layer)},{"code",diagnostic.code},{"message",diagnostic.message}});
        }
        if (fact.present) {
            item["bucket"] = fact.bucket;
            item["source"] = fact.source;
            item["synced_at"] = nullptr;
            item["architecture"] = fact.architecture;
            item["directory"] = path_text(fact.directory);
            item["status"] = "installed";
            if (scope == "user")
                item["persistence"] = persistence_plan_json(context,fact.name,fact.persistence,fact.directory);
        }
        if (scope == "user") {
            const auto managed = root/L".coop"/L"packages"/(wide(fact.name)+L".json");
            if (fs::exists(managed)) try {
                const auto record = read_json(managed);
                item["management"] = "managed";
                item["status"] = record.value("status",std::string("unknown"));
                item["origin"] = record.value("origin",std::string("coop"));
            } catch (const std::exception& error) {
                const auto message = std::string("Coop management record is unreadable; shared installation facts are still reported: ")+error.what();
                item["diagnostics"].push_back(message);
                details.push_back({{"layer","adapter"},{"code","coop-record-unreadable"},{"message",message}});
            }
        }
        item["diagnostic_details"] = std::move(details);
        if (scope == "user") {
            const auto current_version = item.at("version").is_string() ? item.at("version").get<std::string>() : std::string{};
            item["older_versions"] = retained_versions(context,item.at("name").get<std::string>(),current_version);
            item["old_versions"] = version_cleanup_inventory(context,item.at("name").get<std::string>(),current_version,recovery_protected);
        }
        result.push_back(std::move(item));
    }
}
Json installed_packages(const Context& context) {
    // One journal scan serves both the pending-recovery entries and the old-version inventory's
    // recovery protection flag; re-reading the whole transaction history per package made a listing
    // slower as settled journals accumulated.
    const Json recovery_report = pending_recovery_report(context,false);
    const bool recovery_protected = !recovery_report.empty();
    Json result = Json::array();
    list_scope(result,context,context.root, "user", recovery_protected);
    if (context.global_root) list_scope(result,context,*context.global_root, "global", recovery_protected);
    std::map<std::string,std::pair<fs::file_time_type,Json>> operations;
    const auto transactions = context.root/L".coop"/L"transactions";
    if (fs::is_directory(transactions)) for (const auto& entry : fs::directory_iterator(transactions)) {
        const auto path = entry.path()/L"journal.json";
        if (!fs::is_regular_file(path)) continue;
        try {
            const auto journal = read_json(path);
            const auto name = lowercase(journal.at("package").get<std::string>());
            const auto time = fs::last_write_time(path);
            const auto found = operations.find(name);
            if (found == operations.end()) operations[name] = {time,journal};
            else {
                const bool pending = journal.value("state",std::string{}) == "pending";
                const bool previous_pending = found->second.second.value("state",std::string{}) == "pending";
                if (pending != previous_pending ? pending : time > found->second.first) operations[name] = {time,journal};
            }
        } catch (const std::exception&) { /* A malformed journal does not hide queryable installations. */ }
    }
    std::map<std::string,Json> recoveries;
    for (const auto& entry : recovery_report)
        if (entry.is_object() && entry.contains("package") && entry.at("package").is_string()) {
            const auto name = entry.at("package").get<std::string>();
            if (!name.empty()) recoveries[lowercase(name)] = entry;
        }
    std::set<std::string> listed;
    for (auto& item : result) {
        if (item.at("scope") != "user") continue;
        const auto key = lowercase(item.at("name").get<std::string>());
        listed.insert(key);
        const auto operation = operations.find(key);
        if (operation == operations.end()) item["last_operation"] = "none";
        else {
            const auto& journal = operation->second.second;
            const auto state = journal.value("state",std::string{});
            item["last_operation"] = state == "committed" ? "succeeded" : state == "rolled-back" ? "failed" : "pending-recovery";
            item["operation_action"] = journal.value("action",std::string("unknown"));
            if (state == "committed" && journal.value("action",std::string{}) == "uninstall" && !fs::is_directory(context.root/L"apps"/wide(item.at("name"))/L"current")) {
                item["status"] = "uninstalled"; item["management"] = "none"; item["diagnostics"] = Json::array();
            }
        }
        const auto recovery = recoveries.find(key);
        if (recovery != recoveries.end()) {
            item["last_operation"] = "pending-recovery";
            item["operation_action"] = recovery->second.value("action",std::string("unknown"));
            const auto old = previous_record(context,item.at("name").get<std::string>(),recovery->second);
            if (old.is_object()) {
                for (const auto* field : {"version","bucket","source","architecture","directory","origin","status"})
                    if (old.contains(field)) item[field] = old.at(field);
                item["management"] = "managed";
                item["diagnostics"] = Json::array();
            } else if (recovery->second.value("action",std::string{}) == "install" && item.at("version").is_null()) {
                item["version"] = Json(nullptr);
                item["management"] = "none";
                item["status"] = "pending-recovery";
                item["diagnostics"] = Json::array();
            } else if (recovery->second.value("action",std::string{}) == "install") {
                // A later Scoop operation installed the same package while Coop's own install is
                // still pending. Report the installation that actually exists now and keep the
                // pending transaction visible instead of hiding either fact.
                item["last_operation"] = "pending-recovery";
                item["status"] = "pending-recovery";
                item["diagnostics"].push_back("A pending Coop install coexists with an installation readable from the shared layout");
            } else {
                // The current link can already be staged in the transaction while the last
                // committed management record is still in place. Report that record's version as
                // the installed fact instead of an intermediate null, and keep the fact reader's
                // diagnostic that explains the missing link.
                const auto live = context.root/L".coop"/L"packages"/(wide(item.at("name").get<std::string>())+L".json");
                if (fs::is_regular_file(live)) try {
                    const auto record = read_json(live);
                    if (record.is_object() && equal_name(record.value("name",std::string{}),item.at("name").get<std::string>())) {
                        if (item.at("version").is_null() && record.contains("version")) item["version"] = record.at("version");
                        for (const auto* field : {"bucket","architecture","directory","origin"})
                            if (!item.contains(field) && record.contains(field)) item[field] = record.at(field);
                        item["management"] = "managed";
                        item["status"] = record.value("status",std::string("ready"));
                    }
                } catch (const std::exception&) { /* The pending journal remains the authoritative diagnostic. */ }
            }
            item["recovery"] = recovery->second;
        }
    }
    for (const auto& [key,recovery] : recoveries) {
        if (listed.contains(key)) continue;
        result.push_back({{"name",recovery.value("package",std::string{})},{"version",Json(nullptr)},
            {"scope","user"},{"management","none"},{"status","pending-recovery"},
            {"diagnostics",Json::array()},{"last_operation","pending-recovery"},
            {"operation_action",recovery.value("action",std::string("unknown"))},{"recovery",recovery}});
    }
    std::sort(result.begin(), result.end(), [](const Json& a, const Json& b) {
        return a.at("name").get<std::string>() < b.at("name").get<std::string>();
    });
    return result;
}
static Json catalog_item(const Json& source, const Json& entry, const fs::path& directory) {
    const auto name = entry.at("name").get<std::string>();
    Json item = {{"name",name}, {"bucket",source.at("name")},
        {"path",path_text(directory/(wide(name)+L".json"))}, {"source",source.at("url")},
        {"synced_at",source.value("synced_at",Json(nullptr))},
        {"diagnostics",entry.value("diagnostics",Json::array())}};
    if (entry.contains("version")) item["version"] = entry.at("version");
    if (entry.contains("description")) item["description"] = entry.at("description");
    if (entry.contains("homepage")) item["homepage"] = entry.at("homepage");
    return item;
}
static void sort_catalog(Json& result) {
    std::sort(result.begin(), result.end(), [](const Json& a, const Json& b) {
        return a.at("bucket").get<std::string>()+"/"+a.at("name").get<std::string>() <
               b.at("bucket").get<std::string>()+"/"+b.at("name").get<std::string>();
    });
}
static std::string lowercase(std::string value) {
    for (auto& character : value) character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    return value;
}
// `search`/`info` only need the entries that match, so the published bucket metadata is filtered
// while it is read. Building and sorting the whole catalogue first made a single-package lookup
// cost as much as listing every package in the bucket.
static Json matching_catalog(const Context& context, const std::wstring& command, const std::string& needle) {
    Json result = Json::array();
    for (const auto& source : bucket_sources(context)) {
        if (source.value("kind",std::string{}) == "removed") continue;
        const fs::path location(wide(source.at("path").get<std::string>()));
        if (!fs::is_directory(location)) continue;
        const auto directory = fs::is_directory(location/L"bucket") ? location/L"bucket" : location;
        const auto bucket = source.at("name").get<std::string>();
        for (const auto& entry : catalog_entries(context,source)) {
            if (!entry.is_object() || !entry.contains("name") || !entry.at("name").is_string()) continue;
            const auto name = entry.at("name").get<std::string>();
            const auto qualified = bucket+"/"+name;
            const bool match = command == L"info" ? lowercase(name) == needle || lowercase(qualified) == needle :
                lowercase(qualified+" "+entry.value("description",std::string{})).find(needle) != std::string::npos;
            if (match) result.push_back(catalog_item(source,entry,directory));
        }
    }
    sort_catalog(result);
    return result;
}
std::vector<ir::CatalogueEntry> catalogue(const Context& context) {
    std::vector<ir::CatalogueEntry> result;
    for (const auto& source : bucket_sources(context)) {
        if (source.value("kind",std::string{}) == "removed") continue;
        const fs::path location(wide(source.at("path").get<std::string>()));
        if (!fs::is_directory(location)) continue;
        const auto directory = fs::is_directory(location/L"bucket") ? location/L"bucket" : location;
        const auto bucket = source.at("name").get<std::string>();
        for (const auto& entry : catalog_entries(context,source)) {
            if (!entry.is_object() || !entry.contains("name") || !entry.at("name").is_string()) continue;
            const auto name = entry.at("name").get<std::string>();
            result.push_back({name,bucket,directory/(wide(name)+L".json")});
        }
    }
    std::sort(result.begin(), result.end(), [](const ir::CatalogueEntry& a, const ir::CatalogueEntry& b) {
        return a.bucket+"/"+a.name < b.bucket+"/"+b.name;
    });
    return result;
}
// The architecture only selects the manifest variant for one package. Installed facts for the whole
// root are still read (each package's current manifest and install record), but the old-version
// inventories and repeated transaction-journal scans that `installed_packages` adds are not needed
// here. A missing current link can still be described by the last committed record of a pending
// transaction, which the full listing supplies.
static std::string installed_architecture(const Context& context, const std::string& name) {
    bool pending_fact = false;
    for (const auto& fact : ir::read_installations(context.root)) {
        if (!equal_name(fact.name,name)) continue;
        if (fact.present) return fact.architecture.empty() ? std::string("64bit") : fact.architecture;
        pending_fact = true;
        break;
    }
    if (pending_fact) {
        for (const auto& installed : installed_packages(context)) {
            if (installed.value("scope",std::string{}) == "global" ||
                !equal_name(installed.value("name",std::string{}),name)) continue;
            const auto value = installed.value("architecture",std::string{});
            if (!value.empty()) return value;
            break;
        }
    }
    return "64bit";
}
static Json validation_json(const Context& context, const Json& item) {
    // `info` reports the normalized IR and its layered diagnostics: a package that cannot currently be
    // executed still appears with the reason. The adapter and validator only read the manifest bytes.
    const auto architecture = installed_architecture(context,item.at("name").get<std::string>());
    Json validation = {{"architecture",architecture},{"manifest_digest",nullptr},
        {"artifacts",Json::array()},{"diagnostics",Json::array()},{"warnings",Json::array()},{"capabilities",Json::array()}};
    try {
        auto validated = ir::adapt_manifest(fs::path(wide(item.at("path").get<std::string>())),
            item.at("name").get<std::string>(),item.at("bucket").get<std::string>(),architecture);
        ir::validate(validated);
        validation["manifest_digest"] = validated.manifest_digest;
        validation["version"] = validated.version;
        validation["downloads"] = validated.downloads.size();
        if (validated.psmodule) validation["psmodule"] = {{"name",validated.psmodule->name}};
        for (const auto& download : validated.downloads)
            validation["artifacts"].push_back({{"url",download.url},{"filename",download.filename},
                {"renamed",download.renamed},{"algorithm",ir::digest_algorithm_name(download.digest.algorithm)},
                {"digest",download.digest.value},{"archive",ir::archive_format_name(download.format)}});
        for (const auto& diagnostic : validated.diagnostics)
            validation["diagnostics"].push_back({{"layer",ir::layer_name(diagnostic.layer)},{"code",diagnostic.code},{"message",diagnostic.message}});
        // Non-blocking source observations stay beside the diagnostics; `info` never hides them.
        for (const auto& warning : validated.warnings)
            validation["warnings"].push_back({{"layer",ir::layer_name(warning.layer)},{"code",warning.code},{"message",warning.message}});
        for (const auto& capability : validated.capabilities)
            validation["capabilities"].push_back({{"id",capability.id},{"supported",capability.supported},{"detail",capability.detail}});
    } catch (const std::exception& error) {
        validation["diagnostics"].push_back({{"layer","adapter"},{"code","manifest-unreadable"},{"message",error.what()}});
    }
    return validation;
}
int query(const Context& context, const std::wstring& command, const std::vector<std::wstring>& args) {
    Json result = Json::array();
    if (command == L"list") {
        if (!args.empty()) throw UsageError("list does not accept package arguments");
        result = installed_packages(context);
    } else {
        if (args.size() != 1) throw UsageError("search/info requires exactly one package or query");
        result = matching_catalog(context,command,lowercase(utf8(args[0])));
        if (command == L"info" && result.empty()) throw std::runtime_error("Package not found in local buckets");
        if (command == L"info" && result.size() > 1)
            throw std::runtime_error("Ambiguous package; qualify it with its bucket");
        if (command == L"info") for (auto& item : result) item["validation"] = validation_json(context,item);
    }
    if (context.json_output) std::cout << result.dump(2, ' ', false, Json::error_handler_t::replace) << '\n';
    else {
        std::cout << "Name\tVersion\tBucket\tManagement\tScope\tSource\tSynced\tStatus\tLast operation\n";
        for (const auto& item : result) {
            const auto display = [&item](const char* key) {
                return item.contains(key) && item.at(key).is_string() ? item.at(key).get<std::string>() : std::string("unknown");
            };
            std::cout << item.at("name").get<std::string>() << '\t'
                      << display("version") << '\t' << display("bucket") << '\t'
                      << display("management") << '\t' << display("scope") << '\t'
                      << display("source") << '\t' << display("synced_at") << '\t' << display("status") << '\t' << display("last_operation") << '\n';
            for (const auto& error : item.at("diagnostics")) std::cerr << "coop: " << error.get<std::string>() << '\n';
        }
    }
    return 0;
}
}
