#include "script.hpp"
#include <windows.h>
#include <array>
#include <cstdio>
#include <fstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace coop {
namespace {
constexpr std::size_t max_tail_bytes = 8192;
// Pinned upstream version of assets/scoop-lib. Recorded in the host, the journal and the preview
// so hook evidence names the exact compatibility baseline instead of "current Scoop".
constexpr const char* scoop_compat_version = "Scoop v0.6.0 (e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f)";
// Library prelude order: bin/scoop.ps1 first, then the libraries that scoop-install.ps1,
// scoop-update.ps1 and scoop-uninstall.ps1 load before running a hook.
constexpr const char* scoop_compat_modules[] = {
    "core", "buckets", "commands", "help",
    "getopt", "json", "autoupdate", "manifest", "system", "install", "download",
    "decompress", "shortcuts", "psmodules", "versions", "depends"};

fs::path executable_directory() {
    std::vector<wchar_t> buffer(32768);
    const auto length = GetModuleFileNameW(nullptr,buffer.data(),static_cast<DWORD>(buffer.size()));
    if (length == 0 || length >= buffer.size()) return {};
    return fs::path(buffer.data(),buffer.data()+length).parent_path();
}
std::optional<std::wstring> environment_value(const wchar_t* name) {
    wchar_t value[32768]{};
    const auto length = GetEnvironmentVariableW(name,value,static_cast<DWORD>(std::size(value)));
    if (!length || length >= std::size(value)) return std::nullopt;
    return std::wstring(value,length);
}
struct LibraryLookup {
    std::optional<fs::path> path;
    // An explicit COOP_SCOOP_LIB that does not contain core.ps1 is a configuration error, not a
    // reason to silently fall back to the copy beside the executable.
    bool override_invalid = false;
};
LibraryLookup scoop_library() {
    if (const auto configured = environment_value(L"COOP_SCOOP_LIB")) {
        const fs::path candidate(*configured);
        if (!fs::is_regular_file(candidate/L"core.ps1")) return {std::nullopt,true};
        return {candidate,false};
    }
    const auto directory = executable_directory();
    if (!directory.empty()) {
        const auto candidate = directory/L"scoop-lib";
        if (fs::is_regular_file(candidate/L"core.ps1")) return {candidate,false};
    }
    return {std::nullopt,false};
}
std::optional<fs::path> powershell_interpreter() {
    wchar_t configured[32768]{};
    const auto configured_length = GetEnvironmentVariableW(L"COOP_POWERSHELL",configured,static_cast<DWORD>(std::size(configured)));
    if (configured_length && configured_length < std::size(configured)) {
        const fs::path candidate(configured);
        if (fs::is_regular_file(candidate)) return candidate;
        return std::nullopt;
    }
    std::vector<wchar_t> buffer(32768);
    const auto length = SearchPathW(nullptr,L"pwsh.exe",nullptr,static_cast<DWORD>(buffer.size()),buffer.data(),nullptr);
    if (length && length < buffer.size()) {
        const fs::path candidate(buffer.data());
        if (fs::is_regular_file(candidate)) return candidate;
    }
    wchar_t windows[32768]{};
    const auto windows_length = GetWindowsDirectoryW(windows,static_cast<UINT>(std::size(windows)));
    if (windows_length && windows_length < std::size(windows)) {
        const fs::path candidate = fs::path(windows)/L"System32"/L"WindowsPowerShell"/L"v1.0"/L"powershell.exe";
        if (fs::is_regular_file(candidate)) return candidate;
    }
    return std::nullopt;
}
std::wstring quote_argument(const std::wstring& value) {
    if (!value.empty() && value.find_first_of(L" \t\n\v\"") == std::wstring::npos) return value;
    std::wstring result = L"\"";
    unsigned backslashes = 0;
    for (const auto character : value) {
        if (character == L'\\') { ++backslashes; continue; }
        if (character == L'"') result.append(backslashes*2+1,L'\\');
        else result.append(backslashes,L'\\');
        result += character;
        backslashes = 0;
    }
    result.append(backslashes*2,L'\\');
    result += L'"';
    return result;
}
std::string ps_literal(const std::string& value) {
    std::string result = "'";
    for (const auto character : value) {
        if (character == '\'') result += "''";
        else result += character;
    }
    result += '\'';
    return result;
}
// The generated host binds exactly the context Scoop's install_app/scoop-uninstall place in the
// scope of Invoke-HookScript and then runs the hook text with the upstream libs already loaded.
// $cmd is deliberately not defined: Scoop 0.6.0 never sets it either (verified by running its own
// Invoke-HookScript), so `if ($cmd -eq 'uninstall')` blocks in Manifests evaluate the same way.
// $purge exists only for uninstall, also matching scoop-uninstall.ps1's scope.
std::string context_prelude(const Context& context, const Package& package,
                            const fs::path& directory, const fs::path& original_directory,
                            const fs::path& persist_directory, const fs::path& library,
                            const std::string& command_name, bool purge, const fs::path& manifest_path) {
    const auto fname = package.artifacts.empty() ? std::string{} : package.artifacts.front().filename;
    std::string text =
        "$ErrorActionPreference = 'Stop'\n"
        "$ProgressPreference = 'SilentlyContinue'\n"
        "Set-StrictMode -Off\n"
        "try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }\n";
    // core.ps1 resolves $scoopdir from $env:SCOOP first, so the selected management root is the
    // Scoop root for the whole hook session. The variable is set inside the child only.
    text += std::string("$env:SCOOP = ")+ps_literal(path_text(context.root))+"\n";
    text += std::string("$scoopLib = ")+ps_literal(path_text(library))+"\n";
    for (const auto* module : scoop_compat_modules)
        text += ". (Join-Path $scoopLib '"+std::string(module)+".ps1')\n";
    const auto emit = [&](const char* name, const std::string& value) {
        text += "$"+std::string(name)+" = "+ps_literal(value)+"\n";
    };
    emit("app",package.name);
    emit("bucket",package.bucket);
    emit("version",package.version);
    emit("architecture",package.architecture);
    emit("fname",fname);
    emit("dir",path_text(directory));
    emit("original_dir",path_text(original_directory));
    emit("persist_dir",path_text(persist_directory));
    text += "$url = $null\n";
    text += "$global = $false\n";
    if (command_name == "uninstall") text += std::string("$purge = ")+(purge ? "$true\n" : "$false\n");
    if (!manifest_path.empty()) {
        // Scoop's manifest loader reads the Manifest as UTF-8; without the explicit encoding the
        // Windows PowerShell fallback would decode a non-ASCII Manifest with the ANSI code page.
        text += "$manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath "+ps_literal(path_text(manifest_path))+
            " | ConvertFrom-Json\n";
    } else {
        text += "$manifest = $null\n";
    }
    return text;
}
std::string host_script(const Context& context, const Package& package, const fs::path& hook_path,
                        const fs::path& directory, const fs::path& original_directory,
                        const fs::path& persist_directory, const fs::path& library,
                        const std::string& command_name, bool purge, const fs::path& manifest_path) {
    std::string text = context_prelude(context,package,directory,original_directory,persist_directory,
        library,command_name,purge,manifest_path);
    text += "$hookScript = Get-Content -Raw -LiteralPath "+ps_literal(path_text(hook_path))+"\n";
    // A terminating error inside the hook must fail the package instead of being reported as a
    // successful lifecycle; the message reaches the hook's stderr log. `exit N`, `abort` and
    // `throw` therefore propagate, and the hook is never retried.
    text += "try { Invoke-Command ([scriptblock]::Create($hookScript)) } "
            "catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }\n";
    return text;
}
// Scoop's Invoke-Installer runs the declared installer/uninstaller program and then the
// installer/uninstaller hook script in one call. The IR plan carries that hook script as its own
// operation, so this host suppresses only the `script` property of the selected sections and lets
// the upstream helper own the rest: the is_in_dir/Test-Path aborts, $dir/$global/$version argument
// substitution, direct `& $progName` invocation for .ps1 programs, non-zero propagation through
// `abort`, and the keep=false removal of the program file. No behavior is reimplemented here.
std::string installer_host_script(const Context& context, const Package& package,
                                  const fs::path& directory, const fs::path& original_directory,
                                  const fs::path& persist_directory, const fs::path& library,
                                  const std::string& command_name, bool purge,
                                  const fs::path& manifest_path, bool uninstall) {
    std::string text = context_prelude(context,package,directory,original_directory,persist_directory,
        library,command_name,purge,manifest_path);
    text += std::string("$installerType = '")+(uninstall ? "uninstaller" : "installer")+"'\n";
    // arch_specific, used by Invoke-Installer, prefers the selected architecture section; both the
    // root and the selected section are cleaned so the hook script cannot run twice.
    text +=
        "$installerSections = @($manifest.$installerType)\n"
        "if ($manifest.architecture -and $manifest.architecture.$architecture) {\n"
        "    $installerSections += $manifest.architecture.$architecture.$installerType\n"
        "}\n"
        "foreach ($installerSection in $installerSections) {\n"
        "    if ($installerSection -and ($installerSection.PSObject.Properties.Name -contains 'script')) {\n"
        "        $installerSection.PSObject.Properties.Remove('script')\n"
        "    }\n"
        "}\n";
    text += "try { Invoke-Installer -Path $dir";
    // Scoop's install_app passes the downloaded file names; uninstall calls Invoke-Installer
    // without -Name. Both only affect the fallback when installer.file is absent.
    if (!uninstall) text += " -Name @($fname)";
    text += " -Manifest $manifest -ProcessorArchitecture $architecture -AppName $app -Global:$global";
    if (uninstall) text += " -Uninstall";
    // `abort` inside Invoke-Installer already exits non-zero; a terminating error must fail the
    // package the same way instead of being reported as a successful lifecycle.
    text += " } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }\n";
    return text;
}
struct FileHandle {
    HANDLE value = INVALID_HANDLE_VALUE;
    FileHandle() = default;
    explicit FileHandle(HANDLE handle) : value(handle) {}
    ~FileHandle() { if (value != INVALID_HANDLE_VALUE) CloseHandle(value); }
    FileHandle(const FileHandle&) = delete;
    FileHandle& operator=(const FileHandle&) = delete;
    HANDLE release() { const auto result = value; value = INVALID_HANDLE_VALUE; return result; }
    void reset() { if (value != INVALID_HANDLE_VALUE) CloseHandle(value); value = INVALID_HANDLE_VALUE; }
};
void drain(HANDLE pipe, std::size_t& total, std::string& tail, FILE* log, bool echo, FILE* target) {
    std::array<char,65536> buffer{};
    for (;;) {
        DWORD count = 0;
        if (!ReadFile(pipe,buffer.data(),static_cast<DWORD>(buffer.size()),&count,nullptr) || count == 0) break;
        total += count;
        if (log) std::fwrite(buffer.data(),1,count,log);
        if (tail.size()+count > max_tail_bytes) {
            if (count >= max_tail_bytes) tail.assign(buffer.data()+count-max_tail_bytes,max_tail_bytes);
            else {
                tail.erase(0,tail.size()+count-max_tail_bytes);
                tail.append(buffer.data(),count);
            }
        } else tail.append(buffer.data(),count);
        if (echo && target) {
            std::fwrite(buffer.data(),1,count,target);
            std::fflush(target);
        }
    }
    if (log) std::fflush(log);
}
struct LogFile {
    FILE* value = nullptr;
    LogFile() = default;
    ~LogFile() { close(); }
    LogFile(const LogFile&) = delete;
    LogFile& operator=(const LogFile&) = delete;
    void open(const fs::path& path) {
        if (_wfopen_s(&value,path.c_str(),L"wb") != 0 || !value)
            throw std::runtime_error("Cannot write the hook script log");
    }
    void close() { if (value) { std::fclose(value); value = nullptr; } }
};
void write_script_file(const fs::path& path, const std::string& text) {
    std::ofstream output(path,std::ios::binary|std::ios::trunc);
    if (!output) throw std::runtime_error("Cannot write hook script");
    // A BOM keeps the script text readable for both PowerShell 7 and Windows PowerShell 5.1,
    // which otherwise assumes the ANSI code page for BOM-less files.
    static const char bom[] = "\xEF\xBB\xBF";
    output.write(bom,3);
    output.write(text.data(),static_cast<std::streamsize>(text.size()));
    if (!output) throw std::runtime_error("Cannot finish hook script");
}

// Shared child-process capture for every PowerShell host Coop starts (hook scripts and
// installer/uninstaller programs). stdout and stderr are drained concurrently into per-run log files
// so a noisy program cannot deadlock on a full pipe, and every byte is kept on disk while a bounded
// tail is retained for JSON records.
struct ProcessCapture {
    int exit_code = 1;
    std::size_t stdout_bytes = 0;
    std::size_t stderr_bytes = 0;
    std::string stdout_tail;
    std::string stderr_tail;
};
ProcessCapture capture_process(const Context& context, const fs::path& interpreter,
                               const fs::path& host_path, const fs::path& stdout_path,
                               const fs::path& stderr_path) {
    SECURITY_ATTRIBUTES attributes{sizeof(SECURITY_ATTRIBUTES),nullptr,TRUE};
    FileHandle out_read, out_write, err_read, err_write;
    if (!CreatePipe(&out_read.value,&out_write.value,&attributes,0)) throw std::runtime_error("Cannot create the hook stdout pipe");
    if (!CreatePipe(&err_read.value,&err_write.value,&attributes,0)) throw std::runtime_error("Cannot create the hook stderr pipe");
    if (!SetHandleInformation(out_read.value,HANDLE_FLAG_INHERIT,0) || !SetHandleInformation(err_read.value,HANDLE_FLAG_INHERIT,0))
        throw std::runtime_error("Cannot isolate the hook output pipes");
    FileHandle input(CreateFileW(L"NUL",GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,&attributes,OPEN_EXISTING,0,nullptr));
    if (input.value == INVALID_HANDLE_VALUE) throw std::runtime_error("Cannot open the hook stdin device");
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES|STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_HIDE;
    startup.hStdInput = input.value;
    startup.hStdOutput = out_write.value;
    startup.hStdError = err_write.value;
    auto command_line = quote_argument(interpreter.wstring())+L" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "+
        quote_argument(host_path.wstring());
    // Scoop runs hooks and installer programs in-process, so they inherit the caller's current
    // directory. The child is therefore not moved to $dir; a hook that wants the package directory
    // must use $dir, exactly as with Scoop. A null lpCurrentDirectory makes the child inherit the
    // Coop process directory.
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(nullptr,command_line.data(),nullptr,nullptr,TRUE,CREATE_NO_WINDOW,nullptr,
                        nullptr,&startup,&process))
        throw std::runtime_error("Cannot start the PowerShell hook host (Windows error "+std::to_string(GetLastError())+")");
    FileHandle process_handle(process.hProcess);
    CloseHandle(process.hThread);
    out_write.reset();
    err_write.reset();
    const bool echo = !context.json_output;
    ProcessCapture result;
    LogFile stdout_log, stderr_log;
    stdout_log.open(stdout_path);
    stderr_log.open(stderr_path);
    std::thread stdout_thread(drain,out_read.release(),std::ref(result.stdout_bytes),std::ref(result.stdout_tail),stdout_log.value,echo,stdout);
    std::thread stderr_thread(drain,err_read.release(),std::ref(result.stderr_bytes),std::ref(result.stderr_tail),stderr_log.value,echo,stderr);
    WaitForSingleObject(process_handle.value,INFINITE);
    DWORD exit_code = 1;
    GetExitCodeProcess(process_handle.value,&exit_code);
    stdout_thread.join();
    stderr_thread.join();
    const bool log_failed = std::ferror(stdout_log.value) != 0 || std::ferror(stderr_log.value) != 0;
    stdout_log.close();
    stderr_log.close();
    result.exit_code = static_cast<int>(exit_code);
    if (log_failed) throw std::runtime_error("Cannot finish the hook script output log");
    return result;
}
}
ScriptHostInfo script_host() {
    ScriptHostInfo info;
    info.interpreter = powershell_interpreter();
    const auto library = scoop_library();
    info.library = library.path;
    info.library_version = scoop_compat_version;
    if (!info.interpreter)
        info.problem = "A PowerShell runtime (pwsh.exe or Windows PowerShell) is required for lifecycle hook scripts; Coop does not install PowerShell automatically";
    else if (library.override_invalid)
        info.problem = "COOP_SCOOP_LIB is set but does not contain core.ps1, so the pinned Scoop compatibility library needed by hook scripts is not available";
    else if (!info.library)
        info.problem = "The pinned Scoop compatibility library (scoop-lib/core.ps1) was not found beside coop.exe and COOP_SCOOP_LIB is not set, so hook scripts cannot get the Scoop context and helpers";
    return info;
}
const char* script_phase_name(ScriptPhase phase) {
    switch (phase) {
    case ScriptPhase::before_install: return "pre_install";
    case ScriptPhase::installer: return "installer";
    case ScriptPhase::after_install: return "post_install";
    case ScriptPhase::before_uninstall: return "pre_uninstall";
    case ScriptPhase::uninstaller: return "uninstaller";
    case ScriptPhase::after_uninstall: return "post_uninstall";
    }
    return "unknown";
}
std::string script_json_text(const std::string& value) {
    std::string result;
    result.reserve(value.size());
    std::size_t index = 0;
    while (index < value.size()) {
        const auto lead = static_cast<unsigned char>(value[index]);
        if (lead < 0x80) { result += static_cast<char>(lead); ++index; continue; }
        std::size_t length = 0;
        unsigned minimum = 0;
        if ((lead & 0xE0) == 0xC0) { length = 2; minimum = 0x80; }
        else if ((lead & 0xF0) == 0xE0) { length = 3; minimum = 0x800; }
        else if ((lead & 0xF8) == 0xF0) { length = 4; minimum = 0x10000; }
        bool valid = length != 0 && index+length <= value.size();
        unsigned code = length == 2 ? (lead & 0x1Fu) : length == 3 ? (lead & 0x0Fu) : (lead & 0x07u);
        for (std::size_t offset = 1; valid && offset < length; ++offset) {
            const auto next = static_cast<unsigned char>(value[index+offset]);
            if ((next & 0xC0) != 0x80) valid = false;
            else code = (code << 6) | (next & 0x3Fu);
        }
        if (valid && (code < minimum || code > 0x10FFFFu || (code >= 0xD800u && code <= 0xDFFFu))) valid = false;
        if (!valid) { result += '?'; ++index; continue; }
        result.append(value,index,length);
        index += length;
    }
    return result;
}
ScriptRun run_package_script(const Context& context, const Package& package, std::size_t index,
                             const fs::path& directory, const fs::path& original_directory,
                             const fs::path& persist_directory, const fs::path& transaction,
                             const std::string& command_name, bool purge, const fs::path& manifest_path) {
    const auto host = script_host();
    if (!host.interpreter || !host.library)
        throw std::runtime_error(host.problem.empty() ?
            "A real PowerShell hook host and the pinned Scoop compatibility library are required for lifecycle hook scripts" :
            host.problem);
    const auto script = package.scripts.at(index);
    const auto phase = std::string(script_phase_name(script.phase));
    const auto scripts = transaction/L"scripts";
    std::error_code error;
    fs::create_directories(scripts,error);
    if (error) throw std::runtime_error("Cannot create the hook script directory");
    const auto base = scripts/(std::to_wstring(index)+L"-"+wide(phase));
    ScriptRun result;
    result.interpreter = *host.interpreter;
    result.library = *host.library;
    result.manifest_path = manifest_path;
    result.hook_path = fs::path(base.wstring()+L".ps1");
    result.host_path = fs::path(base.wstring()+L".host.ps1");
    result.stdout_path = fs::path(base.wstring()+L".stdout.log");
    result.stderr_path = fs::path(base.wstring()+L".stderr.log");
    write_script_file(result.hook_path,script.text+"\n");
    write_script_file(result.host_path,host_script(context,package,result.hook_path,directory,
        original_directory,persist_directory,*host.library,command_name,purge,manifest_path));
    const auto captured = capture_process(context,*host.interpreter,result.host_path,
        result.stdout_path,result.stderr_path);
    result.exit_code = captured.exit_code;
    result.stdout_bytes = captured.stdout_bytes;
    result.stderr_bytes = captured.stderr_bytes;
    result.stdout_tail = captured.stdout_tail;
    result.stderr_tail = captured.stderr_tail;
    return result;
}
InstallerRun run_installer_program(const Context& context, const Package& package, bool uninstall,
                                   std::size_t index, const fs::path& directory,
                                   const fs::path& original_directory, const fs::path& persist_directory,
                                   const fs::path& transaction, const std::string& command_name,
                                   bool purge, const fs::path& manifest_path) {
    const auto host = script_host();
    if (!host.interpreter || !host.library)
        throw std::runtime_error(host.problem.empty() ?
            "A real PowerShell host and the pinned Scoop compatibility library are required for installer/uninstaller programs" :
            host.problem);
    const auto phase = std::string(uninstall ? "uninstaller" : "installer");
    const auto scripts = transaction/L"scripts";
    std::error_code error;
    fs::create_directories(scripts,error);
    if (error) throw std::runtime_error("Cannot create the installer program directory");
    const auto base = scripts/(std::to_wstring(index)+L"-"+wide(phase)+L"-program");
    InstallerRun result;
    result.interpreter = *host.interpreter;
    result.library = *host.library;
    result.manifest_path = manifest_path;
    result.host_path = fs::path(base.wstring()+L".host.ps1");
    result.stdout_path = fs::path(base.wstring()+L".stdout.log");
    result.stderr_path = fs::path(base.wstring()+L".stderr.log");
    write_script_file(result.host_path,installer_host_script(context,package,directory,
        original_directory,persist_directory,*host.library,command_name,purge,manifest_path,uninstall));
    const auto captured = capture_process(context,*host.interpreter,result.host_path,
        result.stdout_path,result.stderr_path);
    result.exit_code = captured.exit_code;
    result.stdout_bytes = captured.stdout_bytes;
    result.stderr_bytes = captured.stderr_bytes;
    result.stdout_tail = captured.stdout_tail;
    result.stderr_tail = captured.stderr_tail;
    return result;
}
}
