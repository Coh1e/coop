#pragma once
#include <string_view>

namespace coop {
enum class VersionOrder { lower, equal, higher, unknown };
// The target's order relative to the installed version. Unsupported distinct spellings are unknown.
VersionOrder compare_update_versions(std::string_view installed, std::string_view target);
enum class UpdateState { available, current, manifest_changed, downgrade, incomparable, held };
struct UpdateDecision {
    UpdateState state = UpdateState::incomparable;
    bool changes_installation = false;
    bool blocked = true;
};
UpdateDecision decide_update(std::string_view installed, std::string_view target,
                             bool manifest_changed, bool held, bool force = false);
const char* update_state_name(UpdateState state);
const char* update_state_message(UpdateState state);
}
