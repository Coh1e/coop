#pragma once
#include "app.hpp"
#include "ir.hpp"
#include <nlohmann/json.hpp>

namespace coop {
using Json = nlohmann::json;
Json read_json(const fs::path& path);
fs::path installed_record(const fs::path& directory, const std::wstring& kind);
Json installed_packages(const Context& context);
Json catalog(const Context& context);
// Typed catalogue entries for the planner: the package identity the adapter published, never a
// raw Manifest field read by the planner itself.
std::vector<ir::CatalogueEntry> catalogue(const Context& context);
Json bucket_sources(const Context& context);
void write_json(const fs::path& path, const Json& value, bool compact = false);
// Removes a Coop-managed tree. Reparse points are unlinked instead of followed, and the read-only
// attribute Scoop keeps on persist junctions (attrib +R /L) is cleared before unlinking.
void erase_tree(const fs::path& path);
void validate_component(const std::string& value);
class RootLock {
public:
    explicit RootLock(const fs::path& root);
    ~RootLock();
    RootLock(const RootLock&) = delete;
    RootLock& operator=(const RootLock&) = delete;
private:
    void* handle_;
};
}
