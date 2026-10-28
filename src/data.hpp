#pragma once
#include "app.hpp"
#include "ir.hpp"
#include <nlohmann/json.hpp>

namespace coop {
using Json = nlohmann::json;
Json read_json(const fs::path& path);
fs::path installed_record(const fs::path& directory, const std::wstring& kind);
Json installed_packages(const Context& context);
// Typed catalogue entries for the planner: the package identity the adapter published, never a
// raw Manifest field read by the planner itself.
std::vector<ir::CatalogueEntry> catalogue(const Context& context);
Json bucket_sources(const Context& context);
// durable=false skips the write-through flush for high-frequency records that a crash can re-derive;
// the commit points (version publish, current switch, install record) keep the durable default.
void write_json(const fs::path& path, const Json& value, bool compact = false, bool durable = true);
// Counts the write-through flushes performed in this process, so a test can assert that a whole
// extraction no longer syncs once per file.
std::uint64_t durable_syncs();
void note_durable_sync();
// Write-through flush that the counter sees. Every durability decision goes through it, so a test can
// tell "we stopped flushing per file" from "we started again".
bool durable_flush(void* file);
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
