#pragma once
#include "data.hpp"

namespace coop {
Json prepare_git_bucket(const Context& context, const std::string& name, const std::string& url,
                        const std::string& branch, const std::string& revision, const Json* previous);
Json inspect_scoop_bucket(const Context& context, const std::string& name);
}
