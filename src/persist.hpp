#pragma once
#include "package.hpp"
#include "data.hpp"

namespace coop {
// Persistence mappings are package-relative: source lives in the version directory and
// target lives under <root>/persist/<package>/. Directories use junctions, files use hardlinks,
// matching the fixed Scoop implementation. Normal uninstall removes links only; stored data stays.
Json persistence_plan_json(const Context& context, const Package& package, const fs::path& version_directory);
Json prepare_persistence(const Context& context, const Package& package, const fs::path& stage_directory);
Json verify_persistence(const Context& context, const Package& package, const fs::path& version_directory);
// Purge is a separate, explicit operation. Its scope is only the declared store targets, never
// the whole persist/package directory, and each target must still match the ownership and
// filesystem identity observed when the plan was verified.
Json purge_scope(const Context& context, const Package& package, const fs::path& version_directory,
                 const Json& recorded_persistence);
bool verify_purge_target(const Context& context, const std::string& package_name, const Json& entry);
bool same_persistence(const Package& a, const Package& b);
std::vector<std::string> retained_versions(const Context& context, const std::string& package_name,
                                           const std::string& current_version);
}
