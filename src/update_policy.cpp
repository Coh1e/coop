#include "update_policy.hpp"
#include <algorithm>
#include <optional>
#include <string>
#include <vector>

namespace coop {
namespace {
bool digit(char c) { return c >= '0' && c <= '9'; }
bool identifier(char c) { return digit(c) || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '-'; }
std::vector<std::string_view> split(std::string_view text) {
    std::vector<std::string_view> result;
    while (true) {
        const auto dot = text.find('.');
        result.push_back(text.substr(0,dot));
        if (dot == std::string_view::npos) return result;
        text.remove_prefix(dot+1);
    }
}
bool numeric(std::string_view text) { return !text.empty() && std::all_of(text.begin(),text.end(),digit); }
int number_compare(std::string_view a, std::string_view b) {
    while (a.size() > 1 && a.front() == '0') a.remove_prefix(1);
    while (b.size() > 1 && b.front() == '0') b.remove_prefix(1);
    if (a.size() != b.size()) return a.size() < b.size() ? -1 : 1;
    return a == b ? 0 : a < b ? -1 : 1;
}
struct Version { std::vector<std::string_view> core, pre; };
std::optional<Version> parse(std::string_view text) {
    if (text.empty()) return std::nullopt;
    if (text.front() == 'v') text.remove_prefix(1);
    const bool has_suffix = text.find_first_of("-+") != std::string_view::npos;
    if (const auto plus = text.find('+'); plus != std::string_view::npos) {
        for (const auto part : split(text.substr(plus+1)))
            if (part.empty() || !std::all_of(part.begin(),part.end(),identifier)) return std::nullopt;
        text = text.substr(0,plus);
    }
    Version result;
    if (const auto dash = text.find('-'); dash != std::string_view::npos) {
        result.pre = split(text.substr(dash+1));
        for (const auto part : result.pre)
            if (part.empty() || !std::all_of(part.begin(),part.end(),identifier) ||
                (numeric(part) && part.size() > 1 && part.front() == '0')) return std::nullopt;
        text = text.substr(0,dash);
    }
    result.core = split(text);
    for (const auto part : result.core) if (!numeric(part)) return std::nullopt;
    // A hyphen in an arbitrary numeric label can be a date separator, not a pre-release.
    // Only the standard three-component core makes a suffix eligible for SemVer ordering.
    if (has_suffix && (result.core.size() != 3 || std::any_of(result.core.begin(),result.core.end(),
        [](std::string_view part) { return part.size() > 1 && part.front() == '0'; }))) return std::nullopt;
    return result;
}
}
VersionOrder compare_update_versions(std::string_view installed, std::string_view target) {
    if (installed.empty() || target.empty()) return VersionOrder::unknown;
    if (installed == target) return VersionOrder::equal;
    const auto a = parse(installed), b = parse(target);
    if (!a || !b) return VersionOrder::unknown;
    const auto order = [](int value) { return value < 0 ? VersionOrder::lower : value > 0 ? VersionOrder::higher : VersionOrder::equal; };
    for (std::size_t i = 0; i < std::max(a->core.size(),b->core.size()); ++i) {
        const auto cmp = number_compare(i < b->core.size() ? b->core[i] : "0",i < a->core.size() ? a->core[i] : "0");
        if (cmp) return order(cmp);
    }
    if (a->pre.empty() != b->pre.empty()) return a->pre.empty() ? VersionOrder::lower : VersionOrder::higher;
    for (std::size_t i = 0; i < std::min(a->pre.size(),b->pre.size()); ++i) {
        const auto x = b->pre[i], y = a->pre[i];
        const bool xn = numeric(x), yn = numeric(y);
        const auto cmp = xn && yn ? number_compare(x,y) : xn != yn ? (xn ? -1 : 1) : x == y ? 0 : x < y ? -1 : 1;
        if (cmp) return order(cmp);
    }
    return order(b->pre.size() == a->pre.size() ? 0 : b->pre.size() < a->pre.size() ? -1 : 1);
}
UpdateDecision decide_update(std::string_view installed, std::string_view target, bool changed, bool held, bool force) {
    if (held) return {UpdateState::held,false,true};
    switch (compare_update_versions(installed,target)) {
    case VersionOrder::higher: return {UpdateState::available,true,false};
    case VersionOrder::equal: return {changed ? UpdateState::manifest_changed : UpdateState::current,force,false};
    case VersionOrder::lower: return {UpdateState::downgrade,false,true};
    case VersionOrder::unknown: return {UpdateState::incomparable,false,true};
    }
    return {};
}
const char* update_state_name(UpdateState state) {
    switch (state) {
    case UpdateState::available: return "update-available";
    case UpdateState::current: return "current";
    case UpdateState::manifest_changed: return "manifest-changed";
    case UpdateState::downgrade: return "downgrade-blocked";
    case UpdateState::incomparable: return "version-incomparable";
    case UpdateState::held: return "held-package";
    }
    return "version-incomparable";
}
const char* update_state_message(UpdateState state) {
    switch (state) {
    case UpdateState::available: return "A higher version is available";
    case UpdateState::current: return "No update is needed";
    case UpdateState::manifest_changed: return "Same-version manifest changed; use --force to reinstall";
    case UpdateState::downgrade: return "Target version is lower; update refuses to downgrade (including --force)";
    case UpdateState::incomparable: return "Cannot reliably compare versions; update is blocked (including --force)";
    case UpdateState::held: return "Package is held; use coop unhold before updating (including --force)";
    }
    return "Cannot determine update eligibility";
}
}
