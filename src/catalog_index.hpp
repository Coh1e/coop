#pragma once
#include "data.hpp"

namespace coop {
// Searchable bucket metadata is a rebuildable index. It is written only by explicit bucket
// synchronization, and reads validate it against the published source (Git revision or a
// metadata fingerprint), so a query never presents metadata from another revision.
Json catalog_entries(const Context& context, const Json& source);
// Full local inspection needs the actual worktree, including uncommitted changes and parse errors.
// This read-only path never consults or rewrites the rebuildable index.
Json scan_catalog_entries(const Json& source);
bool catalog_index_valid(const Context& context, const Json& source);
void write_catalog_index(const Context& context, const Json& source);
}
