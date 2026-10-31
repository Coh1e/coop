#include "catalog_index.hpp"
#include "package.hpp"
#include <algorithm>
#include <cstdint>
#include <stdexcept>
#include <utility>
#include <vector>

namespace coop {
namespace {
// 2 adds the binary names `search` matches against (Scoop matches app names and binaries).
constexpr int index_format = 2;

fs::path catalog_directory(const Json& source) {
    const auto location = fs::path(wide(source.at("path").get<std::string>()));
    return fs::is_directory(location/L"bucket") ? location/L"bucket" : location;
}
bool git_source(const Json& source) {
    return source.value("kind",std::string{}) == "git";
}
std::vector<fs::path> manifest_files(const fs::path& directory) {
    std::vector<fs::path> files;
    if (!fs::is_directory(directory)) return files;
    for (const auto& file : fs::directory_iterator(directory)) {
        if (!file.is_regular_file() || file.path().extension() != L".json") continue;
        files.push_back(file.path());
    }
    std::sort(files.begin(),files.end(),[](const fs::path& a, const fs::path& b) {
        return path_text(a.filename()) < path_text(b.filename());
    });
    return files;
}
Json scan_entries(const fs::path& directory) {
    Json result = Json::array();
    for (const auto& path : manifest_files(directory)) {
        Json item = {{"name",path_text(path.stem())},{"diagnostics",Json::array()}};
        try {
            const auto manifest = read_json(path);
            if (!manifest.is_object()) throw std::runtime_error("Manifest must be a JSON object");
            item["version"] = manifest.at("version").get<std::string>();
            item["description"] = manifest.value("description",std::string{});
            item["homepage"] = manifest.value("homepage",std::string{});
            // `bin` may be a string, a list of strings, or tuples of [target, alias, arguments...],
            // declared at the top level or per architecture. Every string in it can be the name a
            // user searches for, which is what Scoop matches against.
            Json binaries = Json::array();
            const auto collect = [&binaries](const Json& value) {
                if (value.is_string()) { binaries.push_back(value); return; }
                if (!value.is_array()) return;
                for (const auto& entry : value) {
                    if (entry.is_string()) { binaries.push_back(entry); continue; }
                    if (!entry.is_array()) continue;
                    for (const auto& part : entry) if (part.is_string()) binaries.push_back(part);
                }
            };
            if (manifest.contains("bin")) collect(manifest.at("bin"));
            if (manifest.contains("architecture") && manifest.at("architecture").is_object())
                for (const auto& [architecture,variants] : manifest.at("architecture").items())
                    if (variants.is_object() && variants.contains("bin")) collect(variants.at("bin"));
            item["bin"] = std::move(binaries);
        } catch (const std::exception& error) {
            item["diagnostics"].push_back(error.what());
        }
        result.push_back(std::move(item));
    }
    return result;
}
// A local or unmanaged bucket can change between synchronizations. File size and modification
// time are the same first-level evidence Git uses for its index; content hashes are not needed
// because the index is rebuilt by the next explicit bucket update.
std::string directory_fingerprint(const fs::path& directory) {
    if (!fs::is_directory(directory)) return {};
    std::vector<std::pair<std::string,std::pair<std::uintmax_t,std::string>>> files;
    for (const auto& entry : fs::directory_iterator(directory)) {
        if (!entry.is_regular_file() || entry.path().extension() != L".json") continue;
        std::error_code error;
        const auto size = entry.file_size(error);
        if (error) return {};
        const auto modified = entry.last_write_time(error);
        if (error) return {};
        files.emplace_back(path_text(entry.path().filename()),
            std::make_pair(size,std::to_string(modified.time_since_epoch().count())));
    }
    std::sort(files.begin(),files.end(),[](const auto& a, const auto& b) { return a.first < b.first; });
    std::string material = path_text(directory);
    material += '\n';
    for (const auto& [name,stat] : files) {
        material += name + '|' + std::to_string(stat.first) + '|' + stat.second + '\n';
    }
    return sha256_text(material);
}
fs::path index_path(const Context& context, const std::string& name) {
    validate_component(name);
    return state_cache_directory(context)/L"index"/(wide(name)+L".json");
}
Json read_index(const Context& context, const Json& source, const fs::path& directory) {
    const auto name = source.at("name").get<std::string>();
    const auto index = read_json(index_path(context,name));
    if (!index.is_object() || index.value("version",0) != index_format) return Json();
    if (!equal_name(index.value("bucket",std::string{}),name)) return Json();
    if (index.value("path",std::string{}) != path_text(directory)) return Json();
    if (git_source(source)) {
        const auto revision = source.value("revision",std::string{});
        if (revision.empty() || index.value("revision",std::string{}) != revision) return Json();
    } else if (index.value("fingerprint",std::string{}) != directory_fingerprint(directory)) return Json();
    const auto entries = index.find("entries");
    if (entries == index.end() || !entries->is_array()) return Json();
    return *entries;
}
}
Json catalog_entries(const Context& context, const Json& source) {
    const auto directory = catalog_directory(source);
    try {
        const auto indexed = read_index(context,source,directory);
        if (!indexed.is_null()) return indexed;
    } catch (const std::exception&) {
        // A missing, unreadable or stale index falls back to the published bucket files.
    }
    return scan_entries(directory);
}
bool catalog_index_valid(const Context& context, const Json& source) {
    try {
        return !read_index(context,source,catalog_directory(source)).is_null();
    } catch (const std::exception&) {
        return false;
    }
}
void write_catalog_index(const Context& context, const Json& source) {
    const auto name = source.at("name").get<std::string>();
    const auto directory = catalog_directory(source);
    if (!fs::is_directory(directory)) return;
    Json index = {{"version",index_format},{"bucket",name},{"kind",source.value("kind",std::string{})},
        {"path",path_text(directory)},{"entries",scan_entries(directory)}};
    if (git_source(source)) index["revision"] = source.value("revision",std::string{});
    else index["fingerprint"] = directory_fingerprint(directory);
    // The index is read on every query; compact JSON keeps parse time proportional to the
    // metadata rather than to formatting whitespace.
    write_json(index_path(context,name),index,true);
}
}
