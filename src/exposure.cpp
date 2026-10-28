#include "exposure.hpp"
#include <windows.h>
#include <shlobj.h>
#include <algorithm>
#include <array>
#include <cctype>
#include <fstream>
#include <stdexcept>
#include <vector>

namespace coop {
namespace {
struct ComUninitialize {
    bool active = false;
    ~ComUninitialize() { if (active) CoUninitialize(); }
};
void begin_com(ComUninitialize& guard) {
    const auto result = CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED|COINIT_DISABLE_OLE1DDE);
    if (SUCCEEDED(result)) guard.active = true;
    else if (result != RPC_E_CHANGED_MODE) throw std::runtime_error("Cannot initialize shell shortcut support");
}
struct ShellLinkRelease {
    IShellLinkW* value = nullptr;
    ~ShellLinkRelease() { if (value) value->Release(); }
};
struct PersistFileRelease {
    IPersistFile* value = nullptr;
    ~PersistFileRelease() { if (value) value->Release(); }
};
std::wstring environment_variable(const wchar_t* name) {
    std::array<wchar_t,32768> buffer{};
    const auto length = GetEnvironmentVariableW(name,buffer.data(),static_cast<DWORD>(buffer.size()));
    if (!length || static_cast<std::size_t>(length) >= buffer.size()) return {};
    return std::wstring(buffer.data(),length);
}
fs::path programs_folder() {
    PWSTR raw = nullptr;
    const auto result = SHGetKnownFolderPath(FOLDERID_Programs,KF_FLAG_DEFAULT,nullptr,&raw);
    if (FAILED(result) || raw == nullptr) {
        if (raw) CoTaskMemFree(raw);
        throw std::runtime_error("Cannot locate the current user's Start Menu programs folder");
    }
    fs::path folder(raw);
    CoTaskMemFree(raw);
    return folder;
}
std::optional<WORD> pe_subsystem(const fs::path& path) {
    std::ifstream file(path,std::ios::binary);
    IMAGE_DOS_HEADER dos{};
    file.read(reinterpret_cast<char*>(&dos),sizeof(dos));
    if (!file || dos.e_magic != IMAGE_DOS_SIGNATURE || dos.e_lfanew <= 0) return std::nullopt;
    const auto nt = static_cast<std::streamoff>(dos.e_lfanew);
    file.seekg(nt);
    DWORD signature = 0;
    IMAGE_FILE_HEADER header{};
    file.read(reinterpret_cast<char*>(&signature),sizeof(signature));
    file.read(reinterpret_cast<char*>(&header),sizeof(header));
    if (!file || signature != IMAGE_NT_SIGNATURE) return std::nullopt;
    WORD magic = 0;
    file.read(reinterpret_cast<char*>(&magic),sizeof(magic));
    if (!file || (magic != IMAGE_NT_OPTIONAL_HDR32_MAGIC && magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC)) return std::nullopt;
    // Subsystem has the same offset in the PE32 and PE32+ optional headers.
    WORD subsystem = 0;
    file.seekg(nt+4+static_cast<std::streamoff>(sizeof(IMAGE_FILE_HEADER))+68);
    file.read(reinterpret_cast<char*>(&subsystem),sizeof(subsystem));
    if (!file) return std::nullopt;
    return subsystem;
}
void replace_all(std::string& text, const std::string& needle, const std::string& replacement) {
    if (needle.empty()) return;
    std::size_t position = 0;
    while ((position = text.find(needle,position)) != std::string::npos) {
        text.replace(position,needle.size(),replacement);
        position += replacement.size();
    }
}
fs::path shortcut_relative_path(const std::string& name) {
    const fs::path path(wide(name));
    if (path.empty() || path == L"." || path.is_absolute() || path.has_root_name() || path.has_root_directory())
        throw std::runtime_error("Shortcut name must be a package-independent relative name");
    for (const auto& part : path) {
        if (part == L".") continue;
        validate_component(path_text(part));
    }
    return path.lexically_normal();
}
}
LauncherKind launcher_kind(const fs::path& target) {
    auto extension = path_text(target.extension());
    for (auto& character : extension) character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    if (extension == ".exe" || extension == ".com") return LauncherKind::direct;
    if (extension == ".cmd" || extension == ".bat") return LauncherKind::command_script;
    if (extension == ".ps1") return LauncherKind::power_shell;
    if (extension == ".jar") return LauncherKind::java;
    if (extension == ".py") return LauncherKind::python;
    // Scoop's shim() has no unknown branch: every target not matched above is run through bash.
    // That covers extensionless scripts, .config files and any other suffix.
    return LauncherKind::bash;
}
const char* launcher_text(LauncherKind kind) {
    switch (kind) {
    case LauncherKind::direct: return "direct";
    case LauncherKind::command_script: return "cmd";
    case LauncherKind::power_shell: return "powershell";
    case LauncherKind::java: return "java";
    case LauncherKind::python: return "python";
    case LauncherKind::bash: return "bash";
    }
    return "unknown";
}
std::string command_launcher_name(const fs::path& target) {
    return launcher_text(launcher_kind(target));
}
std::optional<fs::path> command_host_path(LauncherKind kind) {
    const wchar_t* name = kind == LauncherKind::python ? L"python.exe" :
        kind == LauncherKind::bash ? L"bash.exe" : nullptr;
    if (!name) return std::nullopt;
    // Search only the current process PATH, the same lookup a user shell uses for Scoop's shim.
    // SearchPathW would also find a system-directory bash.exe even with an empty PATH, which would
    // hide a missing host instead of failing before an entry is written.
    std::array<wchar_t,32768> buffer{};
    const auto length = GetEnvironmentVariableW(L"PATH",buffer.data(),static_cast<DWORD>(buffer.size()));
    if (!length || static_cast<std::size_t>(length) >= buffer.size()) return std::nullopt;
    const std::wstring path(buffer.data(),length);
    std::size_t begin = 0;
    while (begin <= path.size()) {
        const auto end = path.find(L';',begin);
        auto directory = path.substr(begin,end == std::wstring::npos ? std::wstring::npos : end-begin);
        if (directory.size() >= 2 && directory.front() == L'"' && directory.back() == L'"')
            directory = directory.substr(1,directory.size()-2);
        if (!directory.empty()) {
            const auto candidate = fs::path(directory)/name;
            std::error_code error;
            const auto attributes = GetFileAttributesW(candidate.c_str());
            if (attributes != INVALID_FILE_ATTRIBUTES && !(attributes & FILE_ATTRIBUTE_DIRECTORY) &&
                !(attributes & FILE_ATTRIBUTE_REPARSE_POINT) && fs::is_regular_file(candidate,error) && !error &&
                fs::file_size(candidate,error) > 0 && !error) return candidate;
        }
        if (end == std::wstring::npos) break;
        begin = end+1;
    }
    return std::nullopt;
}
std::string command_host_problem(LauncherKind kind) {
    if (kind == LauncherKind::python)
        return "Python interpreter not found for the .py command entry; install Python 3 or add python.exe to PATH before installing this package, because Scoop runs .py entries through python";
    if (kind == LauncherKind::bash)
        return "bash not found for the script command entry; install a bash implementation or add bash.exe to PATH before installing this package, because Scoop runs extensionless and .config entries through bash";
    return {};
}
std::vector<std::string> entry_environment_lines(const Json& environment, const Json& path_entries, bool shell) {
    std::vector<std::string> lines;
    for (const auto& setting : environment) {
        if (!setting.is_object()) continue;
        const auto name = setting.value("name",std::string{});
        const auto value = setting.value("value",std::string{});
        if (name.empty()) continue;
        lines.push_back(shell ? "export "+name+"='"+value+"'" : "@set \""+name+"="+value+"\"");
    }
    if (!shell) {
        // A cmd wrapper runs in the caller's cmd process when invoked from an interactive prompt, so
        // the declarations are scoped with setlocal and disappear when the wrapper exits.
        std::string joined;
        for (const auto& entry : path_entries) {
            if (!entry.is_string()) continue;
            joined += joined.empty() ? entry.get<std::string>() : ";"+entry.get<std::string>();
        }
        if (!joined.empty()) lines.push_back("@set \"PATH="+joined+";%PATH%\"");
        if (!lines.empty()) lines.insert(lines.begin(),"@setlocal");
    }
    // The POSIX PATH cannot carry Windows entries (a drive letter already contains ':'); the shell
    // wrapper exports the declared variables and leaves PATH to the caller's environment.
    return lines;
}
std::string scoop_command_cmd(LauncherKind kind, const fs::path& target, const std::string& arguments,
                              const Json& environment, const Json& path_entries) {
    const auto path = path_text(target);
    std::vector<std::string> lines;
    if (kind == LauncherKind::python) {
        lines = {"@rem "+path,"@python \""+path+"\" "+arguments+" %*"};
    } else if (kind == LauncherKind::command_script) {
        lines = {"@rem "+path,"@\""+path+"\" "+arguments+" %*"};
    } else if (kind == LauncherKind::power_shell) {
        lines = {
            "@rem "+path,
            "@echo off",
            "where /q pwsh.exe",
            "if %errorlevel% equ 0 (",
            "    pwsh -noprofile -ex unrestricted -file \""+path+"\" "+arguments+" %*",
            ") else (",
            "    powershell -noprofile -ex unrestricted -file \""+path+"\" "+arguments+" %*",
            ")"
        };
    } else if (kind == LauncherKind::java) {
        lines = {
            "@rem "+path,
            // Scoop's branch runs popd last, which resets the caller's exit code, and it does not
            // diagnose a missing runtime. The product requires an explicit failure before the target
            // runs, the caller's working directory preserved and the target's status propagated.
            "@setlocal",
            "@set \"coop_java=java.exe\"",
            "@if defined JAVA_HOME if exist \"%JAVA_HOME%\\bin\\java.exe\" set \"coop_java=%JAVA_HOME%\\bin\\java.exe\"",
            "@\"%coop_java%\" -version >nul 2>&1",
            "@if errorlevel 1 (echo Java runtime not found for the JAR command entry; set JAVA_HOME or add java.exe to PATH 1>&2 & endlocal & exit /b 1)",
            "@pushd "+path_text(target.parent_path()),
            "@\"%coop_java%\" -jar \""+path+"\" "+arguments+" %*",
            "@set \"coop_exit=%errorlevel%\"",
            "@popd",
            "@endlocal & exit /b %coop_exit%"
        };
    } else {
        // Scoop quotes each declared argument element for the bash (else) branch.
        const auto quoted = arguments.empty() ? std::string{} : "\""+arguments+"\"";
        lines = {
            "@rem "+path,
            "@echo off",
            "bash -c \"command -v wslpath >/dev/null\"",
            "if %errorlevel% equ 0 (",
            "  bash \"$(wslpath -u '"+path+"')\" "+quoted+" %*",
            ") else (",
            "  set args="+quoted+" %*",
            "  setlocal enabledelayedexpansion",
            "  if not \"!args!\"==\"\" set args=!args:\"=\"\"!",
            "  bash -c \"$(cygpath -u '"+path+"') !args!\"",
            ")"
        };
    }
    const auto preamble = entry_environment_lines(environment,path_entries,false);
    lines.insert(lines.begin()+1,preamble.begin(),preamble.end());
    std::string text;
    for (std::size_t index = 0; index < lines.size(); ++index) {
        if (index) text += "\r\n";
        text += lines[index];
    }
    return text;
}
std::string scoop_command_shell(LauncherKind kind, const fs::path& target, const std::string& arguments,
                                const Json& environment, const Json& path_entries) {
    const auto path = path_text(target);
    std::vector<std::string> lines;
    if (kind == LauncherKind::python) {
        lines = {"#!/bin/sh","# "+path,"python.exe \""+path+"\" "+arguments+" \"$@\""};
    } else if (kind == LauncherKind::command_script) {
        lines = {"#!/bin/sh","# "+path,"MSYS2_ARG_CONV_EXCL=/C cmd.exe /C \""+path+"\" "+arguments+" \"$@\""};
    } else if (kind == LauncherKind::power_shell) {
        lines = {
            "#!/bin/sh",
            "# "+path,
            "if command -v pwsh.exe > /dev/null 2>&1; then",
            "    pwsh.exe -noprofile -ex unrestricted -file \""+path+"\" "+arguments+" \"$@\"",
            "else",
            "    powershell.exe -noprofile -ex unrestricted -file \""+path+"\" "+arguments+" \"$@\"",
            "fi"
        };
    } else if (kind == LauncherKind::java) {
        const auto parent = path_text(target.parent_path());
        lines = {
            "#!/bin/sh",
            "# "+path,
            "if [ $WSL_INTEROP ]",
            "then",
            "  cd $(wslpath -u '"+parent+"')",
            "else",
            "  cd $(cygpath -u '"+parent+"')",
            "fi",
            "java.exe -jar \""+path+"\" "+arguments+" \"$@\""
        };
    } else {
        lines = {
            "#!/bin/sh",
            "# "+path,
            "if [ $WSL_INTEROP ]",
            "then",
            "  \"$(wslpath -u '"+path+"')\" "+arguments+" \"$@\"",
            "else",
            "  \"$(cygpath -u '"+path+"')\" "+arguments+" \"$@\"",
            "fi"
        };
    }
    const auto preamble = entry_environment_lines(environment,path_entries,true);
    lines.insert(lines.begin()+2,preamble.begin(),preamble.end());
    std::string text;
    for (std::size_t index = 0; index < lines.size(); ++index) {
        if (index) text += "\n";
        text += lines[index];
    }
    return text;
}
std::string scoop_command_ps1(const fs::path& target, const std::string& arguments) {
    const auto path = path_text(target);
    // Scoop writes the relative form when the target is on the shim's drive and the absolute form
    // across drives. Coop always names the stable current path, so the absolute form is the exact
    // equivalent Scoop branch.
    const std::vector<std::string> lines = {
        "# "+path,
        "$path = \""+path+"\"",
        "if ($MyInvocation.ExpectingInput) { $input | & $path "+arguments+" @args } else { & $path "+arguments+" @args }",
        "exit $LASTEXITCODE"
    };
    std::string text;
    for (std::size_t index = 0; index < lines.size(); ++index) {
        if (index) text += "\r\n";
        text += lines[index];
    }
    return text;
}
bool is_gui_executable(const fs::path& path) {
    const auto subsystem = pe_subsystem(path);
    return subsystem && *subsystem == IMAGE_SUBSYSTEM_WINDOWS_GUI;
}
void mark_launcher_gui(const fs::path& launcher) {
    std::fstream file(launcher,std::ios::in|std::ios::out|std::ios::binary);
    IMAGE_DOS_HEADER dos{};
    file.read(reinterpret_cast<char*>(&dos),sizeof(dos));
    if (!file || dos.e_magic != IMAGE_DOS_SIGNATURE || dos.e_lfanew <= 0)
        throw std::runtime_error("Copied command launcher is not a Windows executable");
    const auto nt = static_cast<std::streamoff>(dos.e_lfanew);
    file.seekg(nt);
    DWORD signature = 0;
    IMAGE_FILE_HEADER header{};
    file.read(reinterpret_cast<char*>(&signature),sizeof(signature));
    file.read(reinterpret_cast<char*>(&header),sizeof(header));
    WORD magic = 0;
    file.read(reinterpret_cast<char*>(&magic),sizeof(magic));
    if (!file || signature != IMAGE_NT_SIGNATURE || (magic != IMAGE_NT_OPTIONAL_HDR32_MAGIC && magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC))
        throw std::runtime_error("Copied command launcher has an unexpected PE layout");
    const auto offset = nt+4+static_cast<std::streamoff>(sizeof(IMAGE_FILE_HEADER))+68;
    const WORD subsystem = IMAGE_SUBSYSTEM_WINDOWS_GUI;
    file.seekp(offset);
    file.write(reinterpret_cast<const char*>(&subsystem),sizeof(subsystem));
    file.flush();
    if (!file) throw std::runtime_error("Cannot mark the copied command launcher as a GUI program");
}
fs::path shortcut_directory(const Context& context) {
    (void)context;
    const auto override = environment_variable(L"COOP_PROGRAMS_DIR");
    if (!override.empty()) return fs::path(override).lexically_normal();
    return programs_folder()/L"Scoop Apps";
}
fs::path shortcut_link_path(const Context& context, const std::string& name) {
    const auto relative = shortcut_relative_path(name);
    return shortcut_directory(context)/fs::path(relative.wstring()+L".lnk");
}
std::optional<ShortcutIdentity> read_shortcut(const fs::path& link) {
    if (!fs::is_regular_file(link)) return std::nullopt;
    ComUninitialize guard;
    begin_com(guard);
    ShellLinkRelease shell;
    if (FAILED(CoCreateInstance(CLSID_ShellLink,nullptr,CLSCTX_INPROC_SERVER,IID_IShellLinkW,
        reinterpret_cast<void**>(&shell.value)))) return std::nullopt;
    PersistFileRelease persist;
    if (FAILED(shell.value->QueryInterface(IID_IPersistFile,reinterpret_cast<void**>(&persist.value)))) return std::nullopt;
    if (FAILED(persist.value->Load(link.c_str(),STGM_READ))) return std::nullopt;
    std::array<wchar_t,32768> target{};
    std::array<wchar_t,32768> arguments{};
    std::array<wchar_t,32768> icon{};
    if (FAILED(shell.value->GetPath(target.data(),static_cast<int>(target.size()),nullptr,0)) || target[0] == L'\0')
        return std::nullopt;
    if (FAILED(shell.value->GetArguments(arguments.data(),static_cast<int>(arguments.size())))) return std::nullopt;
    int icon_index = 0;
    if (FAILED(shell.value->GetIconLocation(icon.data(),static_cast<int>(icon.size()),&icon_index)))
        icon[0] = L'\0';
    ShortcutIdentity identity;
    identity.target = fs::path(target.data());
    identity.arguments = utf8(arguments.data());
    identity.icon = icon[0] == L'\0' ? fs::path{} : fs::path(icon.data());
    return identity;
}
void write_shortcut(const fs::path& link, const fs::path& target, const std::string& arguments, const fs::path& icon) {
    ComUninitialize guard;
    begin_com(guard);
    ShellLinkRelease shell;
    if (FAILED(CoCreateInstance(CLSID_ShellLink,nullptr,CLSCTX_INPROC_SERVER,IID_IShellLinkW,
        reinterpret_cast<void**>(&shell.value)))) throw std::runtime_error("Cannot create a Windows shortcut");
    if (FAILED(shell.value->SetPath(target.c_str()))) throw std::runtime_error("Shortcut target cannot be set");
    if (!icon.empty()) {
        if (FAILED(shell.value->SetIconLocation(icon.c_str(),0))) throw std::runtime_error("Shortcut icon cannot be set");
    }
    if (!arguments.empty()) {
        const auto text = wide(arguments);
        if (FAILED(shell.value->SetArguments(text.c_str()))) throw std::runtime_error("Shortcut arguments cannot be set");
    }
    if (FAILED(shell.value->SetWorkingDirectory(target.parent_path().c_str())))
        throw std::runtime_error("Shortcut working directory cannot be set");
    PersistFileRelease persist;
    if (FAILED(shell.value->QueryInterface(IID_IPersistFile,reinterpret_cast<void**>(&persist.value))))
        throw std::runtime_error("Shortcut cannot be persisted");
    std::error_code error;
    fs::create_directories(link.parent_path(),error);
    if (error) throw std::runtime_error("Cannot create shortcut directory: "+path_text(link.parent_path()));
    if (FAILED(persist.value->Save(link.c_str(),TRUE))) throw std::runtime_error("Shortcut cannot be written: "+path_text(link));
}
std::string expand_package_value(const Context& context, const ir::Package& package, const fs::path& base, const std::string& value) {
    auto text = value;
    const auto persist = path_text(context.root/L"persist"/wide(package.name));
    const auto directory = path_text(base);
    replace_all(text,"$persist_dir",persist);
    replace_all(text,"$original_dir",directory);
    replace_all(text,"$dir",directory);
    replace_all(text,"$version",package.version);
    replace_all(text,"$global","");
    if (text.find('%') != std::string::npos) {
        const auto expanded = wide(text);
        std::array<wchar_t,32768> buffer{};
        const auto length = ExpandEnvironmentStringsW(expanded.c_str(),buffer.data(),static_cast<DWORD>(buffer.size()));
        if (length > 0 && length <= buffer.size()) text = utf8(std::wstring(buffer.data(),length-1));
    }
    return text;
}
std::string expand_exposure_arguments(const Context& context, const std::string& package_name,
    const fs::path& base, const std::string& value) {
    // The fixed Scoop baseline substitutes exactly these three variables for bin and shortcut
    // arguments; environment declarations have their own wider expansion.
    auto text = value;
    replace_all(text,"$persist_dir",path_text(context.root/L"persist"/wide(package_name)));
    replace_all(text,"$original_dir",path_text(base));
    replace_all(text,"$dir",path_text(base));
    return text;
}
Json expanded_environment(const Context& context, const ir::Package& package, const fs::path& base) {
    Json result = Json::array();
    for (const auto& setting : package.environment) {
        if (setting.path_entry) continue;
        result.push_back({{"name",setting.variable},{"value",expand_package_value(context,package,base,setting.value)}});
    }
    return result;
}
Json expanded_path_entries(const Context& context, const ir::Package& package, const fs::path& base) {
    (void)context;
    Json result = Json::array();
    for (const auto& entry : package.environment) {
        if (!entry.path_entry) continue;
        auto text = path_text((base/wide(entry.value)).lexically_normal());
        while (text.size() > 3 && (text.back() == '\\' || text.back() == '/')) text.pop_back();
        result.push_back(text);
    }
    return result;
}
Json exposure_plan_json(const Context& context, const ir::Package& package, const fs::path& base) {
    const auto programs = shortcut_directory(context);
    Json result = {{"shortcut_directory",path_text(programs)},
        {"shortcut_directory_source",environment_variable(L"COOP_PROGRAMS_DIR").empty() ? "start-menu-programs" : "isolated-override"},
        {"environment_scope","Declared values are written to the current user's environment (HKCU\\Environment), broadcast with WM_SETTINGCHANGE and also applied to Coop command processes; previous values and ownership are recorded, and user later changes are preserved"},
        {"shortcuts",Json::array()},{"environment",expanded_environment(context,package,base)},
        {"path_entries",expanded_path_entries(context,package,base)}};
    const auto argument_base = context.root/L"apps"/wide(package.name)/L"current";
    for (const auto& shortcut : package.shortcuts)
        result["shortcuts"].push_back({{"name",shortcut.name},{"kind","windows-shortcut"},
            {"link",path_text(programs/fs::path(wide(shortcut.name)+L".lnk"))},
            // Scoop combines the declared value with $dir and resolves it as a FileInfo, so parent
            // components are already collapsed in the path that actually reaches the shortcut.
            {"target",path_text((base/wide(shortcut.target)).lexically_normal())},
            {"arguments",expand_exposure_arguments(context,package.name,argument_base,shortcut.arguments)},
            {"icon",shortcut.icon.empty() ? std::string{} : path_text((base/wide(shortcut.icon)).lexically_normal())}});
    return result;
}
Json ps_module_plan_json(const Context& context, const std::string& name, const fs::path& target, bool removal) {
    if (name.empty()) return Json(nullptr);
    const auto modules = context.root/L"modules";
    return {{"operation",removal ? "remove" : "create"},
        {"name",name},{"link",path_text(modules/wide(name))},{"kind","directory-junction"},
        {"target",path_text(target)},
        {"user_environment",{{"variable","PSModulePath"},{"entry",path_text(modules)},
            {"scope","HKCU\\Environment"},
            {"effect",removal ?
                "remove only the entry Coop recorded as its own when no other module link remains; user changes and other entries are preserved" :
                "prepend the entry when it is absent, record the previous raw value and the entry Coop added"}}},
        {"scoop_semantics","Scoop 0.6.0 psmodules.ps1 install_psmodule/uninstall_psmodule: a directory junction <root>/modules/<name> and the user PSModulePath entry for <root>/modules"}};
}
}
