#pragma once
#include "app.hpp"
#include <string>
#include <vector>

namespace coop {
// Establishes the standard Scoop-compatible directory layout in the selected root. It only creates
// missing standard directories, never modifies existing content, never touches the user
// environment and never starts an external process.
int init_command(const Context& context, const std::vector<std::wstring>& args);
}
