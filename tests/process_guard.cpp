#include <windows.h>
#include <iostream>
#include <string>

// Observe the process tree, distinguishing Windows' console infrastructure.
int wmain(int argc, wchar_t** argv) {
    if (argc != 3) return 2;
    std::wstring command = L"\"" + std::wstring(argv[1]) + L"\" " + argv[2];
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(argv[1], command.data(), nullptr, nullptr, TRUE,
                        DEBUG_PROCESS | CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process)) {
        std::cerr << "CreateProcess failed: " << GetLastError() << '\n';
        return 1;
    }
    unsigned started = 0;
    unsigned console_hosts = 0;
    wchar_t windows_directory[MAX_PATH]{};
    if (!GetWindowsDirectoryW(windows_directory, MAX_PATH)) return 1;
    const std::wstring console_host = std::wstring(windows_directory) + L"\\System32\\conhost.exe";
    DWORD exit_code = 1;
    bool done = false;
    while (!done) {
        DEBUG_EVENT event{};
        if (!WaitForDebugEvent(&event, 10000)) {
            TerminateProcess(process.hProcess, 1);
            CloseHandle(process.hThread);
            CloseHandle(process.hProcess);
            std::cerr << "Timed out waiting for debuggee\n";
            return 1;
        }
        DWORD continuation = DBG_CONTINUE;
        switch (event.dwDebugEventCode) {
        case CREATE_PROCESS_DEBUG_EVENT:
            {
                wchar_t image[MAX_PATH]{};
                DWORD length = MAX_PATH;
                if (QueryFullProcessImageNameW(event.u.CreateProcessInfo.hProcess, 0, image, &length) &&
                    CompareStringOrdinal(image, -1, console_host.c_str(), -1, TRUE) == CSTR_EQUAL) {
                    ++console_hosts;
                } else {
                    ++started;
                    std::wcerr << L"Workload process: " << image << L'\n';
                }
            }
            if (event.u.CreateProcessInfo.hFile) CloseHandle(event.u.CreateProcessInfo.hFile);
            break;
        case LOAD_DLL_DEBUG_EVENT:
            if (event.u.LoadDll.hFile) CloseHandle(event.u.LoadDll.hFile);
            break;
        case EXCEPTION_DEBUG_EVENT:
            if (event.u.Exception.ExceptionRecord.ExceptionCode != EXCEPTION_BREAKPOINT)
                continuation = DBG_EXCEPTION_NOT_HANDLED;
            break;
        case EXIT_PROCESS_DEBUG_EVENT:
            if (event.dwProcessId == process.dwProcessId) {
                exit_code = event.u.ExitProcess.dwExitCode;
                done = true;
            }
            break;
        default: break;
        }
        ContinueDebugEvent(event.dwProcessId, event.dwThreadId, continuation);
    }
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    std::cout << "Observed workload processes: " << started
              << "; Windows console hosts: " << console_hosts << '\n';
    return started == 1 && exit_code == 0 ? 0 : 1;
}
