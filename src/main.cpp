#include <iostream>
#include <string_view>

int wmain(int argc, wchar_t** argv) {
    if (argc == 1 || (argc == 2 && std::wstring_view(argv[1]) == L"--help")) {
        std::cout << "Usage: coop <command> [options]\n"
                     "\nOptions:\n"
                     "  --version  Print version\n"
                     "  --help     Print help\n";
        return 0;
    }
    if (argc == 2 && std::wstring_view(argv[1]) == L"--version") {
        std::cout << "coop " COOP_VERSION "\n";
        return 0;
    }
    std::cerr << "coop: unknown command; use --help\n";
    return 2;
}
