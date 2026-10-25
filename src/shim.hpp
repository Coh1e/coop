#pragma once
namespace coop {
// A copied coop launcher reads its .coop-shim.json metadata and forwards the call to the
// declared target with the correct host for the target type. Returns false when the running
// executable is not a command launcher.
bool run_shim(int argc, wchar_t** argv, int& result);
}
