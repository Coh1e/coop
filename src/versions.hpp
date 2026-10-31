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
// A listing asks for every installed package's old versions at once. The transaction directory can
// hold many settled journals, so scanning it once per package made `list` cost grow with the whole
// history. The caller computes the predicate once and every package reuses it read-only.
Json version_cleanup_inventory(const Context& context, const std::string& package_name,
                               const std::string& current_version, bool recovery_protected);
int cleanup_command(const Context& context, const std::vector<std::wstring>& names, bool dry_run,
                    bool cache = false);
// Trims the evidence of finished write transactions (`cleanup --transactions`), keeping the newest ten
// and never touching a pending one.
int cleanup_transactions(const Context& context, bool dry_run);
Json cleanup_recovery_status(const Context& context, const fs::path& journal_path, bool execute);
}
