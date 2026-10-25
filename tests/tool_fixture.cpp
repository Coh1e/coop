// Test-only external-tool stand-in. It never installs anything and is only used with
// COOP_MSIEXEC to observe argument handling and non-zero exit propagation.
#include <windows.h>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>

int wmain(int argc, wchar_t** argv) {
    wchar_t configured[16]{};
    int exit_code = 0;
    if (GetEnvironmentVariableW(L"COOP_FIXTURE_TOOL_EXIT", configured, static_cast<DWORD>(std::size(configured))))
        exit_code = _wtoi(configured);
    std::filesystem::path target;
    for (int index = 1; index < argc; ++index) {
        const std::wstring argument = argv[index];
        const std::wstring prefix = L"TARGETDIR=";
        if (argument.rfind(prefix, 0) == 0) target = argument.substr(prefix.size());
    }
    if (target.empty()) return 2;
    std::error_code error;
    std::filesystem::create_directories(target, error);
    if (error) return 3;
    std::ofstream marker(target / L"partial.txt", std::ios::binary | std::ios::trunc);
    marker << "fixture tool ran\n";
    if (!marker) return 4;
    return exit_code;
}
