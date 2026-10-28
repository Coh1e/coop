#pragma once
#include "data.hpp"
#include <cstdint>
#include <string>
#include <vector>

namespace coop {
// Per-run attribution of wall time: how much of an install was the network and how much was this
// machine. The distinction is the whole point - a number that mixes both cannot be compared with
// another client, which is why the earlier timing table was withdrawn.
//
// The download step is the only one that waits on the network, and only when it actually moved bytes:
// a cache hit runs inside that step but transfers nothing, so it counts as local work. Everything else
// - hashing, extracting, publishing entries, committing - is local too.
class Timings {
public:
    void add(const std::string& operation,double seconds);
    // Attaches a byte count to a step that moved data, so a duration can be checked against
    // "bytes divided by the transfer rate" instead of being taken on trust.
    void add_bytes(const std::string& operation,std::uint64_t bytes);
    Json result() const;
private:
    struct Entry {
        std::string operation;
        double seconds = 0.0;
        std::uint64_t bytes = 0;
        std::size_t runs = 0;
    };
    std::vector<Entry> entries_;
};
// The recorder belongs to one command. It is installed for write commands only.
void set_timings(Timings* timings);
Timings* active_timings();
void timings_add(const std::string& operation,double seconds);
void timings_add_bytes(const std::string& operation,std::uint64_t bytes);
}
