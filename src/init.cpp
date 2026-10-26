#include "init.hpp"
#include "data.hpp"
#include <array>
#include <iostream>
#include <stdexcept>

namespace coop {
namespace {
// The shared Scoop layout this client and Scoop both use. Scoop itself creates these directories
// on demand, but a machine without Scoop has no starting point: `coop init` is that starting point
// and creates only what is missing.
constexpr std::array<const wchar_t*,5> standard_layout = {L"apps",L"buckets",L"cache",L"persist",L"shims"};
std::string filesystem_error(const fs::path& path,const std::error_code& error) {
    return path_text(path)+" (filesystem error "+std::to_string(error.value())+")";
}
void write_text_list(const char* label,const std::vector<std::string>& values) {
    std::cout << "  " << label << ": ";
    if (values.empty()) {
        std::cout << "none" << '\n';
        return;
    }
    for (std::size_t index = 0; index < values.size(); ++index) {
        if (index) std::cout << ", ";
        std::cout << values[index];
    }
    std::cout << '\n';
}
}
int init_command(const Context& context,const std::vector<std::wstring>& args) {
    bool dry_run = false;
    for (const auto& argument : args) {
        if (argument == L"--dry-run") { dry_run = true; continue; }
        throw std::runtime_error("init accepts only --dry-run: "+utf8(argument));
    }
    std::error_code error;
    if (fs::exists(context.root,error) && !fs::is_directory(context.root,error))
        throw std::runtime_error("Installation root exists and is not a directory: "+path_text(context.root));
    // Validate every standard path before creating anything so a conflicting entry cannot leave a
    // half-initialized root behind.
    std::array<bool,standard_layout.size()> present{};
    for (std::size_t index = 0; index < standard_layout.size(); ++index) {
        const auto path = context.root/standard_layout[index];
        error.clear();
        if (!fs::exists(path,error)) {
            if (error) throw std::runtime_error("Cannot inspect "+filesystem_error(path,error));
            continue;
        }
        if (!fs::is_directory(path,error)) throw std::runtime_error("Standard layout path exists and is not a directory: "+path_text(path));
        present[index] = true;
    }
    std::vector<std::string> created;
    std::vector<std::string> existing;
    for (std::size_t index = 0; index < standard_layout.size(); ++index)
        (present[index] ? existing : created).push_back(path_text(fs::path(standard_layout[index])));
    if (!dry_run) for (std::size_t index = 0; index < standard_layout.size(); ++index) {
        if (present[index]) continue;
        error.clear();
        fs::create_directories(context.root/standard_layout[index],error);
        if (error) throw std::runtime_error("Cannot create "+filesystem_error(context.root/standard_layout[index],error));
    }
    const bool scoop_present = fs::exists(context.root/L"apps"/L"scoop"/L"current",error);
    if (context.json_output) {
        Json directories = Json::array();
        for (const auto* name : standard_layout) directories.push_back(path_text(fs::path(name)));
        Json result = {{"root",path_text(context.root)},{"dry_run",dry_run},{"directories",directories},
            {"created",created},{"existing",existing},
            {"scoop_installation",{{"present",scoop_present}}}};
        std::cout << result.dump(2) << '\n';
        return 0;
    }
    if (dry_run) std::cout << "Preview: standard Scoop-compatible layout at " << path_text(context.root) << '\n';
    else if (created.empty()) std::cout << "Already initialized: " << path_text(context.root) << '\n';
    else std::cout << "Initialized installation root " << path_text(context.root) << '\n';
    write_text_list(dry_run ? "would create" : "created",created);
    write_text_list("existing",existing);
    std::cout << "  Scoop installation: " << (scoop_present ? "present" : "none") << '\n';
    return 0;
}
}
