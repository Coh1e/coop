#pragma once
#include <cstddef>
#include <map>
#include <string>
#include <variant>
#include <vector>

namespace coop {
// One request/result vocabulary for inspection and the later update coordinator. The data object
// carries object-specific facts; state/reason/diagnostics have the same meaning in every group.
enum class OperationKind { status, update };
enum class ResultState { ok, attention, not_checked, not_applicable, failed, blocked, partial };
struct OperationRequest {
    OperationKind operation = OperationKind::status;
    bool local_only = false;
    bool dry_run = false;
    std::vector<std::string> targets;
};
struct ResultDiagnostic { std::string code; std::string message; };
using ResultValue = std::variant<std::nullptr_t,std::string,bool,std::size_t,std::vector<std::string>>;
using ResultData = std::map<std::string,ResultValue>;
struct ResultItem {
    std::string name;
    std::string scope;
    ResultState state = ResultState::not_checked;
    std::string reason;
    ResultData data;
    std::vector<ResultDiagnostic> diagnostics;
};
struct OperationResult {
    OperationRequest request;
    std::vector<ResultItem> clients, buckets, apps, stages;
    std::vector<ResultDiagnostic> diagnostics;
};
const char* result_state_name(ResultState state);
int operation_result_exit_code(const OperationResult& report);
}
