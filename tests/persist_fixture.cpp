#include <windows.h>
#include <array>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>

namespace fs = std::filesystem;

int wmain(int argc, wchar_t** argv) {
    (void)argc;
    (void)argv;
    std::array<wchar_t,32768> module{};
    const auto length = GetModuleFileNameW(nullptr,module.data(),static_cast<DWORD>(module.size()));
    if (!length || length >= module.size()) {
        std::cerr << "persist-fixture: cannot locate its own executable\n";
        return 1;
    }
    const auto directory = fs::path(module.data()).parent_path();
    const auto read = [](const fs::path& path) {
        std::ifstream input(path,std::ios::binary);
        std::string value;
        if (!input || !std::getline(input,value)) return std::string("<missing>");
        return value;
    };
    std::cout << "persist-fixture " FIXTURE_VERSION
              << " config=" << read(directory/L"config"/L"settings.ini")
              << " file=" << read(directory/L"sample.ini") << '\n';
    return 0;
}
