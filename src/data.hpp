#pragma once
#include "app.hpp"
#include "ir.hpp"
#include <nlohmann/json.hpp>

namespace coop {
using Json = nlohmann::json;
Json read_json(const fs::path& path);
fs::path installed_record(const fs::path& directory, const std::wstring& kind);
Json installed_packages(const Context& context);
// Coop's private state lives outside the Scoop root: %USERPROFILE%\.coop\roots\<root>-<hash> by
// default. COOP_STATE_DIR overrides it and expands %ROOT% per invocation, which is how the test
// suite pins each test root without rewriting every <root>/.coop reference.
fs::path state_directory(const Context& context);
fs::path state_directory_for_root(const fs::path& root);
fs::path state_cache_directory(const Context& context);
// First-run move of a legacy <root>/.coop into the state directory. A no-op when COOP_STATE_DIR
// already points at the legacy path; failures keep the old directory and only warn.
void migrate_legacy_state(const Context& context);
// Move a file or directory, falling back to copy + delete when source and destination are on
// different volumes. Junction targets are rebuilt at the destination, never followed.
void move_tree(const fs::path& source, const fs::path& destination);
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
    explicit RootLock(const Context& context);
    ~RootLock();
    RootLock(const RootLock&) = delete;
    RootLock& operator=(const RootLock&) = delete;
private:
    void* handle_;
    fs::path state_;
};
}
