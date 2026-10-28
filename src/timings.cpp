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
        entries_.push_back({operation,seconds,0,1});
        return;
    }
    existing->seconds += seconds;
    ++existing->runs;
}
void Timings::add_bytes(const std::string& operation,std::uint64_t bytes) {
    for (auto& entry : entries_) {
        if (entry.operation != operation) continue;
        entry.bytes += bytes;
        return;
    }
    // The step that reports bytes may not have closed yet; create it and let add() merge.
    entries_.push_back({operation,0.0,bytes,0});
}
Json Timings::result() const {
    Json steps = Json::array();
    double download = 0.0, local = 0.0;
    for (const auto& entry : entries_) {
        steps.push_back({{"operation",entry.operation},{"seconds",entry.seconds},
            {"bytes",entry.bytes},{"runs",entry.runs}});
        // A download step that moved no bytes never waited on the network: a cache hit is local work,
        // and classifying by the transferred bytes keeps the split honest without a second bucket.
        if (entry.operation == "download" && entry.bytes > 0) download += entry.seconds;
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
void timings_add_bytes(const std::string& operation,std::uint64_t bytes) {
    if (g_timings) g_timings->add_bytes(operation,bytes);
}
}
