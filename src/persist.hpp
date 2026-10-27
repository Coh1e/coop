#pragma once
#include "package.hpp"
#include "ir.hpp"
namespace coop {
// Persistence mappings are package-relative: source lives in the version directory and
// target lives under <root>/persist/<package>/. Directories use junctions, files use hardlinks,
// exactly like Scoop, so the other client keeps recognizing the installed data.
Json persistence_plan_json(const Context& context, const std::string& package_name,
                           const std::vector<ir::PersistenceMapping>& mappings, const fs::path& version_directory);
Json prepare_persistence(const Context& context, const ir::Package& package, const fs::path& stage_directory);
Json verify_persistence(const Context& context, const ir::Package& package, const fs::path& version_directory);
// The purge scope is derived from the installed package's own declarations and the actual links,
// never from a Coop private record: an installation the other client created has the same rights
// and the same verification.
Json purge_scope(const Context& context, const ir::Package& package, const fs::path& version_directory);
bool same_persistence(const ir::Package& a, const ir::Package& b);
bool verify_purge_target(const Context& context, const std::string& package_name, const Json& entry);
std::vector<std::string> retained_versions(const Context& context, const std::string& package_name,
                                           const std::string& current_version);
}
