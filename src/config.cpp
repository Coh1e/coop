#include "app.hpp"
#include "native.hpp"
#include "package.hpp"
#include "progress.hpp"
#include "script.hpp"
#include <fstream>
#include <windows.h>
#include <iostream>
#include <vector>

namespace coop {
namespace {
// Scoop keeps its settings in `%XDG_CONFIG_HOME%\scoop\config.json`, falling back to
// `%USERPROFILE%\.config\scoop\config.json`. Coop reads and writes the same file: a second copy would
// let the two clients disagree about the same alias or setting.
fs::path config_file() {
    wchar_t buffer[32768]{};
    if (const auto length = GetEnvironmentVariableW(L"XDG_CONFIG_HOME",buffer,32768); length && length < 32768)
        return fs::path(std::wstring(buffer,length))/L"scoop"/L"config.json";
    if (const auto length = GetEnvironmentVariableW(L"USERPROFILE",buffer,32768); length && length < 32768)
        return fs::path(std::wstring(buffer,length))/L".config"/L"scoop"/L"config.json";
    throw std::runtime_error("Cannot locate the user profile for the Scoop configuration");
}
// Only the keys Coop implements may be written. Everything else is read, reported and preserved:
// overwriting `root_path` or `last_update` would silently change the other client's behaviour.
bool coop_owned(const std::string& key) { return key == "ALIAS" || key == "virustotal_api_key"; }
Json read_config() {
    const auto path = config_file();
    std::error_code error;
    if (!fs::is_regular_file(path,error)) return Json::object();
    try {
        const auto value = read_json(path);
        if (!value.is_object()) throw std::runtime_error("not an object");
        return value;
    } catch (const std::exception&) {
        throw std::runtime_error("Scoop configuration is not readable JSON: "+path_text(path));
    }
}
void write_config(const Json& config) {
    const auto path = config_file();
    std::error_code error;
    fs::create_directories(path.parent_path(),error);
    write_json(path,config);
}
std::string value_text(const Json& value) {
    if (value.is_string()) return value.get<std::string>();
    return value.dump();
}
void write_text(const fs::path& path,const std::string& text) {
    std::error_code error;
    fs::create_directories(path.parent_path(),error);
    std::ofstream stream(path,std::ios::binary|std::ios::trunc);
    if (!stream) throw std::runtime_error("Cannot write "+path_text(path));
    stream.write(text.data(),static_cast<std::streamsize>(text.size()));
}
std::string read_text(const fs::path& path) {
    std::ifstream stream(path,std::ios::binary);
    if (!stream) throw std::runtime_error("Cannot read "+path_text(path));
    return std::string(std::istreambuf_iterator<char>(stream),{});
}
fs::path alias_script_path(const Context& context,const std::string& name) {
    return context.root/L"shims"/(L"scoop-"+wide(name)+L".ps1");
}
std::string script_summary(const std::string& content) {
    const auto prefix = std::string("# Summary:");
    if (content.starts_with(prefix)) {
        const auto end = content.find('\n');
        auto summary = content.substr(prefix.size(),end == std::string::npos ? std::string::npos : end-prefix.size());
        while (!summary.empty() && (summary.front() == ' ' || summary.front() == '\r')) summary.erase(summary.begin());
        while (!summary.empty() && (summary.back() == ' ' || summary.back() == '\r')) summary.pop_back();
        return summary;
    }
    return {};
}
std::string script_command(const std::string& content) {
    const auto newline = content.find('\n');
    if (newline == std::string::npos) return {};
    auto command = content.substr(newline+1);
    while (!command.empty() && (command.back() == '\n' || command.back() == '\r')) command.pop_back();
    return command;
}
}
std::string config_value(const std::string& key) {
    const auto config = read_config();
    if (!config.contains(key)) return {};
    return value_text(config.at(key));
}
int config_command(const Context& context,const std::vector<std::wstring>& args) {
    (void)context;
    auto config = read_config();
    if (args.empty()) {
        std::vector<std::vector<std::string>> rows;
        for (const auto& [key,value] : config.items())
            rows.push_back({key,value_text(value),coop_owned(key) ? std::string{} : "Coop ignores this key"});
        if (rows.empty()) { std::cout << "The Scoop configuration is empty.\n"; return 0; }
        print_table({"Name","Value","Note"},rows);
        return 0;
    }
    const auto first = utf8(args[0]);
    if (first == "rm") {
        if (args.size() != 2) throw UsageError("config rm requires one key");
        const auto key = utf8(args[1]);
        if (!coop_owned(key)) throw std::runtime_error("config key '"+key+"' is not managed by Coop; it is preserved and ignored");
        config.erase(key);
        write_config(config);
        return 0;
    }
    if (args.size() == 1) {
        if (!config.contains(first)) throw std::runtime_error("config key '"+first+"' is not set");
        std::cout << value_text(config.at(first)) << '\n';
        return 0;
    }
    if (args.size() > 2) throw UsageError("config accepts a key and an optional value");
    if (!coop_owned(first)) throw std::runtime_error("config key '"+first+"' is not managed by Coop; it is preserved and ignored");
    config[first] = utf8(args[1]);
    write_config(config);
    return 0;
}
int alias_command(const Context& context,const std::vector<std::wstring>& args) {
    if (args.empty()) throw UsageError("alias requires add, rm or list");
    const auto command = utf8(args[0]);
    auto config = read_config();
    Json aliases = config.contains("ALIAS") && config.at("ALIAS").is_object() ? config.at("ALIAS") : Json::object();
    if (command == "add") {
        if (args.size() < 3) throw UsageError("alias add requires a name and a command");
        const auto name = utf8(args[1]);
        const auto body = utf8(args[2]);
        const auto description = args.size() > 3 ? utf8(args[3]) : std::string{};
        if (aliases.contains(name)) throw std::runtime_error("Alias '"+name+"' already exists.");
        const auto script = alias_script_path(context,name);
        std::error_code error;
        if (fs::exists(script,error)) throw std::runtime_error("File 'scoop-"+name+".ps1' already exists in shims directory.");
        // Scoop's own shape: a `# Summary:` line followed by the command body.
        write_text(script,"# Summary: "+description+"\n"+body+"\n");
        aliases[name] = "scoop-"+name;
        config["ALIAS"] = aliases;
        write_config(config);
        std::cout << "Alias '"<<name<<"' added.\n";
        return 0;
    }
    if (command == "rm") {
        if (args.size() != 2) throw UsageError("alias rm requires one name");
        const auto name = utf8(args[1]);
        if (!aliases.contains(name)) throw std::runtime_error("Alias '"+name+"' doesn't exist.");
        std::cout << "Removing alias '"<<name<<"'...\n";
        std::error_code error;
        fs::remove(alias_script_path(context,name),error);
        aliases.erase(name);
        config["ALIAS"] = aliases;
        write_config(config);
        return 0;
    }
    if (command == "list") {
        bool verbose = false;
        for (std::size_t index = 1; index < args.size(); ++index) {
            const auto argument = utf8(args[index]);
            if (argument == "-v" || argument == "--verbose") { verbose = true; continue; }
            throw UsageError("alias list accepts only -v/--verbose");
        }
        std::vector<std::vector<std::string>> rows;
        for (const auto& [name,script] : aliases.items()) {
            if (!script.is_string()) continue;
            std::error_code error;
            const auto path = alias_script_path(context,name);
            if (!fs::is_regular_file(path,error)) {
                rows.push_back({name,"<BROKEN>"});
                continue;
            }
            const auto content = read_text(path);
            std::vector<std::string> row{name,script_command(content)};
            if (verbose) row.push_back(script_summary(content));
            rows.push_back(std::move(row));
        }
        if (rows.empty()) { std::cout << "No alias found.\n"; return 0; }
        std::sort(rows.begin(),rows.end());
        if (verbose) print_table({"Name","Command","Summary"},rows);
        else print_table({"Name","Command"},rows);
        return 0;
    }
    throw UsageError("'"+command+"' is not one of available subcommands: add, rm, list");
}
int run_alias_script(const Context& context,const std::string& name,const std::vector<std::wstring>& arguments) {
    const auto script = alias_script_path(context,name);
    const auto host = script_host();
    if (!host.interpreter) throw std::runtime_error("A PowerShell runtime is required to run an alias");
    std::vector<std::string> argv{"-NoProfile","-ExecutionPolicy","Bypass","-File",path_text(script)};
    for (const auto& argument : arguments) argv.push_back(utf8(argument));
    const auto logs = state_directory(context)/L"logs";
    std::error_code error;
    fs::create_directories(logs,error);
    const auto run = run_tool(*host.interpreter,argv,fs::path{},logs/(L"alias-"+wide(name)+L"-stdout.log"),
        logs/(L"alias-"+wide(name)+L"-stderr.log"),true);
    return run.exit_code;
}
}
