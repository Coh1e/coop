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
static void list_scope(Json& result, const Context& context, const fs::path& root, const std::string& scope) {
    // Installation facts come from the shared Scoop layout through the IR adapter. Coop's private
    // records are optional management metadata read separately below, so they can never decide
    // whether an installed package is visible or block a query when they are missing or stale.
    for (const auto& fact : ir::read_installations(root, scope)) {
        Json item = {{"name",fact.name}, {"version",fact.present ? Json(fact.version) : Json(nullptr)},
            {"scope",scope}, {"management","unadopted"}, {"diagnostics",Json::array()}};
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
            if (scope == "user") {
                Package listed;
                listed.name = fact.name;
                for (const auto& mapping : fact.persistence)
                    listed.persistence.push_back({fs::path(wide(mapping.source)),fs::path(wide(mapping.target))});
                item["persistence"] = persistence_plan_json(context,listed,fact.directory);
            }
        }
        if (scope == "user") {
            const auto managed = root/L".coop"/L"packages"/(wide(fact.name)+L".json");
            if (fs::exists(managed)) try {
                const auto record = read_json(managed);
                item["management"] = "managed";
                item["status"] = record.value("status",std::string("unknown"));
                item["origin"] = record.value("origin",std::string("coop"));
                item["adoption_backup"] = record.value("adoption_backup",Json(nullptr));
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
            item["old_versions"] = version_cleanup_inventory(context,item.at("name").get<std::string>(),current_version);
        }
        result.push_back(std::move(item));
    }
}
Json installed_packages(const Context& context) {
    Json result = Json::array();
    list_scope(result,context,context.root, "user");
    if (context.global_root) list_scope(result,context,*context.global_root, "global");
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
    for (const auto& entry : pending_recovery_report(context,false))
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
            } else if (recovery->second.value("action",std::string{}) == "install") {
                item["version"] = Json(nullptr);
                item["management"] = "none";
                item["status"] = "pending-recovery";
                item["diagnostics"] = Json::array();
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
Json catalog(const Context& context) {
    Json result = Json::array();
    for (const auto& source : bucket_sources(context)) {
        if (source.value("kind",std::string{}) == "removed") continue;
        const fs::path location(wide(source.at("path").get<std::string>()));
        if (!fs::is_directory(location)) continue;
        const auto directory = fs::is_directory(location/L"bucket") ? location/L"bucket" : location;
        for (const auto& entry : catalog_entries(context,source)) {
            const auto name = entry.at("name").get<std::string>();
            Json item = {{"name",name}, {"bucket",source.at("name")},
                {"path",path_text(directory/(wide(name)+L".json"))}, {"source",source.at("url")},
                {"synced_at",source.value("synced_at",Json(nullptr))},
                {"diagnostics",entry.value("diagnostics",Json::array())}};
            if (entry.contains("version")) item["version"] = entry.at("version");
            if (entry.contains("description")) item["description"] = entry.at("description");
            if (entry.contains("homepage")) item["homepage"] = entry.at("homepage");
            result.push_back(std::move(item));
        }
    }
    std::sort(result.begin(), result.end(), [](const Json& a, const Json& b) {
        return a.at("bucket").get<std::string>()+"/"+a.at("name").get<std::string>() <
               b.at("bucket").get<std::string>()+"/"+b.at("name").get<std::string>();
    });
    return result;
}
static std::string lowercase(std::string value) {
    for (auto& character : value) character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    return value;
}
// `info` reports the normalized IR and its layered diagnostics: a package that cannot currently be
// executed still appears with the reason. The adapter and validator only read the manifest bytes.
static Json validation_json(const Json& item) {
    Json validation = {{"architecture","64bit"},{"manifest_digest",nullptr},
        {"diagnostics",Json::array()},{"capabilities",Json::array()}};
    try {
        auto validated = ir::adapt_manifest(fs::path(wide(item.at("path").get<std::string>())),
            item.at("name").get<std::string>(),item.at("bucket").get<std::string>(),"64bit");
        ir::validate(validated);
        validation["manifest_digest"] = validated.manifest_digest;
        validation["version"] = validated.version;
        validation["downloads"] = validated.downloads.size();
        for (const auto& diagnostic : validated.diagnostics)
            validation["diagnostics"].push_back({{"layer",ir::layer_name(diagnostic.layer)},{"code",diagnostic.code},{"message",diagnostic.message}});
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
        if (!args.empty()) throw std::runtime_error("list does not accept package arguments");
        result = installed_packages(context);
    } else {
        if (args.size() != 1) throw std::runtime_error("search/info requires exactly one package or query");
        const auto needle = lowercase(utf8(args[0]));
        for (const auto& item : catalog(context)) {
            const auto name = item.at("name").get<std::string>();
            const auto qualified = item.at("bucket").get<std::string>()+"/"+name;
            const bool match = command == L"info" ? lowercase(name) == needle || lowercase(qualified) == needle :
                lowercase(qualified+" "+item.value("description",std::string{})).find(needle) != std::string::npos;
            if (match) result.push_back(item);
        }
        if (command == L"info" && result.empty()) throw std::runtime_error("Package not found in local buckets");
        if (command == L"info" && result.size() > 1)
            throw std::runtime_error("Ambiguous package; qualify it with its bucket");
        if (command == L"info") for (auto& item : result) item["validation"] = validation_json(item);
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
