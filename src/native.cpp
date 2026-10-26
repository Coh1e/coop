#include "native.hpp"
#include "data.hpp"
#include <windows.h>
#include <winhttp.h>
#include <winioctl.h>
#include <shlwapi.h>
#include <fstream>
#include <array>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <thread>

namespace coop {
namespace {
struct InternetHandle {
    HINTERNET value;
    ~InternetHandle() { if (value) WinHttpCloseHandle(value); }
};
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
    // Reparse points use the NT namespace (\??\) directly, which is not limited by MAX_PATH.
    // A \\?\ prefix copied from an extended input would produce \??\\\?\... and make the link
    // unusable, so the plain drive/UNC spelling is stored while long targets stay fully supported.
    auto text = fs::absolute(target).wstring();
    if (text.starts_with(L"\\\\?\\UNC\\")) text = L"\\\\"+text.substr(8);
    else if (text.starts_with(L"\\\\?\\")) text = text.substr(4);
    else if (text.starts_with(L"\\\\.\\")) text = text.substr(4);
    const auto print = text;
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
namespace {
constexpr std::size_t max_tail_bytes = 16384;
struct FileHandle {
    HANDLE value = INVALID_HANDLE_VALUE;
    FileHandle() = default;
    explicit FileHandle(HANDLE handle) : value(handle) {}
    ~FileHandle() { if (value != INVALID_HANDLE_VALUE) CloseHandle(value); }
    FileHandle(const FileHandle&) = delete;
    FileHandle& operator=(const FileHandle&) = delete;
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
            throw std::runtime_error("Cannot write the external tool output log");
    }
    void close() { if (value) { std::fclose(value); value = nullptr; } }
};
}
ToolRun run_tool(const fs::path& executable, const std::vector<std::string>& arguments,
                 const fs::path& working_directory, const fs::path& stdout_log,
                 const fs::path& stderr_log, bool echo) {
    std::wstring command_line = quote_argument(executable.wstring());
    for (const auto& argument : arguments) command_line += L" "+quote_argument(wide(argument));
    SECURITY_ATTRIBUTES attributes{sizeof(SECURITY_ATTRIBUTES),nullptr,TRUE};
    FileHandle out_read, out_write, err_read, err_write;
    if (!CreatePipe(&out_read.value,&out_write.value,&attributes,0)) throw std::runtime_error("Cannot create the external tool stdout pipe");
    if (!CreatePipe(&err_read.value,&err_write.value,&attributes,0)) throw std::runtime_error("Cannot create the external tool stderr pipe");
    if (!SetHandleInformation(out_read.value,HANDLE_FLAG_INHERIT,0) || !SetHandleInformation(err_read.value,HANDLE_FLAG_INHERIT,0))
        throw std::runtime_error("Cannot isolate the external tool output pipes");
    FileHandle input(CreateFileW(L"NUL",GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,&attributes,OPEN_EXISTING,0,nullptr));
    if (input.value == INVALID_HANDLE_VALUE) throw std::runtime_error("Cannot open the external tool stdin device");
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES|STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_HIDE;
    startup.hStdInput = input.value;
    startup.hStdOutput = out_write.value;
    startup.hStdError = err_write.value;
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(nullptr,command_line.data(),nullptr,nullptr,TRUE,CREATE_NO_WINDOW,nullptr,
                        working_directory.empty() ? nullptr : working_directory.c_str(),&startup,&process))
        throw std::runtime_error("Cannot start the external tool "+path_text(executable)+" (Windows error "+
            std::to_string(GetLastError())+")");
    FileHandle process_handle(process.hProcess);
    CloseHandle(process.hThread);
    out_write.reset();
    err_write.reset();
    ToolRun result;
    LogFile stdout_file, stderr_file;
    stdout_file.open(stdout_log);
    stderr_file.open(stderr_log);
    std::thread stdout_thread(drain,out_read.value,std::ref(result.stdout_bytes),std::ref(result.stdout_tail),
        stdout_file.value,echo,stdout);
    std::thread stderr_thread(drain,err_read.value,std::ref(result.stderr_bytes),std::ref(result.stderr_tail),
        stderr_file.value,echo,stderr);
    WaitForSingleObject(process_handle.value,INFINITE);
    DWORD exit_code = 1;
    GetExitCodeProcess(process_handle.value,&exit_code);
    stdout_thread.join();
    stderr_thread.join();
    const bool log_failed = std::ferror(stdout_file.value) != 0 || std::ferror(stderr_file.value) != 0;
    stdout_file.close();
    stderr_file.close();
    result.exit_code = static_cast<int>(exit_code);
    if (log_failed) throw std::runtime_error("Cannot finish the external tool output log");
    return result;
}
}

