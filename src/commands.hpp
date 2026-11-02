#pragma once
#include <span>
#include <string_view>

namespace coop {
// The command surface has one source: dispatch, the `coop help` page, `coop <command> --help` and
// the `--help`/no-argument entry point all read this table, so a command cannot be dispatched
// without being documented or documented without being dispatched.
struct Command {
    const char* name;
    // Scoop 0.6.0's usage string, printed as `Usage: coop <command> <usage>`; empty when Scoop
    // prints none.
    const char* usage;
    const char* summary;
    // A Scoop command Coop does not implement yet stays in the table and says so in `coop help`.
    bool implemented;
    // True for the 28 commands Scoop publishes. False for Coop-only `init` and `recover`, which
    // dispatch and answer `coop help <command>` but never appear on the `coop help` page, because
    // that page must stay identical to `scoop help`.
    bool scoop_command;
};
std::span<const Command> commands();
// True when `name` is a command Coop dispatches, including the Coop-only `init` and `recover`.
bool is_command(std::string_view name);
std::string_view command_help(std::string_view name);
std::string_view command_limitations(std::string_view name);
}
