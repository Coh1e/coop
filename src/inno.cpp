#include "inno.hpp"
#include "data.hpp"
#include "native.hpp"
#include "script.hpp"
#include <algorithm>
#include <cstdint>
#include <stdexcept>

namespace coop {
namespace {
std::string lower(std::string text) {
    for (auto& character : text) character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    return text;
}
// Scoop's Expand-InnoArchive switch, verbatim: an empty extract_dir selects {app}; a relative
// extract_dir is resolved below {app}; an explicit {placeholder} path is passed through.
Json tree_totals(const fs::path& root) {
    std::uint64_t files = 0, bytes = 0;
    if (!fs::is_directory(root)) return {{"files",files},{"bytes",bytes}};
    for (const auto& entry : fs::recursive_directory_iterator(root)) {
        const auto status = entry.symlink_status();
        if (fs::is_symlink(status)) throw std::runtime_error("innounp extracted a link, which Coop does not publish");
        if (fs::is_regular_file(status)) {
            ++files;
            bytes += fs::file_size(entry.path());
        }
    }
    return {{"files",files},{"bytes",bytes}};
}
}
InnoHelper inno_helper(const Context& context) {
    std::vector<fs::path> roots{context.root};
    if (context.global_root) roots.push_back(*context.global_root);
    for (const auto& root : roots) {
        for (const auto* helper : {"innounp-unicode","innounp"}) {
            const auto candidate = root/L"apps"/helper/L"current"/L"innounp.exe";
            if (fs::is_regular_file(candidate)) return {candidate,{}};
        }
    }
    return {{},"Inno Setup extraction requires the external innounp helper; Coop looked for "
        "apps/innounp-unicode/current/innounp.exe and apps/innounp/current/innounp.exe under the "
        "selected root (and the global root) and never downloads or installs it. Install the Scoop "
        "package innounp first, or convert the Manifest to an archive that Coop can unpack natively"};
}
std::string inno_selection(const std::string& extract_directory) {
    if (extract_directory.empty()) return "{app}";
    if (extract_directory.front() == '{') return extract_directory;
    return "{app}\\"+extract_directory;
}
InnoArguments inno_arguments(const fs::path& setup, const fs::path& destination,
                             const std::string& extract_directory) {
    InnoArguments result;
    result.selection = inno_selection(extract_directory);
    // Same order as Scoop 0.6.0: -x, -d<destination>, <setup>, -y, -c<selection>.
    result.arguments = {"-x","-d"+path_text(destination),path_text(setup),"-y","-c"+result.selection};
    return result;
}
Json extract_inno_archive(const Context& context, const fs::path& helper, const fs::path& setup,
                          const fs::path& destination, const std::string& extract_directory,
                          const fs::path& transaction, std::size_t index) {
    if (helper.empty() || !fs::is_regular_file(helper))
        throw std::runtime_error("The declared external innounp helper is missing; Coop does not download or install it");
    if (!fs::is_regular_file(setup)) throw std::runtime_error("The Inno Setup artifact is missing: "+path_text(setup));
    fs::create_directories(destination);
    const auto request = inno_arguments(setup,destination,extract_directory);
    const auto base = transaction/(L"inno-"+std::to_wstring(index));
    const auto stdout_log = fs::path(base.wstring()+L".stdout.log");
    const auto stderr_log = fs::path(base.wstring()+L".stderr.log");
    const auto run = run_tool(helper,request.arguments,fs::path{},stdout_log,stderr_log,!context.json_output);
    // Scoop removes the helper's own log file next to the artifact when it is written.
    std::error_code ignored;
    fs::remove(setup.parent_path()/L"innounp.log",ignored);
    const auto totals = tree_totals(destination);
    Json record = {{"mechanism","external innounp helper using Scoop's Expand-InnoArchive arguments"},
        {"helper",path_text(helper)},
        {"helper_sha256",fs::exists(helper) ? sha256_file(helper) : std::string{}},
        {"helper_policy","separate declared software dependency installed in the selected root; Coop detects it, never downloads or installs it, and never substitutes a bundled unpacker"},
        {"arguments",request.arguments},
        {"selection","-c"+request.selection},
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
        {"elevation","not requested by Coop; innounp only unpacks the installer payload into the selected root"},
        {"reboot","not scheduled; the vendor installer is never started"},
        {"installer_effects","not executed: the vendor installer's [Run], [Registry], services, Start Menu entries and uninstall registration are outside this extraction"},
        {"differences","the extracted tree is the declared Inno directory only, with the file contents and timestamps innounp writes; no vendor installation state is created or registered"}};
    if (run.exit_code != 0)
        throw std::runtime_error("innounp could not unpack the Inno Setup artifact "+path_text(setup)+
            " (helper exit code "+std::to_string(run.exit_code)+"; stdout and stderr were captured in "+
            path_text(stdout_log)+" and "+path_text(stderr_log)+")");
    return record;
}
}
