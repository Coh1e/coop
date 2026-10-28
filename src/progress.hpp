#pragma once
#include <cstdint>
#include <string>

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

// Installed by the CLI for the duration of one write command; null in tests and --json runs.
void set_progress(Progress* progress);
Progress* active_progress();

void progress_package(const std::string& text);
void progress_stage(const std::string& text);
void progress_bytes(std::uint64_t done, std::uint64_t total);
void progress_finish_stage();

bool stdout_is_terminal();

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
