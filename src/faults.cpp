#include "faults.hpp"
#include <optional>
#include <stdexcept>
#include <string_view>
#include <windows.h>

namespace coop {
namespace {
constexpr const char* enabled_variable = "COOP_ALLOW_TEST_FAULTS";
bool environment_allows_faults() {
    wchar_t value[16]{};
    const auto length = GetEnvironmentVariableW(L"COOP_ALLOW_TEST_FAULTS",value,
        static_cast<DWORD>(std::size(value)));
    if (!length || length >= std::size(value)) return false;
    return std::wstring_view(value,length) == L"1";
}
// The fault file is an engineering input, never a product state. Unreadable or malformed content
// disables injection instead of failing the user's operation.
std::optional<Json> fault_file(const Context& context) {
    const auto path = context.root/L".coop"/L"test-faults.json";
    try {
        if (!fs::is_regular_file(path)) return std::nullopt;
        const auto value = read_json(path);
        if (!value.is_object()) return std::nullopt;
        return value;
    } catch (const std::exception&) {
        return std::nullopt;
    }
}
}
bool test_faults_enabled(const Context& context) {
    return environment_allows_faults() && fault_file(context).has_value();
}
void test_fault_point(const Context& context, const std::string& stage) {
    if (!environment_allows_faults()) return;
    const auto plan = fault_file(context);
    if (!plan) return;
    const auto listed = [&](const char* key) {
        if (!plan->contains(key) || !plan->at(key).is_array()) return false;
        for (const auto& item : plan->at(key)) if (item.is_string() && item.get<std::string>() == stage) return true;
        return false;
    };
    // A crash is a real interruption: the process stops without unwinding, destructors or an
    // in-process rollback, exactly like a killed process. The pending journal is the only evidence
    // the next command (or the test) can use.
    if (listed("crash")) TerminateProcess(GetCurrentProcess(),0xC0000409u);
    if (listed("fail"))
        throw std::runtime_error("Injected test fault at stage '"+stage+"' (COOP_ALLOW_TEST_FAULTS=1)");
}
}
