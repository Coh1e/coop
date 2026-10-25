#include <windows.h>
#include <string>

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    wchar_t marker[32768]{};
    const auto length = GetEnvironmentVariableW(L"GUI_FIXTURE_MARKER", marker, static_cast<DWORD>(sizeof(marker)/sizeof(marker[0])));
    if (length && length < sizeof(marker)/sizeof(marker[0])) {
        HANDLE file = CreateFileW(marker, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file != INVALID_HANDLE_VALUE) {
            const std::string text = "gui fixture ran";
            DWORD written = 0;
            WriteFile(file, text.data(), static_cast<DWORD>(text.size()), &written, nullptr);
            CloseHandle(file);
        }
    }
    Sleep(300);
    return 5;
}
