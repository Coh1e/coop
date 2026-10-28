#pragma once
#include "app.hpp"
#include <functional>
namespace coop {
// Downloads one artifact. The optional callback reports (received, total) bytes while the body
// streams; total is 0 when the server did not declare a Content-Length.
void download_file(const std::string& url, const fs::path& destination,
    const std::function<void(std::uint64_t,std::uint64_t)>& on_progress = {});
void make_junction(const fs::path& link, const fs::path& target);
// Reads the target of an NTFS directory junction (mount point). Used wherever a managed link must
// be proven to belong to Coop's own object instead of being followed or deleted blindly.
fs::path junction_target(const fs::path& link);
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
