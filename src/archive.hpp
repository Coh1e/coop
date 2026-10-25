#pragma once
#include "package.hpp"

namespace coop {
// Extract a ZIP, tar or 7z archive into an empty, Coop-owned directory.
// Entry paths are validated before any file is written; link entries are rejected.
void extract_archive(const fs::path& archive, const fs::path& destination);
// Move the contents below an optional extract_dir into the package staging directory.
void merge_archive_tree(const fs::path& source, const fs::path& extract_directory, const fs::path& destination);
}
