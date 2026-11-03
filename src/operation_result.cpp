#include "operation_result.hpp"
#include "data.hpp"

namespace coop {
const char* result_state_name(ResultState state) {
    switch (state) {
    case ResultState::ok: return "ok";
    case ResultState::attention: return "attention";
    case ResultState::not_checked: return "not_checked";
    case ResultState::not_applicable: return "not_applicable";
    case ResultState::failed: return "failed";
    case ResultState::blocked: return "blocked";
    case ResultState::partial: return "partial";
    }
    throw std::logic_error("Unknown operation result state");
}
namespace {
bool failed(const ResultItem& item) {
    return item.state == ResultState::failed || item.state == ResultState::blocked ||
        item.state == ResultState::partial || !item.diagnostics.empty();
}
Json diagnostics_json(const std::vector<ResultDiagnostic>& diagnostics) {
    auto result = Json::array();
    for (const auto& item : diagnostics) result.push_back({{"code",item.code},{"message",item.message}});
    return result;
}
Json items_json(const std::vector<ResultItem>& items) {
    auto result = Json::array();
    for (const auto& item : items) {
        auto data = Json::object();
        for (const auto& [name,value] : item.data) std::visit([&](const auto& field) { data[name] = field; },value);
        result.push_back({{"name",item.name},{"scope",item.scope},
            {"state",result_state_name(item.state)},{"reason",item.reason},{"data",data},
            {"diagnostics",diagnostics_json(item.diagnostics)}});
    }
    return result;
}
}
int operation_result_exit_code(const OperationResult& report) {
    if (!report.diagnostics.empty()) return 1;
    for (const auto* group : {&report.clients,&report.buckets,&report.apps,&report.stages})
        for (const auto& item : *group) if (failed(item)) return 1;
    return 0;
}
Json operation_result_json(const OperationResult& report) {
    Json counts = {{"ok",0},{"attention",0},{"not_checked",0},{"not_applicable",0},
        {"failed",0},{"blocked",0},{"partial",0}};
    bool attention = false;
    for (const auto* group : {&report.clients,&report.buckets,&report.apps})
        for (const auto& item : *group) {
            ++counts[result_state_name(item.state)].get_ref<Json::number_integer_t&>();
            attention = attention || item.state == ResultState::attention;
        }
    for (const auto& item : report.stages) attention = attention || item.state == ResultState::attention;
    const bool complete = operation_result_exit_code(report) == 0;
    return {{"schema_version",2},{"command",report.request.operation == OperationKind::status ? "status" : "update"},
        {"scope",report.request.local_only ? "local" : "remote"},
        {"request",{{"local_only",report.request.local_only},{"dry_run",report.request.dry_run},{"targets",report.request.targets}}},
        {"clients",items_json(report.clients)},{"buckets",items_json(report.buckets)},{"apps",items_json(report.apps)},
        {"stages",items_json(report.stages)},{"diagnostics",diagnostics_json(report.diagnostics)},
        {"summary",{{"state",!complete ? "failed" : attention ? "attention" : "ok"},{"complete",complete},{"counts",counts}}}};
}
}
