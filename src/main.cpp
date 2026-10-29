#include <iostream>
#include <string_view>
#include "app.hpp"
#include "package.hpp"
#include "progress.hpp"
#include "timings.hpp"
#include "native.hpp"
#include "recovery.hpp"
#include "shim.hpp"
#include "init.hpp"
#include <windows.h>

namespace {
// Coop writes UTF-8 to stdout/stderr so redirected output and JSON stay stable. When attached to a
// real console, the console must interpret those bytes as UTF-8 too; the previous code page is
// restored before the process exits so the invoking shell is not changed permanently.
class ConsoleOutputEncoding {
public:
    ConsoleOutputEncoding() {
        const auto standard = GetStdHandle(STD_OUTPUT_HANDLE);
        const auto diagnostic = GetStdHandle(STD_ERROR_HANDLE);
        DWORD mode = 0;
        const bool output_console = standard != INVALID_HANDLE_VALUE && standard != nullptr && GetConsoleMode(standard,&mode);
        const bool error_console = diagnostic != INVALID_HANDLE_VALUE && diagnostic != nullptr && GetConsoleMode(diagnostic,&mode);
        if (!output_console && !error_console) return;
        original_ = GetConsoleOutputCP();
        if (original_ != 0 && original_ != CP_UTF8) SetConsoleOutputCP(CP_UTF8);
    }
    ~ConsoleOutputEncoding() {
        // Flush while the UTF-8 code page is still active so the last buffered line is translated
        // correctly, then restore the invoking shell's code page.
        std::cout.flush();
        std::cerr.flush();
        if (original_ != 0 && original_ != CP_UTF8) SetConsoleOutputCP(original_);
    }
    ConsoleOutputEncoding(const ConsoleOutputEncoding&) = delete;
    ConsoleOutputEncoding& operator=(const ConsoleOutputEncoding&) = delete;
private:
    UINT original_ = 0;
};
}

int wmain(int argc, wchar_t** argv) {
    ConsoleOutputEncoding console_encoding;
    try {
        int result = 0;
        if (coop::run_shim(argc,argv,result)) return result;
    } catch (const std::exception& error) { std::cerr << "coop: " << error.what() << '\n'; return 1; }
    if (argc == 1 || (argc == 2 && std::wstring_view(argv[1]) == L"--help")) {
        std::cout << "Usage: coop <command> [options]\n"
                     "\nOptions:\n"
                     "  --version  Print version\n"
                     "  --help     Print help\n"
                     "  --root <path>  Select installation root (also --root=<path>)\n"
                     "  --global-root <path>  Read a global installation root (also --global-root=<path>)\n"
                     "  --arch 64bit|32bit|arm64  Select package architecture (also --arch=<value>)\n"
                     "  --dry-run  Preview without changing state\n"
                     "  --json     Print machine-readable results\n"
                     "  --timings  Print the network and local time a write command spent, and record it\n"
                     "             under <root>/.coop/timings/ for later comparison\n"
                     "\nOutput is UTF-8; exit codes: 0 success, 1 operational or partial-batch failure,\n"
                     "2 command-line misuse.\n"
                     "\nCommands:\n  init [--dry-run]\n  list [query]\n  search [query]\n  info [bucket/]package\n"
                     "  status [-l]\n  prefix <package>\n  cat <package>\n  which <command>\n  home <package>\n"
                     "  depends <package>\n  export\n  checkup\n  help [command]\n"
                     "  bucket list|add|rm|remove|update ...\n"
                     "  install <package>... [--dry-run]\n"
                     "  update [package... | *] [--dry-run]\n"
                     "  uninstall <package>... [--purge] [--dry-run]\n"
                     "  reset <package>@<version> [--dry-run]\n"
                     "  cleanup [package...] [--dry-run]\n"
                     "  recover [package...] [--dry-run]\n";
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
        const auto option_value = [argc,argv](int& index, std::wstring_view arg, std::wstring_view name) -> std::wstring {
            const std::wstring prefix = std::wstring(name)+L"=";
            if (std::wstring_view(arg).starts_with(prefix)) return std::wstring(arg.substr(prefix.size()));
            if (++index == argc) throw coop::UsageError(coop::utf8(std::wstring(arg))+" requires a value");
            return argv[index];
        };
        const auto set_root = [&context](std::wstring_view arg, const std::wstring& value) {
            auto root = coop::normalized_root(value);
            if (arg == L"--root") context.root = std::move(root);
            else context.global_root = std::move(root);
        };
        for (int i = 1; i < argc; ++i) {
            const std::wstring_view arg(argv[i]);
            if (arg == L"--root" || arg == L"--global-root" ||
                std::wstring_view(arg).starts_with(L"--root=") || std::wstring_view(arg).starts_with(L"--global-root=")) {
                const auto name = arg.starts_with(L"--global-root") ? std::wstring_view(L"--global-root") : std::wstring_view(L"--root");
                set_root(name,option_value(i,arg,name));
            } else if (arg == L"--arch" || std::wstring_view(arg).starts_with(L"--arch=")) {
                architecture = coop::utf8(option_value(i,arg,L"--arch"));
                if (architecture != "64bit" && architecture != "32bit" && architecture != "arm64")
                    throw coop::UsageError("--arch must be 64bit, 32bit or arm64");
            } else if (arg == L"--json") context.json_output = true;
            else if (arg == L"--timings") context.timings = true;
            else arguments.emplace_back(arg);
        }
        if (arguments.size() >= 1 && (arguments[0] == L"init" || arguments[0] == L"list" || arguments[0] == L"search" || arguments[0] == L"info" || arguments[0] == L"status" || arguments[0] == L"prefix" || arguments[0] == L"cat" || arguments[0] == L"which" || arguments[0] == L"home" || arguments[0] == L"help" || arguments[0] == L"depends" || arguments[0] == L"export" || arguments[0] == L"checkup" || arguments[0] == L"bucket" || arguments[0] == L"cache" || arguments[0] == L"download" || arguments[0] == L"hold" || arguments[0] == L"unhold" || arguments[0] == L"config" || arguments[0] == L"alias" || arguments[0] == L"import" || arguments[0] == L"install" || arguments[0] == L"update" || arguments[0] == L"uninstall" || arguments[0] == L"reset" || arguments[0] == L"cleanup" || arguments[0] == L"recover")) {
            if (context.root.empty()) {
                wchar_t profile[32768]{};
                const auto length = GetEnvironmentVariableW(L"USERPROFILE", profile, 32768);
                if (!length || length >= 32768) throw std::runtime_error("Use --root to specify an installation root");
                context.root = coop::normalized_root(std::wstring(profile)+L"\\scoop");
            }
            const auto command = arguments.front();
            arguments.erase(arguments.begin());
            // `coop <command> --help` is Scoop's own spelling for the same text `coop help <command>`
            // prints.
            if (arguments.size() == 1 && (arguments[0] == L"--help" || arguments[0] == L"-h"))
                return coop::query(context,L"help",{command});
            if (command == L"init") return coop::init_command(context,arguments);
            if (command == L"bucket") return coop::bucket_command(context,arguments);
            if (command == L"recover") return coop::recovery_command(context,arguments);
            if (command == L"cache") return coop::cache_command(context,arguments);
            if (command == L"import") {
                coop::TextProgress progress;
                if (!context.json_output) coop::set_progress(&progress);
                struct ResetImport { ~ResetImport() { coop::set_progress(nullptr); } } reset_import;
                return coop::import_command(context,arguments,architecture);
            }
            if (command == L"config") return coop::config_command(context,arguments);
            if (command == L"alias") return coop::alias_command(context,arguments);
            if (command == L"hold") return coop::hold_command(context,arguments,true);
            if (command == L"unhold") return coop::hold_command(context,arguments,false);
            if (command == L"download") {
                // Downloading is a write command for the cache; its stage lines need the text progress.
                coop::TextProgress progress;
                if (!context.json_output) coop::set_progress(&progress);
                struct Reset { ~Reset() { coop::set_progress(nullptr); } } reset;
                return coop::download_command(context,arguments,architecture);
            }
            if (command == L"install" || command == L"update" || command == L"uninstall" || command == L"reset" || command == L"cleanup") {
                // `-q/--quiet` hides the progress lines. It is a presentation switch, so it is taken
                // out here rather than reaching the package argument parser. The same holds for the
                // execution switches, which the plan reads from the context.
                bool quiet = false;
                std::vector<std::wstring> kept;
                for (const auto& argument : arguments) {
                    if (argument == L"-q" || argument == L"--quiet") { quiet = true; continue; }
                    if (argument == L"-s" || argument == L"--skip-hash-check") { context.skip_hash = true; continue; }
                    // `-k` means "do not use the download cache" for install/update but "clean the cache" for cleanup.
                    if (argument == L"-k" || argument == L"--no-cache") {
                        if (command == L"cleanup") { kept.push_back(argument); continue; }
                        context.no_cache = true;
                        continue;
                    }
                    if (argument == L"--cache") { kept.push_back(argument); continue; }
                    if (argument == L"-i" || argument == L"--independent") { context.independent = true; continue; }
                    if (argument == L"-f" || argument == L"--force") { context.force = true; continue; }
                    kept.push_back(argument);
                }
                arguments = std::move(kept);
                auto arguments_for_command = arguments;
                if (command == L"update") {
                    // Scoop's `scoop update` with no app refreshes every bucket; Coop has no
                    // self-update to perform, so the bucket half is the whole meaning. `*`/`-a` is a
                    // different gesture in Scoop and updates every installed app.
                    bool all = false;
                    std::vector<std::wstring> names, flags;
                    for (const auto& argument : arguments) {
                        if (argument == L"*" || argument == L"-a" || argument == L"--all") { all = true; continue; }
                        if (argument.starts_with(L"-")) { flags.push_back(argument); continue; }
                        names.push_back(argument);
                    }
                    if (!all && names.empty()) {
                        if (!context.json_output) std::cout << "Updating Buckets...\n";
                        return coop::bucket_command(context,{L"update"},!context.json_output);
                    }
                    if (all) {
                        arguments_for_command.clear();
                        for (const auto& name : coop::installed_package_names(context)) arguments_for_command.push_back(coop::wide(name));
                        if (arguments_for_command.empty()) {
                            std::cout << "WARN  There aren't any apps installed.\n";
                            return 0;
                        }
                        for (const auto& flag : flags) arguments_for_command.push_back(flag);
                    }
                }
                // Progress belongs to the human-readable write commands only; --json and --quiet runs
                // stay silent and keep their result object.
                coop::TextProgress progress;
                if (!context.json_output && !quiet) coop::set_progress(&progress);
                struct Reset { ~Reset() { coop::set_progress(nullptr); } } reset;
                coop::Timings timings;
                coop::set_timings(&timings);
                struct ResetTimings { ~ResetTimings() { coop::set_timings(nullptr); } } reset_timings;
                const auto exit = coop::package_command(context,command,arguments_for_command,architecture);
                // The summary is human output: a --json run already carries the same numbers as a
                // field, and prose after the JSON would break every consumer. A run that executed no
                // step (a preview, or a failure before the first write) writes no record, so it
                // prints no summary either.
                if (context.timings && !context.json_output && !timings.result().at("steps").empty()) {
                    const auto result = timings.result();
                    std::cout << "Timings\n-------\n"
                              << "download " << result.at("download_seconds").get<double>() << " s\n"
                              << "local    " << result.at("local_seconds").get<double>() << " s\n"
                              << "total    " << result.at("total_seconds").get<double>() << " s\n";
                }
                return exit;
            }
            return coop::query(context, command, arguments);
        }
            // A Scoop alias is a generated subcommand: <root>/shims/scoop-<command>.ps1. Coop runs the
            // same script when the command is not one of its own.
            if (arguments.size() >= 1) {
                auto alias_root = context.root;
                if (alias_root.empty()) {
                    wchar_t profile[32768]{};
                    const auto length = GetEnvironmentVariableW(L"USERPROFILE",profile,32768);
                    if (length && length < 32768) alias_root = coop::normalized_root(std::wstring(profile)+L"\\scoop");
                }
                if (!alias_root.empty()) {
                    const auto script = alias_root/L"shims"/(L"scoop-"+arguments[0]+L".ps1");
                    std::error_code alias_error;
                    if (coop::fs::is_regular_file(script,alias_error)) {
                        context.root = alias_root;
                        const auto name = coop::utf8(arguments[0]);
                        arguments.erase(arguments.begin());
                        return coop::run_alias_script(context,name,arguments);
                    }
                }
            }
            throw coop::UsageError("unknown command; use --help");
    } catch (const coop::UsageError& error) {
        std::cerr << "coop: " << error.what() << '\n';
        return 2;
    } catch (const std::exception& error) {
        std::cerr << "coop: " << error.what() << '\n';
        return 1;
    }
}
