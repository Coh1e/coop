#include "native.hpp"
#include "data.hpp"
#include <windows.h>
#include <winhttp.h>
#include <winioctl.h>
#include <shlwapi.h>
#include <fstream>
#include <array>
#include <cctype>
#include <stdexcept>
#include <cstring>

namespace coop {
namespace {
struct InternetHandle {
    HINTERNET value;
    ~InternetHandle() { if (value) WinHttpCloseHandle(value); }
};
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
int hex_value(char value) {
    if (value >= '0' && value <= '9') return value-'0';
    if (value >= 'a' && value <= 'f') return value-'a'+10;
    if (value >= 'A' && value <= 'F') return value-'A'+10;
    return -1;
}
fs::path local_file_path(const std::string& url) {
    auto encoded = url.substr(7);
    if (encoded.starts_with("localhost/")) encoded.erase(0,9);
    if (encoded.empty() || encoded.front() != '/' || encoded.starts_with("//"))
        throw std::runtime_error("Unsupported local artifact URL");
    std::string decoded;
    decoded.reserve(encoded.size());
    for (std::size_t i = 0; i < encoded.size(); ++i) {
        if (encoded[i] != '%') { decoded += encoded[i]; continue; }
        if (i+2 >= encoded.size()) throw std::runtime_error("Invalid local artifact URL escape");
        const int high = hex_value(encoded[i+1]), low = hex_value(encoded[i+2]);
        if (high < 0 || low < 0) throw std::runtime_error("Invalid local artifact URL escape");
        const char value = static_cast<char>(high*16+low);
        if (!value) throw std::runtime_error("Invalid local artifact URL path");
        decoded += value;
        i += 2;
    }
    if (decoded.size() >= 3 && decoded[0] == '/' && std::isalpha(static_cast<unsigned char>(decoded[1])) && decoded[2] == ':')
        decoded.erase(0,1);
    return fs::path(wide(decoded));
}
}
void download_file(const std::string& url, const fs::path& destination) {
    const auto address = wide(url);
    if (url.starts_with("file://")) {
        fs::copy_file(local_file_path(url),destination);
        return;
    }
    URL_COMPONENTS components{};
    components.dwStructSize = sizeof(components);
    components.dwHostNameLength = components.dwUrlPathLength = components.dwExtraInfoLength = static_cast<DWORD>(-1);
    components.dwUserNameLength = components.dwPasswordLength = static_cast<DWORD>(-1);
    if (!WinHttpCrackUrl(address.c_str(),0,0,&components) ||
        (components.nScheme != INTERNET_SCHEME_HTTPS && components.nScheme != INTERNET_SCHEME_HTTP) ||
        components.dwUserNameLength || components.dwPasswordLength) throw std::runtime_error("Unsupported artifact URL");
    InternetHandle session{WinHttpOpen(L"Coop/0.1",WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,WINHTTP_NO_PROXY_NAME,WINHTTP_NO_PROXY_BYPASS,0)};
    if (!session.value) throw std::runtime_error("Cannot initialize native downloader");
    WinHttpSetTimeouts(session.value,15000,15000,30000,30000);
    const std::wstring host(components.lpszHostName,components.dwHostNameLength);
    std::wstring path(components.lpszUrlPath,components.dwUrlPathLength);
    if (components.dwExtraInfoLength) path.append(components.lpszExtraInfo,components.dwExtraInfoLength);
    InternetHandle connection{WinHttpConnect(session.value,host.c_str(),components.nPort,0)};
    InternetHandle request{connection.value ? WinHttpOpenRequest(connection.value,L"GET",path.c_str(),nullptr,WINHTTP_NO_REFERER,WINHTTP_DEFAULT_ACCEPT_TYPES,
        components.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0) : nullptr};
    DWORD logon_policy = WINHTTP_AUTOLOGON_SECURITY_LEVEL_HIGH;
    if (request.value && !WinHttpSetOption(request.value,WINHTTP_OPTION_AUTOLOGON_POLICY,&logon_policy,sizeof(logon_policy)))
        throw std::runtime_error("Cannot disable implicit artifact authentication");
    if (!request.value || !WinHttpSendRequest(request.value,WINHTTP_NO_ADDITIONAL_HEADERS,0,WINHTTP_NO_REQUEST_DATA,0,0,0) ||
        !WinHttpReceiveResponse(request.value,nullptr)) throw std::runtime_error("Artifact request failed (Windows error "+std::to_string(GetLastError())+")");
    DWORD status = 0, size = sizeof(status);
    if (!WinHttpQueryHeaders(request.value,WINHTTP_QUERY_STATUS_CODE|WINHTTP_QUERY_FLAG_NUMBER,WINHTTP_HEADER_NAME_BY_INDEX,&status,&size,WINHTTP_NO_HEADER_INDEX) || status != 200)
        throw std::runtime_error("Artifact HTTP status "+std::to_string(status));
    std::ofstream output(destination,std::ios::binary|std::ios::trunc);
    if (!output) throw std::runtime_error("Cannot create artifact file");
    std::array<char,65536> buffer{};
    DWORD count = 0;
    for (;;) {
        if (!WinHttpReadData(request.value,buffer.data(),static_cast<DWORD>(buffer.size()),&count)) throw std::runtime_error("Artifact download interrupted");
        if (!count) break;
        output.write(buffer.data(),count);
        if (!output) throw std::runtime_error("Cannot write artifact file");
    }
    output.close();
    if (!output) throw std::runtime_error("Cannot finish artifact file");
}
void make_junction(const fs::path& link, const fs::path& target) {
    const auto print = fs::absolute(target).wstring();
    const auto substitute = L"\\??\\"+print;
    const auto bytes = (substitute.size()+print.size()+2)*sizeof(wchar_t);
    if (bytes > MAXIMUM_REPARSE_DATA_BUFFER_SIZE-16) throw std::runtime_error("Junction target too long");
    std::vector<unsigned char> buffer(16+bytes,0);
    const DWORD tag = IO_REPARSE_TAG_MOUNT_POINT;
    const WORD data_length = static_cast<WORD>(bytes+8);
    const WORD substitute_length = static_cast<WORD>(substitute.size()*sizeof(wchar_t));
    const WORD print_offset = substitute_length+sizeof(wchar_t);
    const WORD print_length = static_cast<WORD>(print.size()*sizeof(wchar_t));
    std::memcpy(buffer.data(),&tag,sizeof(tag));
    std::memcpy(buffer.data()+4,&data_length,sizeof(data_length));
    std::memcpy(buffer.data()+10,&substitute_length,sizeof(substitute_length));
    std::memcpy(buffer.data()+12,&print_offset,sizeof(print_offset));
    std::memcpy(buffer.data()+14,&print_length,sizeof(print_length));
    std::memcpy(buffer.data()+16,substitute.c_str(),substitute_length);
    std::memcpy(buffer.data()+16+print_offset,print.c_str(),print_length);
    if (!CreateDirectoryW(link.c_str(),nullptr))
        throw std::runtime_error("Cannot create current link directory (Windows error "+std::to_string(GetLastError())+")");
    const auto handle = CreateFileW(link.c_str(),GENERIC_WRITE,0,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT|FILE_FLAG_BACKUP_SEMANTICS,nullptr);
    DWORD returned = 0;
    const bool success = handle != INVALID_HANDLE_VALUE && DeviceIoControl(handle,FSCTL_SET_REPARSE_POINT,buffer.data(),static_cast<DWORD>(buffer.size()),nullptr,0,&returned,nullptr);
    const DWORD error = success ? ERROR_SUCCESS : GetLastError();
    if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
    if (!success) {
        RemoveDirectoryW(link.c_str());
        throw std::runtime_error("Cannot create native junction (Windows error "+std::to_string(error)+")");
    }
}
bool run_shim(int argc, wchar_t** argv, int& result) {
    std::array<wchar_t,32768> module{};
    const auto length = GetModuleFileNameW(nullptr,module.data(),static_cast<DWORD>(module.size()));
    if (!length || length >= module.size()) throw std::runtime_error("Cannot locate command executable");
    const auto metadata = fs::path(module.data()).replace_extension(L".coop-shim.json");
    if (!fs::exists(metadata)) return false;
    const auto record = read_json(metadata);
    const auto target = wide(record.at("target").get<std::string>());
    auto command = quote(target);
    const auto defaults = record.value("arguments",std::string{});
    if (!defaults.empty()) command += L" "+wide(defaults);
    for (int i = 1; i < argc; ++i) command += L" "+quote(argv[i]);
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(target.c_str(),command.data(),nullptr,nullptr,TRUE,0,nullptr,nullptr,&startup,&process))
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
