#pragma once
#include "app.hpp"
#include <nlohmann/json.hpp>

namespace coop {
using Json = nlohmann::json;
Json read_json(const fs::path& path);
fs::path installed_record(const fs::path& directory, const std::wstring& kind);
Json installed_packages(const Context& context);
Json catalog(const Context& context);
Json bucket_sources(const Context& context);
void write_json(const fs::path& path, const Json& value, bool compact = false);
void validate_component(const std::string& value);
class RootLock {
public:
    explicit RootLock(const fs::path& root);
    ~RootLock();
    RootLock(const RootLock&) = delete;
    RootLock& operator=(const RootLock&) = delete;
private:
    void* handle_;
};
}
