#pragma once
#include "app.hpp"
namespace coop {
void download_file(const std::string& url, const fs::path& destination);
void make_junction(const fs::path& link, const fs::path& target);
}
