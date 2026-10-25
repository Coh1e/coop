#pragma once
#include "app.hpp"
#include <nlohmann/json.hpp>

namespace coop {
using Json = nlohmann::json;
Json read_json(const fs::path& path);
fs::path installed_record(const fs::path& directory, const std::wstring& kind);
Json installed_packages(const Context& context);
Json catalog(const Context& context);
}
