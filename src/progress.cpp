#include "progress.hpp"
#include <io.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <iostream>
#include <mutex>
#include <thread>

namespace coop {
namespace {
Progress* g_progress = nullptr;
// Every emitted line and every progress tick updates this stamp; the stall watchdog compares it with
// the current time. A write command that reaches a step which can block (name resolution, TCP connect,
// TLS, a lock) leaves no other visible trace until that step returns, which is how `coop update coop`
// once looked frozen without printing a single line.
std::atomic<long long> g_last_output_ms{0};
long long now_ms() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}
std::mutex g_output_mutex;
void note_output() { g_last_output_ms.store(now_ms()); }
}
void set_progress(Progress* progress) { g_progress = progress; note_output(); }
Progress* active_progress() { return g_progress; }
void progress_package(const std::string& text) { note_output(); if (g_progress) g_progress->package(text); }
void progress_stage(const std::string& text) { note_output(); if (g_progress) g_progress->stage(text); }
void progress_bytes(std::uint64_t done, std::uint64_t total) { note_output(); if (g_progress) g_progress->bytes(done,total); }
void progress_finish_stage() { if (g_progress) g_progress->finish_stage(); }
StallWatchdog::StallWatchdog(int threshold_seconds) : threshold_seconds_(threshold_seconds) {
    note_output();
    worker_ = std::thread([this] {
        using namespace std::chrono;
        while (!stop_.load()) {
            std::this_thread::sleep_for(milliseconds(500));
            if (stop_.load()) break;
            const auto now = now_ms();
            const auto stamp = g_last_output_ms.load();
            if (!stamp || now-stamp < static_cast<long long>(threshold_seconds_)*1000) continue;
            if (warned_ms_ && now-warned_ms_ < 10000) continue;
            warned_ms_ = now;
            // The stamp moves forward so the next warning is one interval away, not immediate.
            g_last_output_ms.store(now);
            const std::lock_guard<std::mutex> lock(g_output_mutex);
            std::cout << "\ncoop: still working, "<<(now-stamp)/1000<<"s without progress\n";
            std::cout.flush();
        }
    });
}
StallWatchdog::~StallWatchdog() {
    stop_.store(true);
    if (worker_.joinable()) worker_.join();
}

bool stdout_is_terminal() {
    static const bool terminal = _isatty(_fileno(stdout)) != 0;
    return terminal;
}

// The escapes are written unconditionally, exactly as Scoop does: a redirected run keeps them.
std::string human_bytes(std::uint64_t bytes) {
    char text[32]{};
    if (bytes >= 1024ull*1024*1024) std::snprintf(text,sizeof(text),"%.1f GB",bytes/1073741824.0);
    else if (bytes >= 1024ull*1024) std::snprintf(text,sizeof(text),"%.1f MB",bytes/1048576.0);
    else if (bytes >= 1024) std::snprintf(text,sizeof(text),"%.1f KB",bytes/1024.0);
    else std::snprintf(text,sizeof(text),"%llu B",static_cast<unsigned long long>(bytes));
    return text;
}
std::size_t display_width(const std::string& value) {
    std::size_t width = 0;
    for (const auto character : value) if ((static_cast<unsigned char>(character) & 0xC0) != 0x80) ++width;
    return width;
}
void print_table(const std::vector<std::string>& header,
                 const std::vector<std::vector<std::string>>& rows) {
    const auto width_of = [](const std::string& value) {
        // Character width, not byte width, so a non-ASCII name still lines up.
        std::size_t width = 0;
        for (const auto character : value) if ((static_cast<unsigned char>(character) & 0xC0) != 0x80) ++width;
        return width;
    };
    std::vector<std::size_t> widths(header.size(),0);
    for (std::size_t index = 0; index < header.size(); ++index) widths[index] = width_of(header[index]);
    for (const auto& row : rows) for (std::size_t index = 0; index < row.size() && index < widths.size(); ++index)
        widths[index] = (std::max)(widths[index],width_of(row[index]));
    const auto print_row = [&widths,&width_of](const std::vector<std::string>& cells) {
        for (std::size_t index = 0; index < cells.size(); ++index) {
            if (index) std::cout << ' ';
            std::cout << cells[index];
            const auto width = width_of(cells[index]);
            if (index < widths.size() && width < widths[index]) std::cout << std::string(widths[index]-width,' ');
        }
        std::cout << '\n';
    };
    print_row(header);
    std::vector<std::string> rule;
    for (const auto& cell : header) rule.push_back(std::string(width_of(cell),'-'));
    print_row(rule);
    for (const auto& row : rows) print_row(row);
}
std::string ansi_cyan(const std::string& text) { return "\x1b[36m"+text+"\x1b[0m"; }
std::string ansi_dark_yellow(const std::string& text) { return "\x1b[33m"+text+"\x1b[0m"; }

void TextProgress::package(const std::string& text) {
    finish_stage();
    std::cout << text << "\n";
    std::cout.flush();
}
void TextProgress::stage(const std::string& text) {
    finish_stage();
    std::cout << text << "\n";
    std::cout.flush();
}
void TextProgress::bytes(std::uint64_t done, std::uint64_t total) {
    if (!stdout_is_terminal() || !total) return;
    const auto percent = done*100/total;
    const auto mb = [](std::uint64_t bytes) { return static_cast<double>(bytes)/1048576.0; };
    char line[96]{};
    std::snprintf(line,sizeof(line),"\r  %3llu%%  %6.1f / %6.1f MB",
        static_cast<unsigned long long>(percent),mb(done),mb(total));
    std::cout << line;
    std::cout.flush();
    inline_active = true;
}
void TextProgress::finish_stage() {
    if (!inline_active) return;
    std::cout << "\r" << std::string(60,' ') << "\r";
    std::cout.flush();
    inline_active = false;
}
namespace lines {
std::string package_start(const std::string& verb,const std::string& name,const std::string& version,
    const std::string& architecture,const std::string& bucket,const std::string& previous,bool terminate) {
    // Scoop's shapes: uninstall and reset carry no architecture or bucket, reset does not quote the
    // name, and install/update end without a period while the other two carry one.
    if (verb == "Resetting") return verb+" "+name+" ("+version+")"+(terminate ? "." : "");
    if (verb == "Uninstalling") return verb+" '"+name+"' ("+version+")"+(terminate ? "." : "");
    if (verb == "Updating") return verb+" '"+name+"' ("+(previous.empty() ? version : previous)+" -> "+version+")";
    std::string line = verb+" '"+name+"' ("+version+")";
    if (!architecture.empty()) line += " ["+architecture+"]";
    if (!bucket.empty()) line += " from '"+bucket+"' bucket";
    return line;
}
std::string downloading(const std::string& url,bool have_size,std::uint64_t size) {
    return "Downloading "+url+(have_size ? " ("+human_bytes(size)+")..." : "");
}
std::string loading_cache(const std::string& file) { return "Loading "+file+" from cache"; }
std::string checking_hash(const std::string& file) { return "Checking hash of "+ansi_cyan(file)+"... "; }
std::string extracting(const std::string& file) { return "Extracting "+ansi_cyan(file)+"... "; }
std::string linking(const std::string& link,const std::string& target) { return "Linking "+link+" => "+target; }
std::string creating_shim(const std::string& alias) { return "Creating shim for '"+alias+"'."; }
std::string removing_shim(const std::string& alias,const std::string& suffix) { return "Removing shim '"+alias+suffix+"'."; }
std::string installed(const std::string& name,const std::string& version) {
    return "'"+name+"' ("+version+") was installed successfully!";
}
std::string uninstalled(const std::string& name) { return "'"+name+"' was uninstalled."; }
std::string up_to_date(const std::string& name) { return name+": up-to-date"; }
std::string already_installed(const std::string& name,const std::string& version) {
    return "WARN  '"+name+"' ("+version+") is already installed.";
}
// Verbatim alignment covers the stage lines. A sentence that names the client itself follows the
// client the user is actually running, so Coop does not tell its own user to run Scoop.
std::string advise_update(const std::string& name) { return "Use 'coop update "+name+"' to install a new version."; }
std::string version_move(const std::string& name,const std::string& from,const std::string& to) {
    return name+": "+from+" -> "+to;
}
std::string batch_heading(std::size_t outdated) {
    if (outdated == 1) return "Updating one outdated app:";
    return "Updating "+std::to_string(outdated)+" outdated apps:";
}
std::string unlinking(const std::string& path) { return "Unlinking "+path; }
std::string marking_gui(const std::string& path) { return "Making "+path+" a GUI binary."; }
std::string cleanup_removing(const std::string& name) { return "Removing "+name+":"; }
std::string cleanup_version(const std::string& version) { return " "+version; }
std::string cleanup_done() { return "Everything is shiny now!"; }
}
}
