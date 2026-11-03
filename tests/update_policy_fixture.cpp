#include "update_policy.hpp"
#include <iostream>
#include <stdexcept>
#include <string_view>
using namespace coop;
void check(bool value) { if (!value) throw std::runtime_error("Update policy assertion failed"); }
int main() {
    try {
        struct Case { std::string_view a,b; VersionOrder order; };
        for (const auto& item : {Case{"1.9","1.10",VersionOrder::higher},
            Case{"2","1",VersionOrder::lower},Case{"1.0","v1.0.0",VersionOrder::equal},
            Case{"2026.01.01","2026.11.03",VersionOrder::higher},
            Case{"999999999999999999999999","1000000000000000000000000",VersionOrder::higher},
            Case{"1.0.0-rc.9","1.0.0-rc.10",VersionOrder::higher},Case{"1.0.0-rc.1","1.0.0",VersionOrder::higher},
            Case{"1.0.0","1.0.0-alpha",VersionOrder::lower},Case{"1.0.0+one","1.0.0+two",VersionOrder::equal},
            Case{"1.0.0-alpha","1.0.0-alpha.1",VersionOrder::higher},Case{"1.0.0-1","1.0.0-alpha",VersionOrder::higher},
            Case{"nightly","nightly",VersionOrder::equal},Case{"nightly","latest",VersionOrder::unknown},
            Case{"2026-10-01","2026-9-01",VersionOrder::unknown},
            Case{"1.0a","1.0b",VersionOrder::unknown},Case{"","1",VersionOrder::unknown},
            Case{"1..0","2",VersionOrder::unknown},Case{"1.0.0-01","2",VersionOrder::unknown},
            Case{"1+","2",VersionOrder::unknown}}) {
            check(compare_update_versions(item.a,item.b) == item.order);
            const auto reverse = compare_update_versions(item.b,item.a);
            check(reverse == (item.order == VersionOrder::higher ? VersionOrder::lower : item.order == VersionOrder::lower ? VersionOrder::higher : item.order));
        }
        for (const bool force : {false,true}) {
            check(decide_update("1","2",true,false,force).changes_installation);
            check(decide_update("2","1",true,false,force).blocked);
            check(decide_update("nightly","latest",true,false,force).blocked);
            check(decide_update("1","2",true,true,force).blocked);
            const auto changed = decide_update("1","1",true,false,force);
            check(changed.state == UpdateState::manifest_changed && !changed.blocked && changed.changes_installation == force);
            const auto current = decide_update("1","1",false,false,force);
            check(current.state == UpdateState::current && !current.blocked && current.changes_installation == force);
        }
        std::cout << "PASS update version boundaries and force guards\n";
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
