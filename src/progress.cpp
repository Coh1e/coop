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

// The escapes are written unconditionally, exactly as Scoop does: a redirected run keeps them.
std::string human_bytes(std::uint64_t bytes) {
    char text[32]{};
    if (bytes >= 1024ull*1024*1024) std::snprintf(text,sizeof(text),"%.1f GB",bytes/1073741824.0);
    else if (bytes >= 1024ull*1024) std::snprintf(text,sizeof(text),"%.1f MB",bytes/1048576.0);
    else if (bytes >= 1024) std::snprintf(text,sizeof(text),"%.1f KB",bytes/1024.0);
    else std::snprintf(text,sizeof(text),"%llu B",static_cast<unsigned long long>(bytes));
    return text;
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
    const std::string& architecture,const std::string& bucket,const std::string& previous) {
    // Scoop's shapes: uninstall and reset carry no architecture or bucket, reset does not quote the
    // name, and install/update end without a period while the other two carry one.
    if (verb == "Resetting") return verb+" "+name+" ("+version+").";
    if (verb == "Uninstalling") return verb+" '"+name+"' ("+version+").";
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
std::string advise_update(const std::string& name) { return "Use 'scoop update "+name+"' to install a new version."; }
}
}
