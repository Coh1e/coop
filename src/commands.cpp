#include "commands.hpp"

namespace coop {
namespace {
// Order is the order `coop help` prints: Scoop lists its commands alphabetically, and the two
// Coop-only commands take their alphabetical place so the dispatch lookup stays linear and obvious.
constexpr Command kCommands[] = {
    {"alias","<subcommand> [options] [<args>]","Manage scoop aliases",true,true},
    {"bucket","add|list|known|rm [<args>]","Manage Scoop buckets",true,true},
    {"cache","show|rm [app(s)]","Show or clear the download cache",true,true},
    {"cat","<app>","Show content of specified manifest.",true,true},
    {"checkup","","Check for potential problems",true,true},
    {"cleanup","<app> [options]","Cleanup apps by removing old versions",true,true},
    {"config","[rm] name [value]","Get or set configuration values",true,true},
    {"create","<url>","Create a custom app manifest",true,true},
    {"depends","<app>","List dependencies for an app, in the order they'll be installed",true,true},
    {"download","<app> [options]","Download apps in the cache folder and verify hashes",true,true},
    {"export","> scoopfile.json","Exports installed apps, buckets (and optionally configs) in JSON format",true,true},
    {"help","<command>","Show help for a command",true,true},
    {"hold","<apps>","Hold an app to disable updates",true,true},
    {"home","<app>","Opens the app homepage",true,true},
    {"import","<path/url to scoopfile.json>","Imports apps, buckets and configs from a Scoopfile in JSON format",true,true},
    {"info","<app> [options]","Display information about an app",true,true},
    {"init","[--dry-run]","Initialize a Scoop-compatible installation root",true,false},
    {"install","<app> [options]","Install apps",true,true},
    {"list","[query]","List installed apps",true,true},
    {"prefix","<app>","Returns the path to the specified app",true,true},
    {"recover","[package...] [--dry-run]","Recover package operations left unfinished",true,false},
    {"reset","<app>","Reset an app to resolve conflicts",true,true},
    {"search","<query>","Search available apps",true,true},
    {"shim","<subcommand> [<shim_name>...] [options] [other_args]","Manipulate Scoop shims",true,true},
    {"status","","Show status and check for new app versions",true,true},
    {"unhold","<app>","Unhold an app to enable updates",true,true},
    {"uninstall","<app> [options]","Uninstall an app",true,true},
    {"update","<app> [options]","Update apps, or Scoop itself",true,true},
    {"virustotal","[* | app1 app2 ...] [options]","Look for app's hash or url on virustotal.com",true,true},
    {"which","<command>","Locate a shim/executable (similar to 'which' on Linux)",true,true}
};
}
std::span<const Command> commands() { return kCommands; }
bool is_command(std::string_view name) {
    for (const auto& command : kCommands) if (name == command.name) return true;
    return false;
}
std::string_view command_help(std::string_view name) {
    static constexpr struct { std::string_view name; std::string_view text; } help[] = {
#include "command_help.inc"
    };
    for (const auto& entry : help) if (entry.name == name) return entry.text;
    return {};
}
std::string_view command_limitations(std::string_view name) {
    if (name == "bucket") return "add requires an explicit source. rm removes the registration and retains source files. update refreshes shared buckets.";
    if (name == "cat") return "The manifest is printed as stored; cat_style and bat are not used.";
    if (name == "checkup") return "Checks system settings, extraction helpers, buckets, pending transactions and broken shims. Defender exclusions are not inspected or changed.";
    if (name == "cleanup") return "With no app, cleans all apps. --transactions also trims completed transaction records. Global installations are read-only.";
    if (name == "config") return "The settings below describe the shared Scoop configuration. Coop only writes ALIAS and virustotal_api_key; other settings are preserved. Coop does not implement every Scoop setting.";
    if (name == "create") return "Prints an offline manifest skeleton to stdout; no download is made and the hash must be filled in.";
    if (name == "export") return "Exports user apps and buckets. -c/--config is not supported.";
    if (name == "import") return "Imports user apps and buckets. Configuration settings and global installations are not imported.";
    if (name == "install" || name == "uninstall") return "Global installations are read-only. --dry-run previews the operation; --json returns machine-readable output.";
    if (name == "reset") return "Use <app>@<installed-version> to switch to a retained local version. The current version is rejected; no download or installation hook is run.";
    if (name == "status") return "Checks Coop and same-root Scoop updates unless -l is used. Does not update clients or buckets. JSON reports local packages only.";
    if (name == "update") return "Without an app, refreshes buckets only; Coop does not self-update. Package options require app names or */-a/--all. --dry-run is read-only; bare and manifest-URL previews are not available yet. Global installations are read-only.";
    if (name == "shim") return "Lists local native shims; info also shows Target and Arguments. alter changes saved arguments; interactive source selection is not supported.";
    if (name == "virustotal") return "Requires virustotal_api_key or COOP_VIRUSTOTAL_KEY. Uploading for analysis (-s/--scan) is not supported. Uses Coop exit codes 0/1/2, not Scoop's bitmask codes.";
    return {};
}
}
