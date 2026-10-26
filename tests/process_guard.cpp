#include <windows.h>
#include <iostream>
#include <string>

// Test tool: report observed process paths as UTF-8 so a test root with non-ASCII characters is
// evidence, not a console-code-page replacement.
static void write_utf8(const std::wstring& text) {
    if (text.empty()) return;
    const int size = WideCharToMultiByte(CP_UTF8,0,text.data(),static_cast<int>(text.size()),nullptr,0,nullptr,nullptr);
    std::string bytes(static_cast<std::size_t>(size),'\0');
    WideCharToMultiByte(CP_UTF8,0,text.data(),static_cast<int>(text.size()),bytes.data(),size,nullptr,nullptr);
    std::cerr << bytes << '\n';
}

// Observe the process tree, distinguishing Windows' console infrastructure.
int wmain(int argc, wchar_t** argv) {
    if (argc < 3) return 2;
    std::wstring command;
    for (int i = 1; i < argc; ++i) {
        command += L'"';
        unsigned slashes = 0;
        for (const auto* character = argv[i]; *character; ++character) {
            if (*character == L'\\') { ++slashes; continue; }
            command.append(*character == L'"' ? slashes * 2 + 1 : slashes, L'\\');
            command += *character;
            slashes = 0;
        }
        command.append(slashes * 2, L'\\');
        command += L"\" ";
    }
    wchar_t windows_directory[MAX_PATH]{};
    if (!GetWindowsDirectoryW(windows_directory, MAX_PATH)) return 1;
    const std::wstring console_host = std::wstring(windows_directory) + L"\\System32\\conhost.exe";
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(argv[1], command.data(), nullptr, nullptr, TRUE,
                        DEBUG_PROCESS | CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process)) {
        std::cerr << "CreateProcess failed: " << GetLastError() << '\n';
        return 1;
    }
    unsigned started = 0;
    unsigned console_hosts = 0;
    DWORD exit_code = 1;
    bool done = false;
    unsigned long timeout = 10000;
    wchar_t configured_timeout[32]{};
    const auto timeout_length = GetEnvironmentVariableW(L"COOP_PROCESS_GUARD_TIMEOUT_MS",configured_timeout,32);
    if (timeout_length && timeout_length < 32) {
        try { timeout = std::stoul(configured_timeout); } catch (...) { timeout = 10000; }
        if (!timeout || timeout > 120000) timeout = 120000;
    }
    // Lifecycle hooks intentionally start a real PowerShell child. This opt-in keeps the
    // observation and the workload exit code while allowing more than one workload process.
    wchar_t configured_allow_children[8]{};
    const auto allow_children = GetEnvironmentVariableW(L"COOP_PROCESS_GUARD_ALLOW_CHILDREN",configured_allow_children,8) &&
        std::wstring(configured_allow_children) == L"1";
    const auto deadline = GetTickCount64()+timeout;
    while (!done) {
        DEBUG_EVENT event{};
        if (!WaitForDebugEvent(&event, 1000)) {
            if (GetLastError() == ERROR_SEM_TIMEOUT && GetTickCount64() < deadline) continue;
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
                    write_utf8(L"Workload process: "+std::wstring(image));
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
    std::cerr << "Observed workload processes: " << started
              << "; Windows console hosts: " << console_hosts << '\n';
    return (started == 1 || (allow_children && started > 1)) && exit_code == 0 ? 0 : 1;
}
