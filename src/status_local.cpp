#include "status_local.hpp"
#include "catalog_index.hpp"
#include "package.hpp"
#include <algorithm>
#include <cctype>
#include <map>
#include <memory>
#include <set>
#include <git2.h>

namespace coop {
namespace {
std::string key(std::string text) {
    for (auto& character : text) character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    return text;
}
void failure(ResultItem& item, const std::string& code, const std::string& message) {
    item.state = ResultState::failed;
    item.reason = "local-data-invalid";
    item.data["local_state"] = std::string("failed");
    item.diagnostics.push_back({code,message});
}
// Unlike the write-side Git session, a metadata read must not create isolated config directories.
ResultData git_facts(const fs::path& path) {
    ResultData facts = {{"revision",nullptr},{"branch",nullptr}};
    if (!fs::exists(path/L".git")) return facts;
    struct Session {
        Session() { if (git_libgit2_init() < 0) throw std::runtime_error("Cannot initialize local Git reader"); }
        ~Session() { git_libgit2_shutdown(); }
    } session;
    git_repository* raw = nullptr;
    if (git_repository_open_ext(&raw,path_text(path).c_str(),GIT_REPOSITORY_OPEN_NO_SEARCH,nullptr) < 0)
        throw std::runtime_error("Cannot read local Git repository");
    const std::unique_ptr<git_repository,decltype(&git_repository_free)> repository(raw,git_repository_free);
    git_reference* raw_head = nullptr;
    const auto result = git_repository_head(&raw_head,repository.get());
    if (result == GIT_EUNBORNBRANCH) return facts;
    if (result < 0) throw std::runtime_error("Cannot read local Git HEAD");
    const std::unique_ptr<git_reference,decltype(&git_reference_free)> head(raw_head,git_reference_free);
    if (const auto* oid = git_reference_target(head.get())) facts["revision"] = std::string(git_oid_tostr_s(oid));
    if (git_reference_is_branch(head.get())) facts["branch"] = std::string(git_reference_shorthand(head.get()));
    return facts;
}
std::vector<Json> sources(const Context& context, OperationResult& report) {
    std::vector<Json> result;
    std::set<std::string> removed;
    try {
        const auto state = state_directory(context);
        if (fs::exists(state) && !fs::is_directory(state)) throw std::runtime_error("Private state path is not a directory");
        auto registry = state/L"buckets.json";
        if (!fs::exists(registry)) registry = context.root/L".coop"/L"buckets.json";
        if (fs::exists(registry)) {
            const auto records = read_json(registry);
            if (!records.is_array()) throw std::runtime_error("Bucket registry must be an array");
            for (const auto& source : records) {
                try {
                    if (!source.is_object() || !source.contains("name") || !source.at("name").is_string() ||
                        source.at("name").get<std::string>().empty()) throw std::runtime_error("Invalid bucket registry entry");
                    if (source.value("kind",std::string{}) == "removed") { removed.insert(key(source.at("name").get<std::string>())); continue; }
                    if (!source.contains("path") || !source.at("path").is_string()) throw std::runtime_error("Bucket path must be a string");
                    result.push_back(source);
                } catch (const std::exception& error) { report.diagnostics.push_back({"bucket-registry-entry-invalid",error.what()}); }
            }
        }
    } catch (const std::exception& error) { report.diagnostics.push_back({"bucket-registry-unreadable",error.what()}); }
    // Shared directories remain visible even if optional private registry data cannot be read.
    try {
        const auto directory = context.root/L"buckets";
        if (fs::exists(directory)) for (const auto& entry : fs::directory_iterator(directory)) {
            if (!entry.is_directory()) continue;
            const auto name = path_text(entry.path().filename());
            if (removed.contains(key(name))) continue;
            if (std::none_of(result.begin(),result.end(),[&](const auto& source) { return key(source.at("name").template get<std::string>()) == key(name); }))
                result.push_back({{"name",name},{"path",path_text(entry.path())},{"kind","unmanaged"}});
        }
    } catch (const std::exception& error) { report.diagnostics.push_back({"bucket-directory-unreadable",error.what()}); }
    std::sort(result.begin(),result.end(),[](const auto& a,const auto& b) { return a.at("name").template get<std::string>() < b.at("name").template get<std::string>(); });
    return result;
}
struct LocalFact { ir::InstalledFact fact; std::string scope; };
}
OperationResult local_status_report(const Context& context) {
    OperationResult report;
    report.request.local_only = true;
    ResultItem coop;
    coop.name = "coop"; coop.scope = "process"; coop.reason = "local-only";
    coop.data = {{"running_version",std::string(COOP_VERSION)},{"installed",false},{"installed_version",nullptr},{"local_state",std::string("ok")}};
    report.clients.push_back(std::move(coop));
    ResultItem scoop;
    scoop.name = "scoop"; scoop.scope = "user"; scoop.state = ResultState::not_applicable; scoop.reason = "not-installed";
    scoop.data = {{"installed",false},{"revision",nullptr},{"branch",nullptr},{"local_state",std::string("absent")}};
    try {
        const auto app = context.root/L"apps"/L"scoop";
        if (fs::exists(app)) {
            const auto current = app/L"current";
            if (!fs::is_directory(current)) throw std::runtime_error("Scoop has no usable current directory");
            for (const auto& [name,value] : git_facts(current)) scoop.data[name] = value;
            scoop.data["installed"] = true; scoop.data["local_state"] = std::string("ok");
            scoop.state = ResultState::not_checked; scoop.reason = "local-only";
        }
    } catch (const std::exception& error) { scoop.data["installed"] = nullptr; failure(scoop,"scoop-local-unreadable",error.what()); }
    report.clients.push_back(std::move(scoop));

    std::map<std::string,std::map<std::string,fs::path>> manifests;
    std::set<std::string> deprecated;
    std::set<std::string> unreadable_sources;
    for (const auto& source : sources(context,report)) {
        ResultItem bucket;
        bucket.name = source.at("name").get<std::string>(); bucket.scope = "user"; bucket.reason = "local-only";
        bucket.data = {{"path",source.at("path").get<std::string>()},{"kind",source.value("kind",std::string("local"))},
            {"local_state",std::string("ok")},{"revision",nullptr},{"branch",nullptr},{"manifest_count",std::size_t{0}}};
        try {
            const fs::path path(wide(source.at("path").get<std::string>()));
            if (!fs::is_directory(path)) throw std::runtime_error("Bucket directory is missing");
            for (const auto& [name,value] : git_facts(path)) bucket.data[name] = value;
            const auto directory = fs::is_directory(path/L"bucket") ? path/L"bucket" : path;
            const auto entries = scan_catalog_entries(source);
            bucket.data["manifest_count"] = entries.size();
            for (const auto& entry : entries) {
                const auto name = entry.at("name").get<std::string>();
                manifests[key(bucket.name)][key(name)] = directory/(wide(name)+L".json");
                for (const auto& diagnostic : entry.value("diagnostics",Json::array()))
                    failure(bucket,"bucket-manifest-invalid",name+": "+(diagnostic.is_string() ? diagnostic.get<std::string>() : diagnostic.dump()));
            }
            if (fs::is_directory(path/L"deprecated")) for (const auto& entry : fs::recursive_directory_iterator(path/L"deprecated"))
                if (entry.is_regular_file() && entry.path().extension() == L".json") deprecated.insert(key(path_text(entry.path().stem())));
        } catch (const std::exception& error) {
            unreadable_sources.insert(key(bucket.name));
            failure(bucket,"bucket-local-unreadable",error.what());
        }
        report.buckets.push_back(std::move(bucket));
    }
    std::vector<LocalFact> installed;
    const auto add_scope = [&](const fs::path& root,const std::string& scope) {
        try { for (auto& fact : ir::read_installations(root)) installed.push_back({std::move(fact),scope}); }
        catch (const std::exception& error) { report.diagnostics.push_back({"installation-scope-unreadable",scope+": "+error.what()}); }
    };
    add_scope(context.root,"user");
    if (context.global_root) add_scope(*context.global_root,"global");
    std::set<std::string> present;
    for (const auto& local : installed) if (local.fact.present) present.insert(key(local.fact.name));
    for (const auto& local : installed) {
        const auto& fact = local.fact;
        if (key(fact.name) == "scoop" && local.scope == "user") continue;
        ResultItem item;
        item.name = fact.name; item.scope = local.scope; item.state = ResultState::ok; item.reason = "local-facts-consistent";
        item.data = {{"installed_version",fact.present ? ResultValue(fact.version) : ResultValue(nullptr)},
            {"bucket",fact.bucket},{"read_only",local.scope == "global"},{"manifest_version",nullptr},
            {"version_differs",false},{"missing_dependencies",std::vector<std::string>{}},{"held",false},
            {"deprecated",deprecated.contains(key(fact.name))},{"manifest_removed",false},{"local_state",std::string("ok")}};
        for (const auto& diagnostic : fact.diagnostics) failure(item,diagnostic.code,diagnostic.message);
        if (fact.present && fact.version.empty()) failure(item,"installed-version-empty","Installed manifest version is empty");
        if (key(fact.name) == "coop" && local.scope == "user") {
            auto& client = report.clients.front();
            client.data["installed"] = fact.present ? ResultValue(true) : ResultValue(nullptr);
            client.data["installed_version"] = item.data.at("installed_version");
            client.data["bucket"] = fact.bucket;
            for (const auto& diagnostic : item.diagnostics) failure(client,diagnostic.code,diagnostic.message);
            continue;
        }
        try {
            if (fact.present) item.data["held"] = package_is_held(fact.directory);
            fs::path candidate;
            const auto find = [&](const auto& entries) { const auto found = entries.find(key(fact.name)); if (found != entries.end()) candidate = found->second; };
            if (!fact.bucket.empty()) { const auto found = manifests.find(key(fact.bucket)); if (found != manifests.end()) find(found->second); }
            else for (const auto& [name,entries] : manifests) { (void)name; find(entries); if (!candidate.empty()) break; }
            if (candidate.empty()) {
                if ((!fact.bucket.empty() && unreadable_sources.contains(key(fact.bucket))) ||
                    (fact.bucket.empty() && !unreadable_sources.empty()))
                    failure(item,"app-source-unreadable","Cannot determine manifest availability because a source could not be inspected");
                else item.data["manifest_removed"] = true;
            }
            else {
                const auto manifest = read_json(candidate);
                const auto version = manifest.at("version").get<std::string>();
                if (version.empty()) throw std::runtime_error("Manifest version is empty");
                item.data["manifest_version"] = version;
                item.data["version_differs"] = fact.present && version != fact.version;
                if (fact.present && item.state != ResultState::failed) {
                    const auto decision = decide_update(fact.version,version,
                        sha256_file(candidate) != sha256_file(installed_record(fact.directory,L"manifest")),
                        std::get<bool>(item.data.at("held")));
                    item.data["update_state"] = std::string(update_state_name(decision.state));
                    item.data["update_available"] = decision.changes_installation;
                    item.data["update_blocked"] = decision.blocked;
                    if (decision.state != UpdateState::current) {
                        item.state = ResultState::attention;
                        item.reason = update_state_name(decision.state);
                    }
                }
                if (manifest.contains("depends")) {
                    auto dependencies = manifest.at("depends");
                    if (dependencies.is_string()) dependencies = Json::array({dependencies});
                    if (!dependencies.is_array()) throw std::runtime_error("Manifest depends must be a string or array");
                    for (const auto& entry : dependencies) {
                        auto dependency = entry.get<std::string>();
                        if (const auto at = dependency.find('@'); at != std::string::npos) dependency.resize(at);
                        if (const auto slash = dependency.find('/'); slash != std::string::npos) dependency.erase(0,slash+1);
                        if (!present.contains(key(dependency))) std::get<std::vector<std::string>>(item.data["missing_dependencies"]).push_back(dependency);
                    }
                }
            }
            if (item.state != ResultState::failed && (std::get<bool>(item.data.at("version_differs")) ||
                std::get<bool>(item.data.at("manifest_removed")) || std::get<bool>(item.data.at("deprecated")) ||
                !std::get<std::vector<std::string>>(item.data.at("missing_dependencies")).empty())) { item.state = ResultState::attention; item.reason = "local-issues"; }
        } catch (const std::exception& error) { failure(item,"app-local-unreadable",error.what()); }
        report.apps.push_back(std::move(item));
    }
    ResultItem stage;
    stage.name = "local-inspection"; stage.scope = "local";
    stage.state = operation_result_exit_code(report) == 0 ? ResultState::ok : ResultState::failed;
    stage.reason = stage.state == ResultState::ok ? "local-facts-read" : "local-inspection-incomplete";
    report.stages.push_back(std::move(stage));
    return report;
}
}
