#pragma once
#include "package.hpp"

namespace coop {
// Extract a ZIP, tar or 7z archive into an empty, Coop-owned directory.
// Entry paths are validated before any file is written; link entries are rejected.
void extract_archive(const fs::path& archive, const fs::path& destination);
// Move the contents below an optional extract_dir into the package staging directory.
void merge_archive_tree(const fs::path& source, const fs::path& extract_directory, const fs::path& destination);

// External tools are detected, never downloaded or installed by Coop. MSI administrative
// extraction uses the Windows Installer already present on the operating system; the
// COOP_MSIEXEC override exists for isolated tests and points at an explicit tool path.
struct ExternalTool {
    std::string name;
    std::string purpose;
    std::string policy;
    bool available = false;
    fs::path path;
};
std::optional<fs::path> msi_installer();
std::vector<ExternalTool> package_external_tools(const Package& package);
struct MsiExtraction {
    fs::path tool;
    fs::path work_directory;
    fs::path source_directory;
    fs::path log_path;
    int exit_code = -1;
};
// Runs msiexec.exe /a into a directory owned by the current transaction. The caller decides
// whether a non-zero exit code is a failure and keeps the log as evidence either way.
MsiExtraction extract_msi_archive(const fs::path& archive, const fs::path& transaction, std::size_t index);
}
