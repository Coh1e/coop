#include "recovery.hpp"
#include "package.hpp"
#include "versions.hpp"
#include <algorithm>
#include <cctype>
#include <iostream>
#include <memory>
#include <set>
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
    return mode == "manual" || status == "manual" || status == "failed" || status == "not-pending";
}
}
Json pending_recovery_report(const Context& context, bool execute,
                             const std::vector<std::string>& requested) {
    Json result = Json::array();
    std::set<std::string> wanted;
    for (const auto& name : requested) if (!name.empty()) wanted.insert(lower_name(name));
    const auto directory = state_directory(context)/L"transactions";
    if (!fs::is_directory(directory)) {
        for (const auto& name : wanted)
            result.push_back({{"package",name},{"mode","none"},{"status","not-pending"},
                {"requested",true},{"skipped",false},{"actions",Json::array()},
                {"reason","No pending transaction for package "+name}});
        return result;
    }
    std::vector<fs::path> journals;
    for (const auto& entry : fs::directory_iterator(directory)) {
        if (!entry.is_directory()) continue;
        const auto journal = entry.path()/L"journal.json";
        if (fs::is_regular_file(journal)) journals.push_back(journal);
    }
    std::sort(journals.begin(),journals.end(),[](const fs::path& a, const fs::path& b) {
        return path_text(a) < path_text(b);
    });
    std::set<std::string> seen;
    for (const auto& journal : journals) {
        Json info;
        bool matched = wanted.empty();
        try {
            const auto value = read_json(journal);
            if (!value.is_object() || value.value("state",std::string{}) != "pending") continue;
            const auto action = value.value("action",std::string{});
            const auto package = lower_name(value.value("package",std::string{}));
            matched = wanted.empty() || (!package.empty() && wanted.contains(package));
            // A scoped command must never run a transaction the caller did not name.
            const bool execute_this = execute && matched;
            // Adoption journals are no longer produced. A leftover journal from that retired path is
            // reported honestly instead of being routed to a removed recovery implementation.
            if (action == "adopt") info = {{"journal",path_text(journal)},{"action",action},{"package",package},
                {"mode","manual"},{"status","manual"},{"actions",Json::array()},{"diagnostics",Json::array()},
                {"conflicts",Json::array()},
                {"reason","Adoption transactions were retired; this journal cannot be recovered automatically. Remove the transaction directory after checking that no original file changed"}};
            else if (action == "cleanup") info = cleanup_recovery_status(context,journal,execute_this);
            else info = package_recovery_status(context,journal,execute_this);
        } catch (const std::exception& error) {
            info = {{"journal",path_text(journal)},{"mode","manual"},{"status","manual"},
                {"reason",std::string("Transaction journal cannot be read: ")+error.what()}};
        }
        if (!info.contains("journal")) info["journal"] = path_text(journal);
        info["requested"] = matched;
        info["skipped"] = !matched;
        if (!matched) {
            const auto reason = info.value("reason",std::string{});
            info["reason"] = std::string("Not requested; transaction was left pending") +
                (reason.empty() ? std::string{} : ": "+reason);
        } else {
            const auto package = lower_name(info.value("package",std::string{}));
            if (!package.empty()) seen.insert(package);
        }
        result.push_back(std::move(info));
    }
    for (const auto& name : wanted) if (!seen.contains(name))
        result.push_back({{"package",name},{"mode","none"},{"status","not-pending"},
            {"requested",true},{"skipped",false},{"actions",Json::array()},
            {"reason","No pending transaction for package "+name}});
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
        else {
            const auto name = lower_name(utf8(arg));
            if (std::find(requested.begin(),requested.end(),name) == requested.end()) requested.push_back(name);
        }
    }
    std::unique_ptr<RootLock> lock;
    if (!dry_run) lock = std::make_unique<RootLock>(context);
    // Records left by interrupted runs are consumed by the report: they name what was running, not
    // what to restore, so a dry run prints them and leaves them in place.
    report_abandoned_runs(context,!dry_run);
    const auto report = pending_recovery_report(context,!dry_run,requested);
    bool failed = false;
    bool remaining = false;
    for (const auto& entry : report) {
        failed = failed || report_failed(entry);
        remaining = remaining || entry.value("skipped",false);
    }
    if (context.json_output) {
        std::cout << report.dump(2,' ',false,Json::error_handler_t::replace) << '\n';
    } else if (report.empty()) {
        std::cout << "No pending transactions\n";
    } else {
        for (const auto& entry : report) {
            const auto package = entry.value("package",std::string{});
            const auto action = entry.value("action",std::string{"unknown"});
            const auto status = entry.value("status",std::string{"unknown"});
            std::cout << (package.empty() ? std::string("transaction") : package) << ": " << action << ": " << status;
            if (entry.value("skipped",false)) std::cout << " (not requested; left pending)";
            std::cout << '\n';
            if (entry.contains("reason")) std::cout << "  " << entry.at("reason").get<std::string>() << '\n';
            if (entry.contains("conflicts")) for (const auto& conflict : entry.at("conflicts"))
                std::cout << "  conflict " << conflict.value("code",std::string{"unknown"}) << ": "
                          << conflict.value("detail",std::string{}) << '\n';
            if (entry.contains("actions")) for (const auto& action_entry : entry.at("actions")) {
                std::cout << "  " << action_entry.value("kind",std::string{"action"}) << ' '
                          << action_entry.value("path",action_entry.value("from",std::string{})) << '\n';
            }
        }
    }
    return failed || remaining ? 1 : 0;
}
}
