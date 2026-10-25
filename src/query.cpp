#include "data.hpp"
#include "persist.hpp"
#include "versions.hpp"
#include <algorithm>
#include <iostream>
#include <stdexcept>
#include <cctype>
#include <map>

namespace coop {
static std::string lowercase(std::string value);
static std::vector<Persistence> listed_persistence(const Json& manifest) {
    std::vector<Persistence> result;
    if (!manifest.contains("persist") || manifest.at("persist").is_null()) return result;
    const auto add_single = [&](const Json& value) {
        const auto path = fs::path(wide(value.get<std::string>()));
        result.push_back({path,path});
    };
    const auto add_pair = [&](const Json& value) {
        const auto source = fs::path(wide(value.at(0).get<std::string>()));
        const auto target = value.size() == 2 ? fs::path(wide(value.at(1).get<std::string>())) : source;
        result.push_back({source,target});
    };
    const auto& persist = manifest.at("persist");
    if (persist.is_string()) add_single(persist);
    else if (persist.is_array()) for (const auto& entry : persist) {
        if (entry.is_string()) add_single(entry);
        else if (entry.is_array() && !entry.empty() && entry.size() <= 2 &&
                 std::all_of(entry.begin(),entry.end(),[](const Json& item) { return item.is_string(); })) add_pair(entry);
    }
    return result;
}
static void list_scope(Json& result, const Context& context, const fs::path& root, const std::string& scope) {
    const auto apps = root / L"apps";
    if (!fs::exists(apps)) return;
    for (const auto& app : fs::directory_iterator(apps)) {
        if (!app.is_directory() || app.path().filename() == L"scoop") continue;
        Json item = {{"name",path_text(app.path().filename())}, {"version",nullptr},
            {"scope",scope}, {"management","unadopted"}, {"diagnostics",Json::array()}};
        try {
            const auto current = app.path() / L"current";
            if (!fs::is_directory(current)) throw std::runtime_error("No usable current directory");
            const auto manifest = read_json(installed_record(current, L"manifest"));
            const auto install = read_json(installed_record(current, L"install"));
            if (!manifest.is_object() || !install.is_object()) throw std::runtime_error("Installation records must be objects");
            item["version"] = manifest.at("version").get<std::string>();
            item["bucket"] = install.value("bucket", std::string{});
            item["source"] = install.value("url", install.value("bucket",std::string("unknown")));
            item["synced_at"] = nullptr;
            item["architecture"] = install.value("architecture", std::string{});
            item["directory"] = path_text(fs::canonical(current));
            item["status"] = "installed";
            if (scope == "user") {
                Package listed;
                listed.name = item.at("name").get<std::string>();
                listed.persistence = listed_persistence(manifest);
                item["persistence"] = persistence_plan_json(context,listed,fs::canonical(current));
            }
            const auto managed = root/L".coop"/L"packages"/(app.path().filename().wstring()+L".json");
            if (scope == "user" && fs::exists(managed)) {
                const auto record = read_json(managed);
                item["management"] = "managed";
                item["status"] = record.value("status",std::string("unknown"));
                item["origin"] = record.value("origin",std::string("coop"));
                item["adoption_backup"] = record.value("adoption_backup",Json(nullptr));
            }
        } catch (const std::exception& error) {
            item["diagnostics"].push_back(error.what());
        }
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
            if (!operations.contains(name) || time > operations.at(name).first) operations[name] = {time,journal};
        } catch (const std::exception&) { /* A malformed journal does not hide queryable installations. */ }
    }
    for (auto& item : result) {
        if (item.at("scope") != "user") continue;
        const auto operation = operations.find(lowercase(item.at("name")));
        if (operation == operations.end()) { item["last_operation"] = "none"; continue; }
        const auto& journal = operation->second.second;
        const auto state = journal.value("state",std::string{});
        item["last_operation"] = state == "committed" ? "succeeded" : state == "rolled-back" ? "failed" : "pending-recovery";
        item["operation_action"] = journal.value("action",std::string("unknown"));
        if (state == "committed" && journal.value("action",std::string{}) == "uninstall" && !fs::is_directory(context.root/L"apps"/wide(item.at("name"))/L"current")) {
            item["status"] = "uninstalled"; item["management"] = "none"; item["diagnostics"] = Json::array();
        }
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
        for (const auto& file : fs::directory_iterator(directory)) {
            if (!file.is_regular_file() || file.path().extension() != L".json") continue;
            Json item = {{"name",path_text(file.path().stem())}, {"bucket",source.at("name")},
                {"path",path_text(file.path())}, {"source",source.at("url")}, {"synced_at",source.value("synced_at",Json(nullptr))},
                {"diagnostics",Json::array()}};
            try {
                const auto manifest = read_json(file.path());
                if (!manifest.is_object()) throw std::runtime_error("Manifest must be a JSON object");
                item["version"] = manifest.at("version").get<std::string>();
                item["description"] = manifest.value("description",std::string{});
                item["homepage"] = manifest.value("homepage",std::string{});
            } catch (const std::exception& error) {
                item["diagnostics"].push_back(error.what());
            }
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
