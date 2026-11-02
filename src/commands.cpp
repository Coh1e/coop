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
    {"export","","Exports installed apps, buckets (and optionally configs) in JSON format",true,true},
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
}
