#pragma once
#include "data.hpp"
#include <string>

namespace coop {
// Engineering-only interruption points used by the recovery test matrix. They are disabled
// unless both of the following hold for the current process and selected root:
//   * COOP_ALLOW_TEST_FAULTS=1 is present in this process environment;
//   * test-faults.json in the Coop state directory is a regular, readable JSON object.
// The file lists stage names under "fail" (raise an exception after the journaled write, so the
// normal in-process rollback runs) or "crash" (terminate the process without unwinding, leaving a
// real pending transaction). No other code path reads the file, an absent file is a no-op, and
// normal user operations never create it. A fault only reproduces a failure at a stage the
// product already reaches; it does not replace evidence from real mechanisms.
bool test_faults_enabled(const Context& context);
void test_fault_point(const Context& context, const std::string& stage);
}
