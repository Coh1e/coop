#pragma once
#include "operation_result.hpp"
#include "data.hpp"
namespace coop {
// Reads local installation/source evidence only. Never fetches, migrates state or creates caches.
Json status_bucket_sources(const Context& context, std::vector<ResultDiagnostic>& diagnostics);
void read_local_status(const Context& context, const Json& sources, OperationResult& report);
}
