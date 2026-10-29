#pragma once
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <string>
#include <thread>
#include <vector>

namespace coop {
// Human-readable progress for write commands. It never changes the plan, the execution order or the
// exit code, and a --json run installs no progress at all (see GLOSSARY: Progress Feedback).
class Progress {
public:
    virtual ~Progress() = default;
    // One line when a package operation starts: "Installing 'x' (1.4.0) [64bit] from 'main' bucket".
    virtual void package(const std::string& text) { (void)text; }
    // A completed step line: "Extracting x.zip... Done.".
    virtual void stage(const std::string& text) { (void)text; }
    // Inline progress for the current step; only rendered on a terminal.
    virtual void bytes(std::uint64_t done, std::uint64_t total) { (void)done; (void)total; }
    // Clears any inline progress line before the next stage line.
    virtual void finish_stage() {}
};

// Reports when a write command has produced no output for a while. A step that can block (name
// resolution, TCP connect, TLS handshake, an occupied lock) prints nothing of its own, so without
// this the command looks frozen. The watchdog is text-mode only and never changes the plan, the
// execution order or the exit code.
class StallWatchdog {
public:
    explicit StallWatchdog(int threshold_seconds = 5);
    ~StallWatchdog();
    StallWatchdog(const StallWatchdog&) = delete;
    StallWatchdog& operator=(const StallWatchdog&) = delete;
private:
    int threshold_seconds_ = 5;
    std::atomic<bool> stop_{false};
    std::thread worker_;
    long long warned_ms_ = 0;
};
// Installed by the CLI for the duration of one write command; null in tests and --json runs.
void set_progress(Progress* progress);
Progress* active_progress();

void progress_package(const std::string& text);
void progress_stage(const std::string& text);
void progress_bytes(std::uint64_t done, std::uint64_t total);
void progress_finish_stage();

// Scoop writes ANSI escapes into its output regardless of the terminal, so the colour is part of the
// line's bytes and survives a pipe. Text output only; --json never carries these.
std::string ansi_cyan(const std::string& text);
std::string ansi_dark_yellow(const std::string& text);

// The one place a human-readable line is composed. The execution layer supplies data, never English:
// #62 asks for the render to live here, so a line can change without touching the step machine.
namespace lines {
std::string package_start(const std::string& verb,const std::string& name,const std::string& version,
    const std::string& architecture,const std::string& bucket,const std::string& previous,bool terminate = true);
std::string downloading(const std::string& url,bool have_size,std::uint64_t size);
std::string loading_cache(const std::string& file);
std::string checking_hash(const std::string& file);
std::string extracting(const std::string& file);
std::string linking(const std::string& link,const std::string& target);
std::string creating_shim(const std::string& alias);
std::string removing_shim(const std::string& alias,const std::string& suffix);
std::string installed(const std::string& name,const std::string& version);
std::string uninstalled(const std::string& name);
std::string up_to_date(const std::string& name);
std::string already_installed(const std::string& name,const std::string& version);
std::string advise_update(const std::string& name);
std::string version_move(const std::string& name,const std::string& from,const std::string& to);
std::string batch_heading(std::size_t outdated);
std::string unlinking(const std::string& path);
std::string marking_gui(const std::string& path);
std::string cleanup_removing(const std::string& name);
std::string cleanup_version(const std::string& version);
std::string cleanup_done();
}
bool stdout_is_terminal();
// A left-aligned table: every column is as wide as its widest cell (header included), columns are
// separated by one space and the last column is padded too, which is how Scoop's Format-Table prints
// one. Shared by the read commands and `cache show` so both keep the same shape.
// Character width of a UTF-8 string: a multi-byte sequence counts once, so tables line up.
std::size_t display_width(const std::string& value);
void print_table(const std::vector<std::string>& header,
                 const std::vector<std::vector<std::string>>& rows);
// Human-readable byte size, the way Scoop prints one: one decimal place above a kilobyte.
std::string human_bytes(std::uint64_t bytes);

// Writes stage lines to stdout and renders download progress with a carriage-return line.
class TextProgress final : public Progress {
public:
    void package(const std::string& text) override;
    void stage(const std::string& text) override;
    void bytes(std::uint64_t done, std::uint64_t total) override;
    void finish_stage() override;
private:
    bool inline_active = false;
};
}
