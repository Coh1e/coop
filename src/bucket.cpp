#include "catalog_index.hpp"
#include "git_bucket.hpp"
#include <windows.h>
#include <algorithm>
#include <cctype>
#include <iostream>
#include <stdexcept>

namespace coop {
namespace {
bool same_name(const Json& source, const std::string& name) {
    const auto existing = wide(source.at("name").get<std::string>());
    const auto requested = wide(name);
    return CompareStringOrdinal(existing.c_str(),-1,requested.c_str(),-1,TRUE) == CSTR_EQUAL;
}
void report_source(const Json& source) {
    Json output = source;
    output.erase("files");
    std::cout << output.dump(2) << '\n';
}
// The search index is a cache: a bucket stays published when it cannot be written, and an
// unchanged Git revision never rebuilds it. Queries then fall back to the snapshot files.
void refresh_index(const Context& context, const Json& source, bool force) {
    try {
        if (force || !catalog_index_valid(context,source)) write_catalog_index(context,source);
    } catch (const std::exception& error) {
        std::cerr << "coop: bucket " << source.value("name",std::string{}) << ": search index not updated: "
                  << error.what() << '\n';
    }
}
}
int bucket_command(const Context& context, const std::vector<std::wstring>& args) {
    if (args.empty()) throw std::runtime_error("bucket requires list/add/remove/update");
    const auto registry_path = context.root/L".coop"/L"buckets.json";
    if (args[0] == L"list") {
        if (args.size() != 1) throw std::runtime_error("bucket list accepts no arguments");
        Json result = Json::array();
        for (auto source : bucket_sources(context)) {
            if (source.value("kind",std::string{}) == "removed") continue;
            source.erase("files");
            result.push_back(std::move(source));
        }
        std::cout << result.dump(2) << '\n';
        return 0;
    }
    if (args[0] != L"add" && args[0] != L"remove" && args[0] != L"update")
        throw std::runtime_error("Unknown bucket operation");
    if (args[0] == L"add" && args.size() < 3) throw std::runtime_error("bucket add requires name and source");
    if (args[0] == L"remove" && args.size() != 2) throw std::runtime_error("bucket remove requires one name");
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
        if (found != registry.end() && found->value("kind",std::string{}) != "removed") throw std::runtime_error("Bucket already registered");
        const auto source_text = utf8(args[2]);
        const fs::path source(args[2]);
        Json record;
        std::error_code path_error;
        if (fs::is_directory(source,path_error)) {
            if (!branch.empty() || !revision.empty()) throw std::runtime_error("Branch/revision applies to a Git URL, not a plain local bucket");
            record = {{"name",name},{"kind","local"},{"path",path_text(fs::canonical(source))},
                {"url",path_text(source)},{"synced_at",nullptr}};
        } else record = prepare_git_bucket(context,name,source_text,branch,revision,nullptr);
        if (found == registry.end()) registry.push_back(record);
        else *found = record;
        write_json(registry_path,registry);
        refresh_index(context,record,false);
        report_source(record);
        return 0;
    }
    if (args[0] == L"remove") {
        if (found == registry.end() || found->value("kind",std::string{}) == "removed") throw std::runtime_error("Bucket is not registered");
        (*found)["kind"] = "removed";
        write_json(registry_path,registry);
        std::cout << "Removed bucket registration " << name << "; source files retained\n";
        return 0;
    }
    if (!name.empty() && found == registry.end()) throw std::runtime_error("Bucket is not registered");
    bool failed = false;
    for (std::size_t index = 0; index < registry.size(); ++index) {
        auto& source = registry.at(index);
        if ((!name.empty() && !same_name(source,name)) || source.value("kind",std::string{}) == "removed") continue;
        try {
            const auto kind = source.value("kind",std::string{});
            if (kind == "local" || (kind == "unmanaged" && !fs::exists(fs::path(wide(source.at("path").get<std::string>()))/L".git"))) {
                refresh_index(context,source,false);
                report_source(source);
                continue;
            }
            auto previous = kind == "unmanaged" ? inspect_scoop_bucket(context,source.at("name").get<std::string>()) : source;
            auto updated = prepare_git_bucket(context,previous.at("name").get<std::string>(),previous.at("url").get<std::string>(),
                previous.value("branch",std::string{}),previous.value("fixed_revision",std::string{}),&previous);
            Json candidate = registry;
            candidate.at(index) = updated;
            write_json(registry_path,candidate);
            source = std::move(updated);
            refresh_index(context,source,source.value("changed",true));
            report_source(source);
        } catch (const std::exception& error) {
            failed = true;
            std::cerr << "coop: bucket " << source.at("name").get<std::string>() << ": " << error.what() << '\n';
        }
    }
    return failed ? 1 : 0;
}
}
