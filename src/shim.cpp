#include "shim.hpp"
#include "exposure.hpp"
#include "data.hpp"
#include <windows.h>
#include <array>
#include <stdexcept>

namespace coop {
namespace {
std::wstring quote(const std::wstring& argument) {
    std::wstring result = L"\"";
    std::size_t slashes = 0;
    for (const auto c : argument) {
        if (c == L'\\') { ++slashes; continue; }
        if (c == L'\"') result.append(slashes*2+1,L'\\');
        else result.append(slashes,L'\\');
        slashes = 0;
        result += c;
    }
    result.append(slashes*2,L'\\');
    return result+L'\"';
}
std::wstring environment_variable(const wchar_t* name) {
    std::array<wchar_t,32768> buffer{};
    const auto length = GetEnvironmentVariableW(name,buffer.data(),static_cast<DWORD>(buffer.size()));
    if (!length || static_cast<std::size_t>(length) >= buffer.size()) return {};
    return std::wstring(buffer.data(),length);
}
fs::path search_tool(const wchar_t* name) {
    std::array<wchar_t,32768> buffer{};
    const auto length = SearchPathW(nullptr,name,nullptr,static_cast<DWORD>(buffer.size()),buffer.data(),nullptr);
    if (!length || static_cast<std::size_t>(length) >= buffer.size()) return {};
    return fs::path(buffer.data());
}
fs::path java_executable() {
    const auto home = environment_variable(L"JAVA_HOME");
    if (!home.empty()) {
        const auto candidate = fs::path(home)/L"bin"/L"java.exe";
        if (fs::is_regular_file(candidate)) return candidate;
    }
    const auto found = search_tool(L"java.exe");
    if (!found.empty()) return found;
    throw std::runtime_error("Java runtime not found for the JAR command entry; set JAVA_HOME or add java.exe to PATH");
}
fs::path powershell_executable() {
    const auto found = search_tool(L"pwsh.exe");
    if (!found.empty()) return found;
    std::array<wchar_t,32768> windows{};
    const auto length = GetWindowsDirectoryW(windows.data(),static_cast<UINT>(windows.size()));
    if (length && static_cast<std::size_t>(length) < windows.size()) {
        const auto legacy = fs::path(windows.data())/L"System32"/L"WindowsPowerShell"/L"v1.0"/L"powershell.exe";
        if (fs::is_regular_file(legacy)) return legacy;
    }
    throw std::runtime_error("PowerShell not found for the PS1 command entry");
}
fs::path command_interpreter() {
    const auto comspec = environment_variable(L"ComSpec");
    if (!comspec.empty() && fs::is_regular_file(comspec)) return fs::path(comspec);
    std::array<wchar_t,32768> windows{};
    const auto length = GetWindowsDirectoryW(windows.data(),static_cast<UINT>(windows.size()));
    if (length && static_cast<std::size_t>(length) < windows.size())
        return fs::path(windows.data())/L"System32"/L"cmd.exe";
    throw std::runtime_error("Command interpreter not found for a BAT/CMD command entry");
}
void apply_environment(const Json& record) {
    if (record.contains("path_entries") && record.at("path_entries").is_array()) {
        std::wstring prefix;
        for (const auto& entry : record.at("path_entries")) {
            if (!entry.is_string()) continue;
            if (!prefix.empty()) prefix += L';';
            prefix += wide(entry.get<std::string>());
        }
        if (!prefix.empty()) {
            const auto current = environment_variable(L"PATH");
            const auto combined = current.empty() ? prefix : prefix+L';'+current;
            SetEnvironmentVariableW(L"PATH",combined.c_str());
        }
    }
    if (record.contains("environment") && record.at("environment").is_array()) {
        for (const auto& setting : record.at("environment")) {
            if (!setting.is_object()) continue;
            const auto name = wide(setting.value("name",std::string{}));
            const auto value = wide(setting.value("value",std::string{}));
            if (name.empty()) continue;
            SetEnvironmentVariableW(name.c_str(),value.c_str());
        }
    }
}
}
bool run_shim(int argc, wchar_t** argv, int& result) {
    std::array<wchar_t,32768> module{};
    const auto length = GetModuleFileNameW(nullptr,module.data(),static_cast<DWORD>(module.size()));
    if (!length || length >= module.size()) throw std::runtime_error("Cannot locate command executable");
    const auto launcher = fs::path(module.data());
    const auto metadata = launcher.parent_path()/(launcher.stem().wstring()+L".coop-shim.json");
    if (!fs::exists(metadata)) return false;
    const auto record = read_json(metadata);
    const auto target = wide(record.at("target").get<std::string>());
    const auto kind = record.value("launcher",std::string("direct"));
    const auto defaults = wide(record.value("arguments",std::string{}));
    std::wstring forwarded;
    if (!defaults.empty()) forwarded = L" "+defaults;
    for (int index = 1; index < argc; ++index) {
        forwarded += L" ";
        forwarded += quote(argv[index]);
    }
    fs::path application;
    std::wstring command;
    fs::path working_directory;
    if (kind == "direct") {
        application = target;
        command = quote(target)+forwarded;
    } else if (kind == "cmd") {
        application = command_interpreter();
        command = quote(application.wstring())+L" /d /s /c \""+quote(target)+forwarded+L"\"";
    } else if (kind == "powershell") {
        application = powershell_executable();
        command = quote(application.wstring())+L" -NoProfile -ExecutionPolicy Unrestricted -File "+quote(target)+forwarded;
    } else if (kind == "java") {
        application = java_executable();
        command = quote(application.wstring())+L" -jar "+quote(target)+forwarded;
        working_directory = fs::path(target).parent_path();
    } else {
        throw std::runtime_error("Command entry launcher type is not supported: "+kind);
    }
    apply_environment(record);
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(application.c_str(),command.data(),nullptr,nullptr,TRUE,0,nullptr,
        working_directory.empty() ? nullptr : working_directory.c_str(),&startup,&process))
        throw std::runtime_error("Command target cannot be started (Windows error "+std::to_string(GetLastError())+")");
    CloseHandle(process.hThread);
    WaitForSingleObject(process.hProcess,INFINITE);
    DWORD exit_code = 1;
    GetExitCodeProcess(process.hProcess,&exit_code);
    CloseHandle(process.hProcess);
    result = static_cast<int>(exit_code);
    return true;
}
}
