#pragma once
#include "package.hpp"

namespace coop {
// Extract a ZIP, tar or 7z archive into an empty, Coop-owned directory.
// Entry paths are validated before any file is written; link entries are rejected.
void extract_archive(const fs::path& archive, const fs::path& destination);
// Move the contents below an optional extract_dir into the package staging directory.
void merge_archive_tree(const fs::path& source, const fs::path& extract_directory, const fs::path& destination);

// External tools are detected, never downloaded or installed by Coop. MSI extraction is
// deliberately not enabled: the administrative install path modifies the Windows Installer
// machine cache outside the selected project root, so the limitation is reported instead of
// being hidden behind a successful-looking lifecycle.
struct ExternalTool {
    std::string name;
    std::string purpose;
    std::string policy;
    bool available = false;
    bool enabled = false;
    std::string limitation;
    fs::path path;
};
std::optional<fs::path> msi_installer();
std::vector<ExternalTool> package_external_tools(const Package& package);
}
