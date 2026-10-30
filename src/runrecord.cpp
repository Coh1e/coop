#include "app.hpp"
#include "data.hpp"
#include "progress.hpp"
#include <windows.h>
#include <ctime>
#include <iostream>

namespace coop {
namespace {
std::uint64_t g_run_counter = 0;
std::string timestamp() {
    const auto seconds = std::time(nullptr);
    std::tm local{};
    localtime_s(&local,&seconds);
    char text[32]{};
    std::snprintf(text,sizeof text,"%04d-%02d-%02d %02d:%02d:%02d",local.tm_year+1900,local.tm_mon+1,
        local.tm_mday,local.tm_hour,local.tm_min,local.tm_sec);
    return text;
}
}
RunRecord::RunRecord(const Context& context,std::string command,std::vector<std::string> packages) {
    root_ = context.root;
    std::error_code error;
    // A command that is refused before its first write must not leave a root behind, so the
    // constructor remembers whether the root already existed.
    root_existed_ = fs::exists(root_,error);
    const auto directory = root_/L".coop"/L"runs";
    fs::create_directories(directory,error);
    const auto id = std::to_string(GetCurrentProcessId())+"-"+std::to_string(++g_run_counter)+"-"+
        std::to_string(GetTickCount64());
    path_ = directory/(wide(id)+L".json");
    command_ = std::move(command);
    packages_ = std::move(packages);
    started_ = timestamp();
    save();
    // Every progress line also names the stage, so the record follows the command without the
    // executor knowing that a record exists.
    set_phase_sink([this](const std::string& text) { stage(text); });
}
RunRecord::~RunRecord() {
    set_phase_sink(nullptr);
    std::error_code error;
    fs::remove(path_,error);
    // A root that only saw finished runs keeps no trace of them: the record directory goes, and
    // `.coop` goes with it while it is still empty (the remove fails harmlessly when it is not).
    if (path_.has_parent_path()) fs::remove(path_.parent_path(),error);
    if (path_.parent_path().has_parent_path()) fs::remove(path_.parent_path().parent_path(),error);
    if (!root_existed_) fs::remove(root_,error);
}
void RunRecord::stage(const std::string& text) {
    if (text.empty()) return;
    stage_ = text.substr(0,200);
    try {
        save();
    } catch (const std::exception&) {
        // The record is observational: losing it must never fail the command it describes.
    }
}
void RunRecord::save() {
    const Json record = {{"command",command_},{"packages",packages_},{"pid",GetCurrentProcessId()},
        {"started",started_},{"stage",stage_},{"updated",timestamp()}};
    write_json(path_,record,false);
}

std::size_t report_abandoned_runs(const Context& context,bool consume) {
    const auto directory = context.root/L".coop"/L"runs";
    std::error_code error;
    if (!fs::is_directory(directory,error)) return 0;
    std::size_t count = 0;
    for (const auto& entry : fs::directory_iterator(directory,error)) {
        if (error) break;
        if (!entry.is_regular_file() || entry.path().extension() != L".json") continue;
        Json record = Json::object();
        try {
            const auto stored = read_json(entry.path());
            if (stored.is_object()) record = stored;
        } catch (const std::exception&) { /* A damaged record still says that something was interrupted. */ }
        std::string packages;
        if (record.contains("packages") && record.at("packages").is_array())
            for (const auto& item : record.at("packages"))
                if (item.is_string()) packages += (packages.empty() ? "" : " ")+item.get<std::string>();
        std::cerr << "coop: an interrupted run was recorded: coop "<<record.value("command",std::string{"unknown"});
        if (!packages.empty()) std::cerr << ' ' << packages;
        std::cerr << " (pid "<<record.value("pid",0)<<", started "<<record.value("started",std::string{"unknown"})
                  <<", last stage: "<<record.value("stage",std::string{"unknown"})<<")\n";
        std::cerr << "coop: the record carries no ownership evidence, so nothing is restored from it\n";
        if (consume) {
            std::error_code remove_error;
            fs::remove(entry.path(),remove_error);
        }
        ++count;
    }
    return count;
}
}
