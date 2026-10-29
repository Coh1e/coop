#include "app.hpp"
#include "ir.hpp"
#include "package.hpp"
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
bool package_is_held(const fs::path& version_directory) {
    const auto record = install_record(version_directory);
    return !record.empty() && is_held(record);
}
}
