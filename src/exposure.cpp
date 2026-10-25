#include "exposure.hpp"
#include <windows.h>
#include <shlobj.h>
#include <algorithm>
#include <array>
#include <fstream>
#include <stdexcept>

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
std::optional<LauncherKind> launcher_kind(const fs::path& target) {
    auto extension = path_text(target.extension());
    for (auto& character : extension) character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    if (extension == ".exe" || extension == ".com") return LauncherKind::direct;
    if (extension == ".cmd" || extension == ".bat") return LauncherKind::command_script;
    if (extension == ".ps1") return LauncherKind::power_shell;
    if (extension == ".jar") return LauncherKind::java;
    return std::nullopt;
}
const char* launcher_text(LauncherKind kind) {
    switch (kind) {
    case LauncherKind::direct: return "direct";
    case LauncherKind::command_script: return "cmd";
    case LauncherKind::power_shell: return "powershell";
    case LauncherKind::java: return "java";
    }
    return "unknown";
}
std::string command_launcher_name(const fs::path& target) {
    const auto kind = launcher_kind(target);
    return kind ? std::string(launcher_text(*kind)) : std::string("unsupported");
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
std::string expand_package_value(const Context& context, const Package& package, const fs::path& base, const std::string& value) {
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
Json expanded_environment(const Context& context, const Package& package, const fs::path& base) {
    Json result = Json::array();
    for (const auto& setting : package.environment)
        result.push_back({{"name",setting.name},{"value",expand_package_value(context,package,base,setting.value)}});
    return result;
}
Json expanded_path_entries(const Context& context, const Package& package, const fs::path& base) {
    (void)context;
    Json result = Json::array();
    for (const auto& entry : package.path_entries) {
        auto text = path_text((base/entry).lexically_normal());
        while (text.size() > 3 && (text.back() == '\\' || text.back() == '/')) text.pop_back();
        result.push_back(text);
    }
    return result;
}
Json exposure_plan_json(const Context& context, const Package& package, const fs::path& base) {
    const auto programs = shortcut_directory(context);
    Json result = {{"shortcut_directory",path_text(programs)},
        {"shortcut_directory_source",environment_variable(L"COOP_PROGRAMS_DIR").empty() ? "start-menu-programs" : "isolated-override"},
        {"environment_scope","Declared values are applied to processes started through Coop command entries; user and system environment variables are not modified"},
        {"shortcuts",Json::array()},{"environment",expanded_environment(context,package,base)},
        {"path_entries",expanded_path_entries(context,package,base)}};
    for (const auto& shortcut : package.shortcuts)
        result["shortcuts"].push_back({{"name",shortcut.name},{"kind","windows-shortcut"},
            {"link",path_text(programs/fs::path(wide(shortcut.name)+L".lnk"))},
            {"target",path_text(base/shortcut.target)},{"arguments",shortcut.arguments},
            {"icon",shortcut.icon.empty() ? std::string{} : path_text(base/shortcut.icon)}});
    return result;
}
}
