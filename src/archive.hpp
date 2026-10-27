#pragma once
#include "package.hpp"
#include <cstdint>

namespace coop {
// Keep untrusted archive content bounded the same way for every backend.
constexpr std::uint64_t maximum_extracted_bytes = 16ull * 1024 * 1024 * 1024;
constexpr std::size_t maximum_archive_entries = 1000000;

// Extract a ZIP, tar or 7z archive into an empty, Coop-owned directory.
// Entry paths are validated before any file is written; link entries are rejected.
void extract_archive(const fs::path& archive, const fs::path& destination);
// Move the contents below an optional extract_dir into the package staging directory.
void merge_archive_tree(const fs::path& source, const fs::path& extract_directory, const fs::path& destination);
// Validate a package-relative entry name and create its parent directories below root. Shared by
// the archive and MSI image backends so both refuse reparse points and unsafe components the same
// way. Returns the full target path; the caller creates the file itself.
fs::path prepare_package_target(const fs::path& root, const fs::path& relative);

// External tools are detected, never downloaded or installed by Coop. The MSI image backend uses
// the Windows Installer database API (a Windows system component) read-only, so it is reported as
// a detected requirement with its exact boundary instead of being hidden. Inno Setup extraction
// uses the separately installed innounp helper that Scoop also requires, reported the same way.
struct ExternalTool {
    std::string name;
    std::string purpose;
    std::string policy;
    bool available = false;
    bool enabled = false;
    std::string limitation;
    fs::path path;
};
std::vector<ExternalTool> package_external_tools(const Context& context, const ir::Package& package);
}
