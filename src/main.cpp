#include <iostream>
#include <string_view>
#include "app.hpp"
#include "package.hpp"
#include "native.hpp"
#include <windows.h>

int wmain(int argc, wchar_t** argv) {
    try {
        int result = 0;
        if (coop::run_shim(argc,argv,result)) return result;
    } catch (const std::exception& error) { std::cerr << "coop: " << error.what() << '\n'; return 1; }
    if (argc == 1 || (argc == 2 && std::wstring_view(argv[1]) == L"--help")) {
        std::cout << "Usage: coop <command> [options]\n"
                     "\nOptions:\n"
                     "  --version  Print version\n"
                     "  --help     Print help\n"
                     "  --root <path>  Select installation root\n"
                     "  --global-root <path>  Read a global installation root\n"
                     "  --json     Print machine-readable query results\n"
                     "\nCommands:\n  list\n  search <query>\n  info [bucket/]package\n";
        return 0;
    }
    if (argc == 2 && std::wstring_view(argv[1]) == L"--version") {
        std::cout << "coop " COOP_VERSION "\n";
        return 0;
    }
    try {
        coop::Context context;
        std::string architecture;
        std::vector<std::wstring> arguments;
        for (int i = 1; i < argc; ++i) {
            const std::wstring_view arg(argv[i]);
            if (arg == L"--root" || arg == L"--global-root") {
                if (++i == argc) throw std::runtime_error("Root option requires a path");
                if (arg == L"--root") context.root = argv[i];
                else context.global_root = argv[i];
            } else if (arg == L"--arch") {
                if (++i == argc) throw std::runtime_error("--arch requires an architecture");
                architecture = coop::utf8(argv[i]);
            } else if (arg == L"--json") context.json_output = true;
            else arguments.emplace_back(arg);
        }
        if (arguments.size() >= 1 && (arguments[0] == L"list" || arguments[0] == L"search" || arguments[0] == L"info" || arguments[0] == L"bucket" || arguments[0] == L"install" || arguments[0] == L"update" || arguments[0] == L"uninstall" || arguments[0] == L"adopt")) {
            if (context.root.empty()) {
                wchar_t profile[32768]{};
                const auto length = GetEnvironmentVariableW(L"USERPROFILE", profile, 32768);
                if (!length || length >= 32768) throw std::runtime_error("Use --root to specify an installation root");
                context.root = coop::fs::path(profile) / L"scoop";
            }
            const auto command = arguments.front();
            arguments.erase(arguments.begin());
            context.root = coop::fs::absolute(context.root).lexically_normal();
            if (context.global_root) context.global_root = coop::fs::absolute(*context.global_root).lexically_normal();
            if (command == L"bucket") return coop::bucket_command(context,arguments);
            if (command == L"install" || command == L"update" || command == L"uninstall" || command == L"adopt")
                return coop::package_command(context,command,arguments,architecture);
            return coop::query(context, command, arguments);
        }
        std::cerr << "coop: unknown command; use --help\n";
        return 2;
    } catch (const std::exception& error) {
        std::cerr << "coop: " << error.what() << '\n';
        return 1;
    }
}
