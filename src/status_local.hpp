#pragma once
#include "operation_result.hpp"
#include "app.hpp"
namespace coop {
// Reads local installation/source evidence only. Never fetches, migrates state or creates caches.
OperationResult local_status_report(const Context& context);
}
