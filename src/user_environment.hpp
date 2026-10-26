#pragma once
#include "data.hpp"

namespace coop {
// Current-user environment persistence. Coop writes only HKCU\Environment, records the raw
// values it replaced, and broadcasts WM_SETTINGCHANGE("Environment") so new terminals and normal
// shell launches read the same values instead of receiving an injected child environment.
//
// The returned object has this shape:
//   ownership  evidence to store in the package record for a later update/uninstall
//   undo       exact before/expected values for in-process transaction rollback
//   writes     per-value before/after details
//   preserved  values a user changed after Coop wrote them and Coop therefore left alone
//   broadcast  SendMessageTimeout result for the live environment notification
//
// `environment` is the already expanded env_set list (name/value objects) and `path_entries` is
// the already expanded env_add_path list. Declarations the installed package owned but the new
// manifest no longer declares are reverted during the same reconcile.
Json apply_user_environment(const Json& environment, const Json& path_entries, const Json& previous_ownership);
// Revert every value the installed package still owns. A value changed by the user is preserved
// and reported. Used by uninstall and by an update that no longer declares any environment.
Json revert_user_environment(const Json& previous_ownership);
// Undo one apply/revert result if the current raw values still match what that operation wrote.
// Otherwise leaves the user's newer value untouched and reports the conflict.
Json restore_user_environment(const Json& undo);
}
