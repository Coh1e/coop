#include "timings.hpp"
#include <algorithm>

namespace coop {
namespace {
Timings* g_timings = nullptr;
}
void Timings::add(const std::string& operation,double seconds) {
    const auto existing = std::find_if(entries_.begin(),entries_.end(),
        [&](const Entry& entry) { return entry.operation == operation; });
    if (existing == entries_.end()) {
        entries_.push_back({operation,seconds,1});
        return;
    }
    existing->seconds += seconds;
    ++existing->runs;
}
void Timings::reset() { entries_.clear(); }
bool timings_is_download(const std::string& operation) { return operation == "download"; }
Json Timings::result() const {
    Json steps = Json::array();
    double download = 0.0, local = 0.0;
    for (const auto& entry : entries_) {
        steps.push_back({{"operation",entry.operation},{"seconds",entry.seconds},{"runs",entry.runs}});
        if (timings_is_download(entry.operation)) download += entry.seconds;
        else local += entry.seconds;
    }
    return Json{{"steps",steps},{"download_seconds",download},{"local_seconds",local},
        {"total_seconds",download+local}};
}
void set_timings(Timings* timings) { g_timings = timings; }
Timings* active_timings() { return g_timings; }
void timings_add(const std::string& operation,double seconds) {
    if (g_timings) g_timings->add(operation,seconds);
}
}