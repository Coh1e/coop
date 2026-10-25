#include "data.hpp"
#include <algorithm>
#include <iostream>
#include <stdexcept>
#include <cctype>

namespace coop {
static void list_scope(Json& result, const fs::path& root, const std::string& scope) {
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
        } catch (const std::exception& error) {
            item["diagnostics"].push_back(error.what());
        }
        result.push_back(std::move(item));
    }
}
Json installed_packages(const Context& context) {
    Json result = Json::array();
    list_scope(result, context.root, "user");
    if (context.global_root) list_scope(result, *context.global_root, "global");
    std::sort(result.begin(), result.end(), [](const Json& a, const Json& b) {
        return a.at("name").get<std::string>() < b.at("name").get<std::string>();
    });
    return result;
}
Json catalog(const Context& context) {
    Json result = Json::array();
    const auto buckets = context.root / L"buckets";
    if (!fs::exists(buckets)) return result;
    for (const auto& bucket : fs::directory_iterator(buckets)) {
        if (!bucket.is_directory()) continue;
        const auto directory = fs::is_directory(bucket.path()/L"bucket") ? bucket.path()/L"bucket" : bucket.path();
        for (const auto& file : fs::directory_iterator(directory)) {
            if (!file.is_regular_file() || file.path().extension() != L".json") continue;
            Json item = {{"name",path_text(file.path().stem())}, {"bucket",path_text(bucket.path().filename())},
                {"path",path_text(file.path())}, {"source",path_text(bucket.path())}, {"synced_at",nullptr},
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
        std::cout << "Name\tVersion\tBucket\tManagement\tScope\tSource\tSynced\n";
        for (const auto& item : result) {
            const auto display = [&item](const char* key) {
                return item.contains(key) && item.at(key).is_string() ? item.at(key).get<std::string>() : std::string("unknown");
            };
            std::cout << item.at("name").get<std::string>() << '\t'
                      << display("version") << '\t' << display("bucket") << '\t'
                      << display("management") << '\t' << display("scope") << '\t'
                      << display("source") << '\t' << display("synced_at") << '\n';
            for (const auto& error : item.at("diagnostics")) std::cerr << "coop: " << error.get<std::string>() << '\n';
        }
    }
    return 0;
}
}
