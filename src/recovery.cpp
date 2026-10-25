#include "recovery.hpp"
#include "package.hpp"
#include "versions.hpp"
#include <algorithm>
#include <cctype>
#include <iostream>
#include <memory>
#include <stdexcept>

namespace coop {
namespace {
std::string lower_name(std::string value) {
    for (auto& character : value)
        character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    return value;
}
bool report_failed(const Json& entry) {
    const auto mode = entry.value("mode",std::string{});
    const auto status = entry.value("status",std::string{});
    return mode == "manual" || status == "manual" || status == "failed";
}
}
Json pending_recovery_report(const Context& context, bool execute) {
    Json result = Json::array();
    const auto directory = context.root/L".coop"/L"transactions";
    if (!fs::is_directory(directory)) return result;
    std::vector<fs::path> journals;
    for (const auto& entry : fs::directory_iterator(directory)) {
        if (!entry.is_directory()) continue;
        const auto journal = entry.path()/L"journal.json";
        if (fs::is_regular_file(journal)) journals.push_back(journal);
    }
    std::sort(journals.begin(),journals.end(),[](const fs::path& a, const fs::path& b) {
        return path_text(a) < path_text(b);
    });
    for (const auto& journal : journals) {
        Json info;
        try {
            const auto value = read_json(journal);
            if (!value.is_object() || value.value("state",std::string{}) != "pending") continue;
            const auto action = value.value("action",std::string{});
            if (action == "adopt") info = adoption_recovery_status(context,journal,execute);
            else if (action == "cleanup") info = cleanup_recovery_status(context,journal,execute);
            else info = package_recovery_status(context,journal,execute);
        } catch (const std::exception& error) {
            info = {{"journal",path_text(journal)},{"mode","manual"},{"status","manual"},
                {"reason",std::string("Transaction journal cannot be read: ")+error.what()}};
        }
        if (!info.contains("journal")) info["journal"] = path_text(journal);
        result.push_back(std::move(info));
    }
    return result;
}
int recovery_command(const Context& context, const std::vector<std::wstring>& args) {
    bool dry_run = false;
    std::vector<std::string> requested;
    for (const auto& arg : args) {
        if (arg == L"--dry-run") {
            if (dry_run) throw std::runtime_error("--dry-run was specified more than once");
            dry_run = true;
        } else if (arg.starts_with(L"--")) throw std::runtime_error("Unknown recover option");
        else requested.push_back(lower_name(utf8(arg)));
    }
    std::unique_ptr<RootLock> lock;
    if (!dry_run) lock = std::make_unique<RootLock>(context.root);
    auto report = pending_recovery_report(context,!dry_run);
    if (!requested.empty()) {
        Json filtered = Json::array();
        for (const auto& entry : report) {
            const auto name = lower_name(entry.value("package",std::string{}));
            if (std::find(requested.begin(),requested.end(),name) != requested.end())
                filtered.push_back(entry);
        }
        report = std::move(filtered);
    }
    bool failed = false;
    for (const auto& entry : report) failed = failed || report_failed(entry);
    if (context.json_output) {
        std::cout << report.dump(2,' ',false,Json::error_handler_t::replace) << '\n';
    } else if (report.empty()) {
        std::cout << "No pending transactions\n";
    } else {
        for (const auto& entry : report) {
            const auto package = entry.value("package",std::string{});
            const auto action = entry.value("action",std::string{"unknown"});
            const auto status = entry.value("status",std::string{"unknown"});
            std::cout << (package.empty() ? std::string("transaction") : package) << ": " << action << ": " << status << '\n';
            if (entry.contains("reason")) std::cout << "  " << entry.at("reason").get<std::string>() << '\n';
            if (entry.contains("actions")) for (const auto& action_entry : entry.at("actions")) {
                std::cout << "  " << action_entry.value("kind",std::string{"action"}) << ' '
                          << action_entry.value("path",action_entry.value("from",std::string{})) << '\n';
            }
        }
    }
    return failed ? 1 : 0;
}
}
