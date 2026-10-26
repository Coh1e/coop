#include "shim.hpp"
#include "exposure.hpp"
#include "data.hpp"
#include <windows.h>
#include <array>
#include <cctype>
#include <stdexcept>
#include <fstream>
#include <set>

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
std::string trim_text(std::string value) {
    const auto first = value.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) return {};
    return value.substr(first,value.find_last_not_of(" \t\r\n")-first+1);
}
// A shared shim lives at <root>/shims/<name>.shim. Its target names the package under
// <root>/apps/<package>/, so the optional Coop record (environment/path entries) can be found
// without adding non-Scoop keys to the shim file.
fs::path record_for_target(const fs::path& target) {
    std::vector<fs::path> parts;
    for (const auto& part : target) parts.push_back(part);
    for (std::size_t index = 0; index + 1 < parts.size(); ++index) {
        const auto name = parts[index].wstring();
        if (CompareStringOrdinal(name.c_str(),-1,L"apps",-1,TRUE) != CSTR_EQUAL) continue;
        fs::path root;
        for (std::size_t prefix = 0; prefix <= index; ++prefix) root /= parts[prefix];
        return root.parent_path()/L".coop"/L"packages"/(parts[index+1].wstring()+L".json");
    }
    return {};
}
}
ShimMetadata read_shim_metadata(const fs::path& path) {
    std::error_code error;
    const auto size = fs::file_size(path,error);
    if (error) throw std::runtime_error("Cannot read Scoop command metadata");
    if (size > 16384) throw std::runtime_error("Scoop shim metadata exceeds size limit");
    std::ifstream input(path,std::ios::binary);
    if (!input) throw std::runtime_error("Cannot read Scoop command metadata");
    ShimMetadata result;
    std::string line;
    std::set<std::string> keys;
    while (std::getline(input,line)) {
        if (line.starts_with("\xef\xbb\xbf")) line.erase(0,3);
        line = trim_text(line);
        if (line.empty() || line.starts_with('#') || line.starts_with(';') || line.starts_with("//")) continue;
        const auto equal = line.find('=');
        if (equal == std::string::npos) throw std::runtime_error("Invalid Scoop shim metadata line");
        const auto key = trim_text(line.substr(0,equal));
        const auto value = trim_text(line.substr(equal+1));
        if (!keys.insert(key).second) throw std::runtime_error("Duplicate Scoop shim metadata key");
        if (key == "path") result.target = value;
        else if (key == "args") result.arguments = value;
        else result.unknown_keys.push_back(key);
    }
    if (result.target.size() >= 2 && result.target.front() == '"' && result.target.back() == '"')
        result.target = result.target.substr(1,result.target.size()-2);
    if (result.target.empty()) throw std::runtime_error("Scoop shim metadata has no target path");
    return result;
}
bool looks_like_scoop_shim(const fs::path& path) {
    std::error_code error;
    const auto size = fs::file_size(path,error);
    if (error || size < 64 || size > 8*1024*1024) return false;
    std::ifstream input(path,std::ios::binary);
    if (!input) return false;
    std::string bytes(static_cast<std::size_t>(size),'\0');
    input.read(bytes.data(),static_cast<std::streamsize>(bytes.size()));
    if (!input && !input.eof()) return false;
    if (bytes.size() < 2 || bytes[0] != 'M' || bytes[1] != 'Z') return false;
    static const char* markers[] = {
        "Cannot open shim file for read.",
        "Could not read shim file.",
        "Scoop helper program for shimming executables.",
        "Shim: Could not create process with command"
    };
    for (const auto* marker : markers)
        if (bytes.find(marker) != std::string::npos) return true;
    return false;
}

bool scoop_wrapper_belongs_to_package(const fs::path& path, const std::string& package_name) {
    const auto attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY) ||
        (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) return false;
    std::error_code error;
    const auto size = fs::file_size(path,error);
    if (error || size == 0 || size > 1024*1024 || !fs::is_regular_file(path,error)) return false;
    std::ifstream input(path,std::ios::binary);
    if (!input) return false;
    std::string text(static_cast<std::size_t>(size),'\0');
    input.read(text.data(),static_cast<std::streamsize>(text.size()));
    if (!input && !input.eof()) return false;
    auto lower = [](std::string value) {
        for (auto& character : value) character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
        return value;
    };
    text = lower(std::move(text));
    const auto name = lower(package_name);
    return text.find("apps\\"+name+"\\") != std::string::npos ||
        text.find("apps/"+name+"/") != std::string::npos;
}
std::vector<fs::path> scoop_entry_wrappers(const Context& context, const std::string& package_name,
    const std::vector<std::string>& command_names) {
    std::vector<fs::path> result;
    std::set<std::string> seen;
    const auto shims = context.root/L"shims";
    for (const auto& name : command_names) {
        for (const auto& candidate : {shims/(wide(name)+L".cmd"),shims/(wide(name)+L".ps1"),shims/wide(name)}) {
            if (!scoop_wrapper_belongs_to_package(candidate,package_name)) continue;
            if (!seen.insert(path_text(candidate)).second) continue;
            result.push_back(candidate);
        }
    }
    return result;
}

bool run_shim(int argc, wchar_t** argv, int& result) {
    std::array<wchar_t,32768> module{};
    const auto length = GetModuleFileNameW(nullptr,module.data(),static_cast<DWORD>(module.size()));
    if (!length || length >= module.size()) throw std::runtime_error("Cannot locate command executable");
    const auto launcher = fs::path(module.data());
    const auto coop_metadata = launcher.parent_path()/(launcher.stem().wstring()+L".coop-shim.json");
    const auto scoop_metadata = launcher.parent_path()/(launcher.stem().wstring()+L".shim");
    fs::path target;
    std::string kind;
    std::wstring defaults;
    Json record;
    if (fs::exists(coop_metadata)) {
        record = read_json(coop_metadata);
        target = wide(record.at("target").get<std::string>());
        kind = record.value("launcher",std::string("direct"));
        defaults = wide(record.value("arguments",std::string{}));
    } else if (fs::exists(scoop_metadata)) {
        const auto shim = read_shim_metadata(scoop_metadata);
        target = fs::path(wide(shim.target));
        kind = "direct";
        defaults = wide(shim.arguments);
        const auto record_path = record_for_target(target);
        if (!record_path.empty() && fs::is_regular_file(record_path)) {
            try { record = read_json(record_path); }
            catch (const std::exception&) { /* The command still runs without optional environment evidence. */ }
        }
    } else return false;
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
    if (!record.is_null()) apply_environment(record);
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
