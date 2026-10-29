#include "app.hpp"
#include "ir.hpp"
#include "package.hpp"
#include "progress.hpp"
#include "shim.hpp"
#include <array>
#include <fstream>
#include <windows.h>
#include <iostream>
#include <vector>

namespace coop {
namespace {
// The install record is what Scoop's own `hold` writes and what `list`/`status` read for
// `Held package`. `scoop-install.json` is the current name, `install.json` the legacy one.
fs::path install_record(const fs::path& version_directory) {
    for (const auto* name : {L"scoop-install.json", L"install.json"}) {
        std::error_code error;
        if (fs::is_regular_file(version_directory/name,error)) return version_directory/name;
    }
    return {};
}
bool is_held(const fs::path& record) {
    try { return read_json(record).value("hold",false); }
    catch (const std::exception&) { return false; }
}
}
int hold_command(const Context& context, const std::vector<std::wstring>& args, bool hold) {
    std::vector<std::wstring> names;
    for (const auto& argument : args) {
        if (argument == L"-g" || argument == L"--global")
            throw std::runtime_error("global-scope-readonly: Coop does not write a system-level installation; "
                                     "use --global-root to read one");
        if (argument.starts_with(L"-")) throw UsageError("Unknown "+std::string(hold ? "hold" : "unhold")+" option: "+utf8(argument));
        names.push_back(argument);
    }
    if (names.empty()) throw UsageError(std::string("Use one or more packages"));
    int result = 0;
    for (const auto& request : names) {
        const auto name = utf8(request);
        std::error_code error;
        const auto current = context.root/L"apps"/wide(name)/L"current";
        const auto directory = fs::canonical(current,error);
        if (error) {
            std::cerr << "coop: '"<<name<<"' is not installed.\n";
            result = 1;
            continue;
        }
        const auto record = install_record(directory);
        if (record.empty()) {
            std::cerr << "coop: Failed to "<<(hold ? "hold" : "unhold")<<" '"<<name<<"'.\n";
            result = 1;
            continue;
        }
        try {
            auto json = read_json(record);
            const bool held = json.value("hold",false);
            if (hold && held) { std::cout << "INFO  '"<<name<<"' is already held.\n"; continue; }
            if (!hold && !held) { std::cout << "INFO  '"<<name<<"' is not held.\n"; continue; }
            if (hold) json["hold"] = true;
            else json.erase("hold");
            write_json(record,json);
            std::cout << (hold ? name+" is now held and can not be updated anymore."
                               : name+" is no longer held and can be updated again.") << '\n';
        } catch (const std::exception& failure) {
            std::cerr << "coop: "<<name<<": "<<failure.what()<<'\n';
            result = 1;
        }
    }
    return result;
}
// `shim` manages the shared <root>/shims entries. `add` publishes the same launcher Coop copies for
// a package entry and records the target in a Scoop `.shim` file, so either client can run, list and
// remove the result.
namespace {
fs::path shims_directory(const Context& context) { return context.root/L"shims"; }
std::string trim_text_value(std::string value) {
    while (!value.empty() && (value.back() == '\r' || value.back() == '\n' || value.back() == ' ')) value.pop_back();
    while (!value.empty() && (value.front() == ' ' || value.front() == '\r')) value.erase(value.begin());
    return value;
}
std::vector<fs::path> shim_files(const Context& context) {
    std::vector<fs::path> files;
    std::error_code error;
    const auto directory = shims_directory(context);
    if (!fs::is_directory(directory,error)) return files;
    for (const auto& entry : fs::directory_iterator(directory,error)) {
        if (error) break;
        std::error_code type_error;
        if (entry.is_regular_file(type_error) && entry.path().extension() == L".shim") files.push_back(entry.path());
    }
    std::sort(files.begin(),files.end());
    return files;
}
std::string quoted_value(const std::string& value) { return "\""+value+"\""; }
void write_shim_file(const fs::path& path,const std::string& target,const std::string& arguments) {
    std::string text = "path = "+quoted_value(target)+"\n";
    if (!arguments.empty()) text += "args = "+quoted_value(arguments)+"\n";
    std::error_code error;
    fs::create_directories(path.parent_path(),error);
    std::ofstream stream(path,std::ios::binary|std::ios::trunc);
    if (!stream) throw std::runtime_error("Cannot write "+path_text(path));
    stream.write(text.data(),static_cast<std::streamsize>(text.size()));
}
void publish_launcher(const fs::path& executable) {
    std::array<wchar_t,32768> module{};
    const auto length = GetModuleFileNameW(nullptr,module.data(),static_cast<DWORD>(module.size()));
    if (!length || static_cast<std::size_t>(length) >= module.size())
        throw std::runtime_error("Cannot find the launcher executable");
    std::error_code error;
    if (!fs::copy_file(fs::path(module.data()),executable,fs::copy_options::overwrite_existing,error))
        throw std::runtime_error("Cannot publish the launcher at "+path_text(executable)+": "+error.message());
}
}
int shim_command(const Context& context,const std::vector<std::wstring>& args) {
    if (args.empty()) throw UsageError("shim requires add, rm, list, info or alter");
    const auto command = utf8(args[0]);
    const auto directory = shims_directory(context);
    if (command == "list") {
        std::vector<std::string> filters;
        for (std::size_t index = 1; index < args.size(); ++index) filters.push_back(utf8(args[index]));
        std::vector<std::vector<std::string>> rows;
        for (const auto& file : shim_files(context)) {
            const auto name = utf8(file.stem().wstring());
            if (!filters.empty()) {
                bool match = false;
                for (const auto& filter : filters) if (filter == name) { match = true; break; }
                if (!match) continue;
            }
            try {
                const auto metadata = read_shim_metadata(file);
                rows.push_back({name,metadata.target,metadata.arguments});
            } catch (const std::exception&) {
                rows.push_back({name,"<BROKEN>",std::string{}});
            }
        }
        if (rows.empty()) { std::cout << "No shim found.\n"; return 0; }
        print_table({"Name","Target","Arguments"},rows);
        return 0;
    }
    if (command == "info") {
        if (args.size() != 2) throw UsageError("shim info requires one name");
        const auto name = utf8(args[1]);
        const auto metadata_file = directory/(wide(name)+L".shim");
        std::error_code error;
        if (!fs::is_regular_file(metadata_file,error)) throw std::runtime_error("Shim '"+name+"' not found");
        const auto metadata = read_shim_metadata(metadata_file);
        std::cout << "Name    : "<<name<<"\nTarget  : "<<metadata.target<<"\nArguments: "<<metadata.arguments<<"\n";
        return 0;
    }
    if (command == "add") {
        if (args.size() < 3) throw UsageError("shim add requires a name and a command path");
        const auto name = utf8(args[1]);
        const auto target = utf8(args[2]);
        std::string arguments;
        for (std::size_t index = 3; index < args.size(); ++index) arguments += (arguments.empty() ? "" : " ")+utf8(args[index]);
        std::error_code error;
        if (!fs::is_regular_file(fs::path(wide(target)),error)) throw std::runtime_error("Command path does not exist: "+target);
        const auto metadata = directory/(wide(name)+L".shim");
        if (fs::exists(metadata,error)) throw std::runtime_error("Shim '"+name+"' already exists");
        publish_launcher(directory/(wide(name)+L".exe"));
        write_shim_file(metadata,target,arguments);
        std::cout << "Adding local shim "<<name<<"...\n";
        return 0;
    }
    if (command == "rm") {
        if (args.size() < 2) throw UsageError("shim rm requires one or more names");
        int result = 0;
        for (std::size_t index = 1; index < args.size(); ++index) {
            const auto name = utf8(args[index]);
            std::error_code error;
            const auto metadata = directory/(wide(name)+L".shim");
            const auto coop_metadata = directory/(wide(name)+L".coop-shim.json");
            if (!fs::exists(metadata,error) && !fs::exists(coop_metadata,error)) {
                std::cerr << "coop: Shim '"<<name<<"' not found\n";
                result = 1;
                continue;
            }
            std::cout << "Removing shim '"<<name<<"'...\n";
            fs::remove(metadata,error);
            fs::remove(coop_metadata,error);
            fs::remove(directory/(wide(name)+L".exe"),error);
        }
        return result;
    }
    if (command == "alter") {
        if (args.size() < 3) throw UsageError("shim alter requires a name and arguments");
        const auto name = utf8(args[1]);
        const auto metadata_file = directory/(wide(name)+L".shim");
        std::error_code error;
        if (!fs::is_regular_file(metadata_file,error)) throw std::runtime_error("Shim '"+name+"' not found");
        const auto metadata = read_shim_metadata(metadata_file);
        std::string arguments;
        for (std::size_t index = 2; index < args.size(); ++index) arguments += (arguments.empty() ? "" : " ")+utf8(args[index]);
        write_shim_file(metadata_file,metadata.target,arguments);
        std::cout << "Altering shim '"<<name<<"'...\n";
        return 0;
    }
    throw UsageError("'"+command+"' is not one of available subcommands: add, rm, list, info, alter");
}
bool package_is_held(const fs::path& version_directory) {
    const auto record = install_record(version_directory);
    return !record.empty() && is_held(record);
}
}
