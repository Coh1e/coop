#include "app.hpp"
#include "native.hpp"
#include "package.hpp"
#include <iostream>
#include <map>
#include <windows.h>
#include <vector>

namespace coop {
namespace {
// `create` derives a name and a version guess from the URL alone: it never downloads, so it works
// offline and cannot fail on a slow server. The output goes to stdout, because writing into a bucket
// needs a target the user has not chosen yet.
std::string version_guess(const std::string& filename) {
    std::string best;
    std::size_t index = 0;
    while (index < filename.size()) {
        if (!std::isdigit(static_cast<unsigned char>(filename[index]))) { ++index; continue; }
        const auto start = index;
        bool dot = false;
        while (index < filename.size()) {
            const auto character = filename[index];
            if (std::isdigit(static_cast<unsigned char>(character))) { ++index; continue; }
            if (character == '.') { dot = true; ++index; continue; }
            break;
        }
        auto candidate = filename.substr(start,index-start);
        while (!candidate.empty() && candidate.back() == '.') candidate.pop_back();
        if (dot && candidate.size() >= 3) return candidate;
    }
    return best;
}
std::string lowercase_text(std::string value) {
    for (auto& character : value) character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    return value;
}
}
int create_command(const Context& context,const std::vector<std::wstring>& args) {
    (void)context;
    if (args.size() != 1) throw UsageError("create requires one URL");
    const auto url = utf8(args[0]);
    if (!url.starts_with("http://") && !url.starts_with("https://"))
        throw std::runtime_error("Error: "+url+" is not a valid URL");
    auto path = url;
    if (const auto query = path.find_first_of("?#"); query != std::string::npos) path.resize(query);
    const auto slash = path.find_last_of('/');
    const auto filename = slash == std::string::npos ? path : path.substr(slash+1);
    if (filename.empty()) throw std::runtime_error("Error: "+url+" has no file name");
    const auto manifest = Json{{"version",version_guess(filename)},{"url",url},{"hash",""},
        {"bin",Json::array()},{"extract_dir",""}};
    std::cout << manifest.dump(2,' ',false,Json::error_handler_t::replace) << '\n';
    return 0;
}
int virustotal_command(const Context& context,const std::vector<std::wstring>& args) {
    bool all = false, passthru = false;
    std::vector<std::wstring> names;
    for (const auto& argument : args) {
        if (argument == L"-a" || argument == L"--all") { all = true; continue; }
        if (argument == L"-p" || argument == L"--passthru") { passthru = true; continue; }
        if (argument == L"-n" || argument == L"--no-depends") continue;
        if (argument == L"-u" || argument == L"--no-update-scoop") continue;
        if (argument == L"-s" || argument == L"--scan")
            throw std::runtime_error("Uploading a package for analysis (-s) is not implemented in Coop yet");
        if (argument.starts_with(L"-")) throw UsageError("Unknown virustotal option: "+utf8(argument));
        names.push_back(argument);
    }
    if (!all && names.empty()) throw UsageError("virustotal requires one or more packages or -a/--all");
    const auto key = config_value("virustotal_api_key");
    if (key.empty()) {
        std::cerr << "coop: the VirusTotal API key is not configured; run 'coop config virustotal_api_key <key>'\n";
        return 1;
    }
    std::string base = "https://www.virustotal.com/api/v3";
    // The API root is overridable so the report parsing can be exercised against a local response
    // without a network or a live key; production runs use the default above.
    wchar_t api_root[32768]{};
    if (const auto length = GetEnvironmentVariableW(L"COOP_VIRUSTOTAL_API",api_root,32768); length && length < 32768)
        base = utf8(std::wstring(api_root,length));
    if (all) {
        names.clear();
        for (const auto& name : installed_package_names(context)) names.push_back(wide(name));
    }
    const auto index = catalogue(context);
    Json output = Json::array();
    int result = 0;
    for (const auto& request : names) {
        auto name = utf8(request);
        std::string bucket;
        if (const auto slash = name.find('/'); slash != std::string::npos) {
            bucket = name.substr(0,slash);
            name = name.substr(slash+1);
        }
        const ir::CatalogueEntry* found = nullptr;
        for (const auto& entry : index)
            if (lowercase_text(entry.name) == lowercase_text(name) &&
                (bucket.empty() || lowercase_text(entry.bucket) == lowercase_text(bucket))) found = &entry;
        if (!found) {
            std::cerr << "coop: couldn't find manifest for '"<<name<<"'\n";
            result = 1;
            continue;
        }
        std::string hash;
        try {
            auto package = parse_package(found->manifest_path,found->name,found->bucket,"64bit");
            if (!package.downloads.empty() && package.downloads.front().digest.algorithm == ir::DigestAlgorithm::sha256)
                hash = package.downloads.front().digest.value;
        } catch (const std::exception& error) {
            std::cerr << "coop: "<<name<<": "<<error.what()<<'\n';
            result = 1;
            continue;
        }
        if (hash.empty()) {
            std::cerr << "coop: '"<<name<<"' declares no SHA256 digest; VirusTotal is keyed by it\n";
            result = 1;
            continue;
        }
        const auto extension = base.starts_with("file://") ? "/"+hash+".json" : "/files/"+hash;
        int status = 0;
        const auto body = http_get_text(base+extension,{{"x-apikey",key}},status);
        Json report = {{"name",name},{"hash",hash}};
        if (status == 404) {
            report["status"] = "no-information";
            if (!passthru) std::cout << name<<": no information in VirusTotal\n";
        } else if (status == 200) {
            try {
                const auto parsed = Json::parse(body);
                const auto stats = parsed.at("data").at("attributes").at("last_analysis_stats");
                const auto count = [&stats](const char* field) {
                    return stats.contains(field) && stats.at(field).is_number_unsigned() ?
                        stats.at(field).get<std::uint64_t>() : 0ull;
                };
                const auto malicious = count("malicious"), suspicious = count("suspicious");
                const auto total = malicious+suspicious+count("harmless")+count("undetected")+count("timeout");
                report["status"] = "reported";
                report["malicious"] = malicious;
                report["suspicious"] = suspicious;
                report["engines"] = total;
                if (!passthru)
                    std::cout << name<<": "<<malicious<<" malicious, "<<suspicious<<" suspicious out of "
                              <<total<<" engines\n";
            } catch (const std::exception&) {
                std::cerr << "coop: "<<name<<": the VirusTotal response is not readable JSON\n";
                result = 1;
                continue;
            }
        } else {
            std::cerr << "coop: "<<name<<": VirusTotal answered HTTP "<<status<<"\n";
            result = 1;
            continue;
        }
        output.push_back(std::move(report));
    }
    if (passthru) std::cout << output.dump(2,' ',false,Json::error_handler_t::replace) << '\n';
    return result;
}
}
