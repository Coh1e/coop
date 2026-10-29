#include "app.hpp"
#include "native.hpp"
#include "package.hpp"
#include "progress.hpp"
#include <algorithm>
#include <cctype>
#include <iostream>
#include <vector>

namespace coop {
namespace {
std::string lowercase_text(std::string value) {
    for (auto& character : value) character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    return value;
}
struct CacheEntry {
    std::string filename;
    std::string app;
    std::string version;
    std::uintmax_t size = 0;
};
// A cache file is `<app>#<version>#<sha256(url)[0..7]><extension>`; a file without both markers was
// written by an older Coop and cannot be attributed to a package.
bool is_attributed(const std::string& name) {
    const auto first = name.find('#');
    return first != std::string::npos && name.find('#',first+1) != std::string::npos;
}
std::vector<CacheEntry> cache_entries(const Context& context) {
    std::vector<CacheEntry> entries;
    std::error_code error;
    const auto directory = context.root/L"cache";
    if (!fs::is_directory(directory,error)) return entries;
    for (const auto& item : fs::directory_iterator(directory,error)) {
        if (error) break;
        std::error_code type_error;
        if (!item.is_regular_file(type_error)) continue;
        CacheEntry entry;
        entry.filename = utf8(item.path().filename().wstring());
        const auto first = entry.filename.find('#');
        const auto second = first == std::string::npos ? std::string::npos : entry.filename.find('#',first+1);
        entry.app = first == std::string::npos ? entry.filename : entry.filename.substr(0,first);
        entry.version = first == std::string::npos || second == std::string::npos ? std::string{} :
            entry.filename.substr(first+1,second-first-1);
        std::error_code size_error;
        entry.size = item.file_size(size_error);
        entries.push_back(std::move(entry));
    }
    std::sort(entries.begin(),entries.end(),[](const CacheEntry& a,const CacheEntry& b) {
        return a.filename < b.filename;
    });
    return entries;
}
std::uintmax_t total_size(const std::vector<CacheEntry>& entries) {
    std::uintmax_t total = 0;
    for (const auto& entry : entries) total += entry.size;
    return total;
}
std::string plural(std::size_t count,const char* one,const char* many) {
    return std::to_string(count)+" "+(count == 1 ? one : many);
}
int cache_show(const Context& context,const std::vector<std::string>& apps) {
    std::vector<CacheEntry> selected;
    for (const auto& entry : cache_entries(context)) {
        if (!is_attributed(entry.filename)) continue;
        if (apps.empty()) { selected.push_back(entry); continue; }
        for (const auto& app : apps)
            if (lowercase_text(entry.app) == lowercase_text(app)) { selected.push_back(entry); break; }
    }
    if (context.json_output) {
        Json output = Json::array();
        for (const auto& entry : selected)
            output.push_back({{"name",entry.app},{"version",entry.version},{"length",entry.size},
                {"file",entry.filename}});
        std::cout << output.dump(2,' ',false,Json::error_handler_t::replace) << '\n';
        return 0;
    }
    std::vector<std::vector<std::string>> rows;
    for (const auto& entry : selected)
        rows.push_back({entry.app,entry.version,std::to_string(entry.size)});
    if (!rows.empty()) print_table({"Name","Version","Length"},rows);
    std::cout << "Total: " << plural(selected.size(),"file","files") << ", "
              << human_bytes(total_size(selected)) << '\n';
    return 0;
}
int cache_remove(const Context& context,const std::vector<std::string>& apps,bool all) {
    std::vector<CacheEntry> selected;
    for (const auto& entry : cache_entries(context)) {
        if (!all && !is_attributed(entry.filename)) continue;
        if (apps.empty() && !all) continue;
        if (!all) {
            bool match = false;
            for (const auto& app : apps)
                if (lowercase_text(entry.app) == lowercase_text(app)) { match = true; break; }
            if (!match) continue;
        }
        selected.push_back(entry);
    }
    std::uintmax_t total = total_size(selected);
    for (const auto& entry : selected) {
        std::cout << "Removing " << entry.filename << "...\n";
        std::error_code error;
        fs::remove(context.root/L"cache"/wide(entry.filename),error);
    }
    std::cout << "Deleted: " << plural(selected.size(),"file","files") << ", " << human_bytes(total) << '\n';
    return 0;
}
}
int cache_command(const Context& context,const std::vector<std::wstring>& args) {
    if (args.empty()) throw UsageError("cache requires show or rm");
    const auto command = utf8(args[0]);
    std::vector<std::string> apps;
    bool all = false;
    for (std::size_t index = 1; index < args.size(); ++index) {
        const auto argument = utf8(args[index]);
        if (argument == "*" || argument == "-a" || argument == "--all") { all = true; continue; }
        apps.push_back(argument);
    }
    if (command == "show") return cache_show(context,apps);
    if (command == "rm") {
        // Scoop requires a package or `*`/`--all`: a bare `cache rm` must not empty the cache.
        if (apps.empty() && !all) throw std::runtime_error("<app(s)> missing");
        return cache_remove(context,apps,all || apps.empty());
    }
    throw UsageError("cache requires show or rm");
}
int download_command(const Context& context,const std::vector<std::wstring>& args,const std::string& architecture) {
    bool force = false, skip_hash = false;
    std::vector<std::wstring> names;
    for (const auto& argument : args) {
        if (argument == L"-f" || argument == L"--force") { force = true; continue; }
        if (argument == L"-s" || argument == L"--skip-hash-check") { skip_hash = true; continue; }
        if (argument == L"-u" || argument == L"--no-update-scoop") continue;
        if (argument.starts_with(L"-")) throw UsageError("Unknown download option: "+utf8(argument));
        names.push_back(argument);
    }
    if (names.empty()) throw UsageError("download requires one or more packages");
    const auto index = catalogue(context);
    bool failed = false;
    for (const auto& request : names) {
        auto name = utf8(request);
        std::string bucket;
        if (const auto slash = name.find('/'); slash != std::string::npos) {
            bucket = name.substr(0,slash);
            name = name.substr(slash+1);
        }
        const ir::CatalogueEntry* found = nullptr;
        for (const auto& entry : index)
            if (lowercase_text(entry.name) == lowercase_text(name) && (bucket.empty() || lowercase_text(entry.bucket) == lowercase_text(bucket))) {
                if (found) throw std::runtime_error("Ambiguous package; qualify it with its bucket");
                found = &entry;
            }
        if (!found) { std::cerr << "coop: Package not found in local buckets: "<<utf8(request)<<'\n'; failed = true; continue; }
        try {
            auto package = parse_package(found->manifest_path,found->name,found->bucket,
                architecture.empty() ? std::string("64bit") : architecture);
            ir::validate(package);
            std::cout << "Downloading '"<<package.name<<"' ("<<package.version<<") ["
                      <<(architecture.empty() ? "64bit" : architecture)<<"] from "<<package.bucket<<" bucket\n";
            std::error_code directory_error;
            fs::create_directories(context.root/L"cache",directory_error);
            for (const auto& artifact : package.downloads) {
                const auto suffix = wide(sha256_text(artifact.url).substr(0,7))+
                    fs::path(wide(artifact.url)).extension().wstring();
                const auto cached = context.root/L"cache"/(wide(package.name)+L"#"+wide(package.version)+L"#"+suffix);
                std::error_code error;
                if (!force && fs::is_regular_file(cached,error) &&
                    digest_file(cached,artifact.digest.algorithm) == artifact.digest.value) {
                    std::cout << lines::loading_cache(artifact.filename) << '\n';
                    continue;
                }
                // Scoop names the size before the transfer; a local artifact is measured up front and a
                // network one once its response headers arrive.
                const auto announce = [&artifact](std::uint64_t size) {
                    progress_stage(lines::downloading(artifact.url,size != 0,size));
                };
                if (artifact.url.starts_with("file://")) announce(artifact_size(artifact.url).value_or(0));
                // `download_file` refuses to overwrite, so a forced or stale entry is removed first.
                std::error_code existing_error;
                fs::remove(cached,existing_error);
                try {
                    download_file(artifact.url,cached,[](std::uint64_t,std::uint64_t) {},announce);
                } catch (...) {
                    std::error_code remove_error;
                    fs::remove(cached,remove_error);
                    throw;
                }
                progress_finish_stage();
                progress_stage(lines::checking_hash(artifact.filename));
                if (!skip_hash && digest_file(cached,artifact.digest.algorithm) != artifact.digest.value) {
                    std::error_code remove_error;
                    fs::remove(cached,remove_error);
                    throw std::runtime_error("Artifact digest mismatch: "+artifact.filename);
                }
                std::cout << "OK.\n";
            }
        } catch (const std::exception& error) {
            std::cerr << "coop: "<<utf8(request)<<": "<<error.what()<<'\n';
            failed = true;
        }
    }
    return failed ? 1 : 0;
}
}
