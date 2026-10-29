#include "catalog_index.hpp"
#include "git_bucket.hpp"
#include <windows.h>
#include <algorithm>
#include <cctype>
#include <fstream>
#include <iostream>
#include <stdexcept>

namespace coop {
namespace {
bool same_name(const Json& source, const std::string& name) {
    const auto existing = wide(source.at("name").get<std::string>());
    const auto requested = wide(name);
    return CompareStringOrdinal(existing.c_str(),-1,requested.c_str(),-1,TRUE) == CSTR_EQUAL;
}
std::string normalized_source(std::string value) {
    while (!value.empty() && (value.back() == '/' || value.back() == '\\')) value.pop_back();
    if (value.size() >= 4 && value.substr(value.size()-4) == ".git") value.resize(value.size()-4);
    for (auto& character : value) character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    std::replace(value.begin(),value.end(),'\\','/');
    return value;
}
bool same_source(const std::string& left, const std::string& right) {
    return normalized_source(left) == normalized_source(right);
}
fs::path refresh_journal_path(const Context& context, const std::string& name) {
    return context.root/L".coop"/L"bucket-refresh"/(wide(name)+L".json");
}
void report_source(const Json& source) {
    Json output = source;
    output.erase("files");
    std::cout << output.dump(2) << '\n';
}
// A refresh journal marks a Git shared-bucket operation while it is in progress. If the process
// is terminated, the next refresh can overwrite it; the shared working tree and the previously
// published registry record remain available to queries.
class RefreshJournal {
public:
    RefreshJournal(const Context& context, const std::string& name) : path_(refresh_journal_path(context,name)) {
        write_json(path_,{{"name",name},{"action","refresh"},{"layout","shared-worktree"}});
    }
    ~RefreshJournal() {
        std::error_code ignored;
        fs::remove(path_,ignored);
    }
    RefreshJournal(const RefreshJournal&) = delete;
    RefreshJournal& operator=(const RefreshJournal&) = delete;
private:
    fs::path path_;
};
// The search index is a cache: a bucket stays published when it cannot be written, and an
// unchanged Git revision never rebuilds it. Queries then fall back to the shared bucket files.
void refresh_index(const Context& context, const Json& source, bool force) {
    try {
        if (force || !catalog_index_valid(context,source)) write_catalog_index(context,source);
    } catch (const std::exception& error) {
        std::cerr << "coop: bucket " << source.value("name",std::string{}) << ": search index not updated: "
                  << error.what() << '\n';
    }
}
}
int bucket_command(const Context& context, const std::vector<std::wstring>& args, bool quiet_report) {
    if (args.empty()) throw std::runtime_error("bucket requires list/add/remove/update");
    const auto registry_path = context.root/L".coop"/L"buckets.json";
    if (args[0] == L"list") {
        if (args.size() != 1) throw std::runtime_error("bucket list accepts no arguments");
        Json result = Json::array();
        for (auto source : bucket_sources(context)) {
            if (source.value("kind",std::string{}) == "removed") continue;
            const auto journal = refresh_journal_path(context,source.at("name").get<std::string>());
            if (fs::exists(journal)) {
                source["refresh_pending"] = true;
                source["refresh_journal"] = path_text(journal);
            }
            source.erase("files");
            result.push_back(std::move(source));
        }
        std::cout << result.dump(2) << '\n';
        return 0;
    }
    if (args[0] == L"known") {
        if (args.size() != 1) throw std::runtime_error("bucket known accepts no arguments");
        // Scoop ships this list inside its own installation. When the shared root contains Scoop,
        // read that copy so the answer tracks the installed revision; otherwise use the snapshot of
        // Scoop 0.6.0's `buckets.json` below.
        std::error_code error;
        const auto shipped = context.root/L"apps"/L"scoop"/L"current"/L"buckets.json";
        if (fs::is_regular_file(shipped,error)) try {
            // Scoop prints these in declaration order, so the read keeps the file's order instead of
            // the sorted order a plain object would give.
            std::ifstream stream(shipped,std::ios::binary);
            const auto known = nlohmann::ordered_json::parse(stream);
            if (known.is_object()) {
                for (const auto& [bucket,url] : known.items()) std::cout << bucket << '\n';
                return 0;
            }
        } catch (const std::exception&) { /* Fall through to the snapshot. */ }
        for (const auto* bucket : {"main","extras","versions","nirsoft","sysinternals","php","nerd-fonts","nonportable","java","games"})
            std::cout << bucket << '\n';
        return 0;
    }
    // `rm` is Scoop's documented spelling; `remove` stays as the original Coop form.
    const bool remove = args[0] == L"remove" || args[0] == L"rm";
    if (args[0] != L"add" && !remove && args[0] != L"update")
        throw std::runtime_error("Unknown bucket operation");
    if (args[0] == L"add" && args.size() < 3) throw std::runtime_error("bucket add requires name and source");
    if (remove && args.size() != 2) throw std::runtime_error("bucket rm requires one name");
    if (args[0] == L"update" && args.size() > 2) throw std::runtime_error("bucket update accepts at most one name");
    std::string name = args.size() > 1 ? utf8(args[1]) : std::string{};
    if (!name.empty()) validate_component(name);
    std::string branch,revision;
    if (args[0] == L"add") for (std::size_t i = 3; i < args.size(); i += 2) {
        if (i+1 == args.size()) throw std::runtime_error("Bucket option requires a value");
        if (args[i] == L"--branch") branch = utf8(args[i+1]);
        else if (args[i] == L"--revision") revision = utf8(args[i+1]);
        else throw std::runtime_error("Unknown bucket option");
    }
    if (!revision.empty() && (revision.size() != 40 || !std::all_of(revision.begin(),revision.end(),[](unsigned char c) { return std::isxdigit(c) != 0; })))
        throw std::runtime_error("A fixed revision must be a full commit id");
    RootLock lock(context.root);
    auto registry = bucket_sources(context);
    auto found = std::find_if(registry.begin(),registry.end(),[&](const Json& source) { return same_name(source,name); });
    if (args[0] == L"add") {
        if (found != registry.end() && found->value("kind",std::string{}) != "removed") {
            if (found->value("kind",std::string{}) == "unmanaged")
                throw std::runtime_error("A shared bucket directory with this name already exists; use bucket update to adopt it");
            throw std::runtime_error("Bucket already registered");
        }
        const auto source_text = utf8(args[2]);
        const fs::path source(args[2]);
        Json record;
        std::error_code path_error;
        if (fs::is_directory(source,path_error)) {
            if (!branch.empty() || !revision.empty()) throw std::runtime_error("Branch/revision applies to a Git URL, not a plain local bucket");
            record = {{"name",name},{"kind","local"},{"path",path_text(operating_path(fs::canonical(source)))},
                {"url",path_text(operating_path(fs::absolute(source)))},{"synced_at",nullptr}};
        } else {
            const auto shared = context.root/L"buckets"/wide(name);
            const bool reregister = found != registry.end() && found->value("kind",std::string{}) == "removed" &&
                fs::exists(shared/L".git");
            if (reregister) {
                // A removed registration keeps the shared working tree. Re-registering only adopts
                // that exact repository; it does not fetch or move HEAD, so local commits and
                // offline use remain intact. A later `bucket update` applies the refresh rules.
                record = inspect_scoop_bucket(context,name);
                if (!same_source(record.at("url").get<std::string>(),source_text))
                    throw std::runtime_error("Existing shared bucket source differs from the requested source: "+
                        record.at("url").get<std::string>());
                if (!branch.empty() && branch != record.value("branch",std::string{}))
                    throw std::runtime_error("Existing shared bucket uses a different branch: "+record.value("branch",std::string{}));
                if (!revision.empty() && revision != found->value("fixed_revision",std::string{}))
                    throw std::runtime_error("Existing shared bucket uses a different fixed revision");
                record["fixed_revision"] = found->value("fixed_revision",std::string{});
                // Re-registration takes over a worktree that already exists on disk.
                record["adopted"] = true;
                record["refresh_kind"] = "unchanged";
                record["changed"] = false;
                record["first_refresh"] = false;
                record["registered"] = true;
                record["synced_at"] = nullptr;
            } else record = prepare_git_bucket(context,name,source_text,branch,revision,nullptr);
        }
        if (found == registry.end()) registry.push_back(record);
        else *found = record;
        write_json(registry_path,registry);
        refresh_index(context,record,false);
        if (!quiet_report) report_source(record);
        return 0;
    }
    if (remove) {
        if (found == registry.end() || found->value("kind",std::string{}) == "removed") throw std::runtime_error("Bucket is not registered");
        (*found)["kind"] = "removed";
        write_json(registry_path,registry);
        std::cout << "Removed bucket registration " << name << "; source files retained\n";
        return 0;
    }
    if (!name.empty() && found == registry.end()) throw std::runtime_error("Bucket is not registered");
    if (!name.empty() && found != registry.end() && found->value("kind",std::string{}) == "removed")
        throw std::runtime_error("Bucket registration was removed; use bucket add "+name+" <source> to re-register the shared bucket");
    bool failed = false;
    for (std::size_t index = 0; index < registry.size(); ++index) {
        auto& source = registry.at(index);
        if ((!name.empty() && !same_name(source,name)) || source.value("kind",std::string{}) == "removed") continue;
        try {
            const auto kind = source.value("kind",std::string{});
            if (kind == "local" || (kind == "unmanaged" && !fs::exists(fs::path(wide(source.at("path").get<std::string>()))/L".git"))) {
                refresh_index(context,source,false);
                if (!quiet_report) report_source(source);
                continue;
            }
            const auto bucket_name = source.at("name").get<std::string>();
            RefreshJournal journal(context,bucket_name);
            auto previous = kind == "unmanaged" ? inspect_scoop_bucket(context,bucket_name) : source;
            // Keep the fact that this shared bucket was adopted by this refresh; the inspector
            // itself reports the repository layout, not the registry origin.
            if (kind == "unmanaged") previous["kind"] = "unmanaged";
            auto updated = prepare_git_bucket(context,bucket_name,previous.at("url").get<std::string>(),
                previous.value("branch",std::string{}),previous.value("fixed_revision",std::string{}),&previous);
            // Update the in-memory registry before committing it so an update-all cannot roll a
            // previously refreshed source back to its old record.
            source = std::move(updated);
            write_json(registry_path,registry);
            refresh_index(context,source,source.value("changed",true));
            if (!quiet_report) report_source(source);
        } catch (const std::exception& error) {
            failed = true;
            std::cerr << "coop: bucket " << source.at("name").get<std::string>() << ": " << error.what() << '\n';
        }
    }
    return failed ? 1 : 0;
}
}
