#pragma once
#include "data.hpp"
#include <string>
#include <vector>

namespace coop {
// Per-run attribution of wall time: how much of an install was the network and how much was this
// machine. The distinction is the whole point - a number that mixes both cannot be compared with
// another client, which is why the earlier timing table was withdrawn.
//
// The download step is the only one that waits on the network. Everything else - hashing, extracting,
// publishing entries, committing - is local work.
class Timings {
public:
    void add(const std::string& operation,double seconds);
    void reset();
    Json result() const;
private:
    struct Entry {
        std::string operation;
        double seconds = 0.0;
        std::size_t runs = 0;
    };
    std::vector<Entry> entries_;
};
// The recorder belongs to one command. It is installed for write commands only.
void set_timings(Timings* timings);
Timings* active_timings();
void timings_add(const std::string& operation,double seconds);
bool timings_is_download(const std::string& operation);
}