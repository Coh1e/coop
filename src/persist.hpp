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
bool same_persistence(const Package& a, const Package& b);
std::vector<std::string> retained_versions(const Context& context, const std::string& package_name,
                                           const std::string& current_version);
}
