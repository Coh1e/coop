// Red when: inspection and update results diverge, required failures are hidden, or stage counts
// are mixed into object counts. Exercises the shared result interface without a CLI-only adapter.
#include "operation_result.hpp"
#include "data.hpp"
#include <iostream>

static void check(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
int main() {
    try {
        coop::OperationResult report;
        report.request.operation = coop::OperationKind::update;
        report.request.dry_run = true;
        report.request.targets = {"demo"};
        coop::ResultItem client;
        client.name = "coop"; client.scope = "process"; client.reason = "local-only";
        report.clients.push_back(client);
        auto value = coop::operation_result_json(report);
        check(value.at("command") == "update" && value.at("request").at("dry_run") == true &&
            value.at("request").at("targets").at(0) == "demo", "Shared request lost update identity");
        check(value.at("summary").at("complete") == true && coop::operation_result_exit_code(report) == 0,
            "Intentionally unchecked item treated as failure");
        coop::ResultItem app;
        app.name = "demo"; app.scope = "user"; app.state = coop::ResultState::attention;
        app.data = {{"installed_version",std::string("1")},{"manifest_version",std::string("2")}};
        report.apps.push_back(app);
        value = coop::operation_result_json(report);
        check(value.at("summary").at("state") == "attention" && value.at("summary").at("complete") == true,
            "Known issue confused with incomplete inspection");
        for (const auto state : {coop::ResultState::failed,coop::ResultState::blocked,coop::ResultState::partial}) {
            app.state = state;
            report.stages = {app};
            value = coop::operation_result_json(report);
            check(coop::operation_result_exit_code(report) == 1 && value.at("summary").at("complete") == false,
                "Required stage failure hidden");
            check(value.at("summary").at("counts").at("attention") == 1 &&
                value.at("apps").at(0).at("data").at("installed_version") == "1", "Stage modified independent object results");
        }
        report.stages.clear();
        report.diagnostics.push_back({"source-unreadable","fixture"});
        check(coop::operation_result_exit_code(report) == 1 &&
            coop::operation_result_json(report).at("summary").at("state") == "failed", "Report diagnostic hidden");
        std::cout << "PASS shared inspection/update requests, independent items and stage failure aggregation\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
