#include "progress.hpp"
#include <io.h>
#include <cstdio>
#include <iostream>

namespace coop {
namespace {
Progress* g_progress = nullptr;
}
void set_progress(Progress* progress) { g_progress = progress; }
Progress* active_progress() { return g_progress; }
void progress_package(const std::string& text) { if (g_progress) g_progress->package(text); }
void progress_stage(const std::string& text) { if (g_progress) g_progress->stage(text); }
void progress_bytes(std::uint64_t done, std::uint64_t total) { if (g_progress) g_progress->bytes(done,total); }
void progress_finish_stage() { if (g_progress) g_progress->finish_stage(); }

bool stdout_is_terminal() {
    static const bool terminal = _isatty(_fileno(stdout)) != 0;
    return terminal;
}

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
}
