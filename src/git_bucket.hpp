#pragma once
#include "data.hpp"

namespace coop {
// Refreshes the shared bucket that Scoop itself uses at <root>/buckets/<name>.
// A null previous record performs the first refresh (clone); an existing record refreshes the
// working tree in place. Both paths use the embedded Git library and never start git.exe.
Json prepare_git_bucket(const Context& context, const std::string& name, const std::string& url,
                        const std::string& branch, const std::string& revision, const Json* previous);
// Reads an existing unmanaged shared Git bucket without changing it.
Json inspect_scoop_bucket(const Context& context, const std::string& name);
}
