#pragma once
#include "data.hpp"
#include <vector>

namespace coop {
// A pending transaction is reported from its journal only. Recovery never infers success
// from the absence of a process and never re-runs lifecycle scripts.
Json pending_recovery_report(const Context& context, bool execute);
int recovery_command(const Context& context, const std::vector<std::wstring>& args);
}
