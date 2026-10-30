#include "nsis.hpp"
#include "data.hpp"
#include "native.hpp"
#include "script.hpp"
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <stdexcept>
#include <vector>

namespace coop {
namespace {
// NSIS FirstHeader signature: the 0xDEADBEEF magic followed by the ASCII marker. 7-Zip's own NSIS
// handler finds the same header; the declared download name never decides how the payload is read.
constexpr unsigned char nsis_signature[] = {0xEF,0xBE,0xAD,0xDE,'N','u','l','l','s','o','f','t','I','n','s','t'};
Json tree_totals(const fs::path& root) {
    std::uint64_t files = 0, bytes = 0;
    if (!fs::is_directory(root)) return {{"files",files},{"bytes",bytes}};
    for (const auto& entry : fs::recursive_directory_iterator(root)) {
        const auto status = entry.symlink_status();
        if (fs::is_symlink(status)) throw std::runtime_error("7-Zip extracted a link, which Coop does not publish");
        if (fs::is_regular_file(status)) {
            ++files;
            bytes += fs::file_size(entry.path());
        }
    }
    return {{"files",files},{"bytes",bytes}};
}
}
NsisHelper nsis_helper(const Context& context) {
    std::vector<fs::path> roots{context.root};
    if (context.global_root) roots.push_back(*context.global_root);
    for (const auto& root : roots) {
        const auto candidate = root/L"apps"/L"7zip"/L"current"/L"7z.exe";
        if (fs::is_regular_file(candidate)) return {candidate,{}};
    }
    return {{},"NSIS installer extraction requires the external 7-Zip helper; Coop looked for "
        "apps/7zip/current/7z.exe under the selected root (and the global root) and never downloads "
        "or installs it. Install the Scoop package 7zip first, or use an archive Coop can unpack natively"};
}
NsisPayload inspect_nsis_payload(const fs::path& path) {
    NsisPayload result;
    std::ifstream file(path,std::ios::binary);
    if (!file) return result;
    char magic[2]{};
    file.read(magic,2);
    if (file.gcount() != 2 || magic[0] != 'M' || magic[1] != 'Z') return result;
    file.clear();
    file.seekg(0,std::ios::beg);
    constexpr std::size_t chunk = 1u << 20;
    constexpr std::size_t pattern = sizeof(nsis_signature);
    std::vector<char> buffer(chunk+pattern-1);
    std::uint64_t file_offset = 0;
    std::size_t carry = 0;
    for (;;) {
        file.read(buffer.data()+carry,static_cast<std::streamsize>(chunk));
        const auto read = static_cast<std::size_t>(file.gcount());
        if (read == 0) break;
        const auto total = carry+read;
        for (std::size_t index = 0; index+pattern <= total; ++index) {
            if (std::memcmp(buffer.data()+index,nsis_signature,pattern) == 0) {
                result.detected = true;
                result.signature_offset = file_offset+index;
                return result;
            }
        }
        carry = std::min(total,pattern-1);
        std::memmove(buffer.data(),buffer.data()+total-carry,carry);
        file_offset += total-carry;
    }
    return result;
}
NsisArguments nsis_arguments(const fs::path& payload, const fs::path& destination,
                             const std::string& extract_directory) {
    NsisArguments result;
    // Same order as Scoop 0.6.0's Expand-7zipArchive: x, artifact, -o<destination>, -xr!*.nsis, -y.
    result.arguments = {"x",path_text(payload),"-o"+path_text(destination),"-xr!*.nsis","-y"};
    if (!extract_directory.empty()) {
        result.selection = "-ir!"+extract_directory+"\\*";
        result.arguments.push_back(result.selection);
    } else {
        result.selection = "(whole installer payload)";
    }
    return result;
}
Json extract_nsis_archive(const Context& context, const fs::path& helper, const fs::path& payload,
                          const fs::path& destination, const std::string& extract_directory,
                          const fs::path& transaction, std::size_t index) {
    if (helper.empty() || !fs::is_regular_file(helper))
        throw std::runtime_error("The declared external 7-Zip helper is missing; Coop does not download or install it");
    if (!fs::is_regular_file(payload)) throw std::runtime_error("The NSIS installer payload is missing: "+path_text(payload));
    const auto detection = inspect_nsis_payload(payload);
    if (!detection.detected) throw std::runtime_error("The artifact is not an NSIS installer payload: "+path_text(payload));
    fs::create_directories(destination);
    const auto request = nsis_arguments(payload,destination,extract_directory);
    const auto base = transaction/(L"nsis-"+std::to_wstring(index));
    const auto stdout_log = fs::path(base.wstring()+L".stdout.log");
    const auto stderr_log = fs::path(base.wstring()+L".stderr.log");
    const auto run = run_tool(helper,request.arguments,fs::path{},stdout_log,stderr_log,!context.json_output);
    const auto totals = tree_totals(destination);
    Json record = {{"mechanism","external 7-Zip helper using Scoop's Expand-7zipArchive arguments"},
        {"helper",path_text(helper)},
        {"helper_sha256",fs::exists(helper) ? sha256_file(helper) : std::string{}},
        {"helper_policy","separately installed 7-Zip software package; Coop detects it, never downloads, installs or bundles it, and never substitutes a bundled unpacker"},
        {"arguments",request.arguments},
        {"selection",request.selection},
        {"detection",{{"signature","FirstHeader magic DE AD BE EF followed by the ASCII marker NullsoftInst"},
                      {"offset",detection.signature_offset}}},
        {"exit_code",run.exit_code},
        {"stdout_log",path_text(stdout_log)},
        {"stderr_log",path_text(stderr_log)},
        {"stdout_bytes",run.stdout_bytes},
        {"stderr_bytes",run.stderr_bytes},
        {"stdout_tail",script_json_text(run.stdout_tail)},
        {"stderr_tail",script_json_text(run.stderr_tail)},
        {"files",totals.at("files")},
        {"bytes",totals.at("bytes")},
        {"installer_executed",false},
        {"elevation","not requested by Coop; 7-Zip only unpacks the installer payload into the selected root"},
        {"reboot","not scheduled; the vendor setup.exe is never started"},
        {"installer_effects","not executed: the vendor setup.exe's install directory, registry, services, Start Menu entries, [Run] steps and uninstall registration are outside this extraction"},
        {"differences","the extracted tree is the whole NSIS payload, or the declared extract_dir selection, with the file contents and timestamps 7-Zip writes; $PLUGINSDIR, Uninstall.exe and similar payload entries remain until the Manifest's own hooks remove them, exactly as with Scoop's Expand-7zipArchive"}};
    if (run.exit_code != 0)
        throw std::runtime_error("7-Zip could not unpack the NSIS installer payload "+path_text(payload)+
            " (helper exit code "+std::to_string(run.exit_code)+"; stdout and stderr were captured in "+
            path_text(stdout_log)+" and "+path_text(stderr_log)+")");
    return record;
}
SevenZipSfx inspect_seven_zip_sfx(const fs::path& path) {
    SevenZipSfx result;
    constexpr unsigned char signature[6] = {0x37,0x7A,0xBC,0xAF,0x27,0x1C};
    std::ifstream file(path,std::ios::binary);
    if (!file) return result;
    char magic[2]{};
    file.read(magic,2);
    if (file.gcount() != 2 || magic[0] != 'M' || magic[1] != 'Z') return result;
    file.clear();
    file.seekg(0,std::ios::beg);
    constexpr std::size_t chunk = 1u << 20;
    std::vector<char> buffer(chunk+sizeof(signature)-1);
    std::uint64_t file_offset = 0;
    std::size_t carry = 0;
    for (;;) {
        file.read(buffer.data()+carry,static_cast<std::streamsize>(chunk));
        const auto read = static_cast<std::size_t>(file.gcount());
        if (read == 0) break;
        const auto total = carry+read;
        for (std::size_t index = 0; index+sizeof(signature) <= total; ++index) {
            if (std::memcmp(buffer.data()+index,signature,sizeof(signature)) == 0) {
                result.detected = true;
                result.signature_offset = file_offset+index;
                return result;
            }
        }
        carry = std::min(total,sizeof(signature)-1);
        std::memmove(buffer.data(),buffer.data()+total-carry,carry);
        file_offset += total-carry;
    }
    return result;
}
Json extract_seven_zip_sfx(const Context& context, const fs::path& helper, const fs::path& archive,
                           const fs::path& destination, const std::string& extract_directory,
                           const fs::path& transaction, std::size_t index) {
    if (helper.empty() || !fs::is_regular_file(helper))
        throw std::runtime_error("7z self-extracting archive extraction requires the external 7-Zip helper; "
                                 "Coop looked for apps/7zip/current/7z.exe under the selected root and never "
                                 "downloads or installs it");
    const auto detection = inspect_seven_zip_sfx(archive);
    if (!detection.detected) throw std::runtime_error("The artifact is not a 7z self-extracting archive: "+path_text(archive));
    fs::create_directories(destination);
    // Same argument order as Scoop's Expand-7zipArchive: x, artifact, -o<destination>, -y.
    std::vector<std::string> arguments{"x",path_text(archive),"-o"+path_text(destination),"-y"};
    std::string selection = "(whole archive)";
    if (!extract_directory.empty()) {
        selection = "-ir!"+extract_directory+"\\*";
        arguments.push_back(selection);
    }
    const auto base = transaction/(L"7zsfx-"+std::to_wstring(index));
    const auto stdout_log = fs::path(base.wstring()+L".stdout.log");
    const auto stderr_log = fs::path(base.wstring()+L".stderr.log");
    const auto run = run_tool(helper,arguments,fs::path{},stdout_log,stderr_log,!context.json_output);
    const auto totals = tree_totals(destination);
    Json record = {{"mechanism","external 7-Zip helper reading a 7z self-extracting archive"},
        {"helper",path_text(helper)},
        {"helper_sha256",fs::exists(helper) ? sha256_file(helper) : std::string{}},
        {"helper_policy","separately installed 7-Zip software package; Coop detects it, never downloads, installs or bundles it"},
        {"arguments",arguments},
        {"selection",selection},
        {"detection",{{"signature","MZ header followed by the 7z signature 37 7A BC AF 27 1C"},
                      {"offset",detection.signature_offset}}},
        {"exit_code",run.exit_code},
        {"stdout_log",path_text(stdout_log)},
        {"stderr_log",path_text(stderr_log)},
        {"stdout_tail",script_json_text(run.stdout_tail)},
        {"stderr_tail",script_json_text(run.stderr_tail)},
        {"files",totals.at("files")},
        {"bytes",totals.at("bytes")},
        {"installer_executed",false},
        {"reason","the native archive reader rejects the stream options of this SFX, so the same helper Scoop uses unpacks it without running the stub"}};
    if (run.exit_code != 0)
        throw std::runtime_error("7-Zip could not unpack the 7z self-extracting archive "+path_text(archive)+
            " (helper exit code "+std::to_string(run.exit_code)+"; stdout and stderr were captured in "+
            path_text(stdout_log)+" and "+path_text(stderr_log)+")");
    return record;
}
}
