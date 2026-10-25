#pragma once
#include "data.hpp"
#include <vector>

namespace coop {
// Old-version evidence is always derived from local files and Coop's own records. Missing
// historical manifests are reported as missing; this module never reconstructs a download URL.
Json version_evidence(const fs::path& directory, const std::string& version);
// Records local file metadata without following reparse points. It detects ordinary later
// modifications to an old version directory without hashing or traversing persisted stores.
std::string version_tree_stamp(const fs::path& directory);
Json scan_version_evidence(const fs::path& app_directory);
Json recorded_version_evidence(const Context& context, const std::string& package_name);
Json version_cleanup_inventory(const Context& context, const std::string& package_name,
                               const std::string& current_version);
int cleanup_command(const Context& context, const std::vector<std::wstring>& names, bool dry_run);
Json cleanup_recovery_status(const Context& context, const fs::path& journal_path, bool execute);
}
