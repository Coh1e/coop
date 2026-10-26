#pragma once
#include "app.hpp"
namespace coop {
void download_file(const std::string& url, const fs::path& destination);
void make_junction(const fs::path& link, const fs::path& target);
// Windows command-line quoting for one argument of a child process command line.
std::wstring quote_argument(const std::wstring& value);
// Start one declared external tool without a shell and capture both output streams. stdout/stderr
// are drained concurrently into the given log files so a noisy tool cannot deadlock on a full
// pipe, while a bounded tail is kept in memory for the transaction journal. An empty working
// directory makes the child inherit the Coop process directory, like a Scoop external command.
struct ToolRun {
    int exit_code = 1;
    std::size_t stdout_bytes = 0;
    std::size_t stderr_bytes = 0;
    std::string stdout_tail;
    std::string stderr_tail;
};
ToolRun run_tool(const fs::path& executable, const std::vector<std::string>& arguments,
                 const fs::path& working_directory, const fs::path& stdout_log,
                 const fs::path& stderr_log, bool echo);
}
