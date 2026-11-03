#include <iostream>
#include <algorithm>
#include <string_view>
#include "app.hpp"
#include "commands.hpp"
#include "package.hpp"
#include "progress.hpp"
#include "timings.hpp"
#include "native.hpp"
#include "recovery.hpp"
#include "shim.hpp"
#include "init.hpp"
#include <windows.h>

namespace {
void validate_update_package(const std::wstring& argument) {
    const auto request = coop::utf8(argument);
    if (request.find("://") != std::string::npos) return;
    std::error_code error;
    const auto path = coop::fs::path(argument);
    if (coop::fs::is_regular_file(path,error) && path.extension() == L".json") return;
    auto name = request;
    try {
        if (const auto at = name.find('@'); at != std::string::npos) {
            coop::validate_component(name.substr(at+1));
            name.resize(at);
        }
        if (const auto slash = name.find('/'); slash != std::string::npos) {
            coop::validate_component(name.substr(0,slash));
            name.erase(0,slash+1);
        }
        coop::validate_component(name);
    } catch (const std::exception& failure) {
        throw coop::UsageError("Invalid update package: "+request+": "+failure.what());
    }
}
// Validate before legacy-state migration or a RunRecord: even rejected updates must be read-only.
// The bare and wildcard dispatch paths otherwise bypass package_command's option validation.
bool validate_update_arguments(const std::vector<std::wstring>& args) {
    bool preview = false, all = false, named = false, package_option = false, manifest_url = false;
    for (const auto& arg : args) {
        if (arg == L"--dry-run") {
            if (preview) throw coop::UsageError("--dry-run was specified more than once");
            preview = true;
        } else if (arg == L"*" || arg == L"-a" || arg == L"--all") {
            all = true;
        } else if (arg == L"-g" || arg == L"--global") {
            throw std::runtime_error("global-scope-readonly: Coop does not write a system-level installation; "
                                     "use --global-root to read one");
        } else if (arg == L"-p" || arg == L"--purge") {
            throw coop::UsageError("--purge is only supported by uninstall");
        } else if (arg == L"-q" || arg == L"--quiet" || arg == L"-u" || arg == L"--no-update-scoop") {
            // Presentation and the already-supported no-self-update switch apply to either form.
        } else if (arg == L"-f" || arg == L"--force" || arg == L"-k" || arg == L"--no-cache" ||
                   arg == L"-s" || arg == L"--skip-hash-check" || arg == L"-i" || arg == L"--independent") {
            package_option = true;
        } else if (arg.starts_with(L"-")) {
            throw coop::UsageError("Unknown update option: "+coop::utf8(arg));
        } else {
            if (arg.empty()) throw coop::UsageError("update requires a non-empty package name");
            validate_update_package(arg);
            named = true;
            manifest_url = manifest_url || arg.find(L"://") != std::wstring::npos;
        }
    }
    if (all && named) throw coop::UsageError("update cannot combine package names with */-a/--all");
    if (!all && !named && package_option) throw coop::UsageError("update package options require package names or */-a/--all");
    // Full source/client previews belong to subsequent work. Never fall through to a real refresh
    // or materialize a URL in the private state directory when only a preview was requested.
    if (preview && !all && !named)
        throw std::runtime_error("Bare update preview is not available yet; no sources were refreshed");
    if (preview && manifest_url)
        throw std::runtime_error("Update preview for manifest URLs is not available yet; use an installed package name");
    return preview;
}
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
    // `coop`, `coop --help` and `coop help` print one page: Scoop's own, unchanged. Splitting the
    // page in two is how the command lists drifted apart in the first place.
    if (argc == 1 || (argc == 2 && std::wstring_view(argv[1]) == L"--help"))
        return coop::query(coop::Context{},L"help",{});
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
            if (std::wstring_view(argv[index]).starts_with(L"-"))
                throw coop::UsageError(coop::utf8(std::wstring(name))+" requires a value; use the = form for values beginning with '-'");
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
            } else if (arg == L"--json" || arg.starts_with(L"--json=")) {
                if (arg != L"--json" && arg != L"--json=2") throw coop::UsageError("Supported JSON formats are --json and --json=2");
                const auto format = arg == L"--json" ? coop::JsonFormat::legacy : coop::JsonFormat::full;
                if (context.json_output && context.json_format != format) throw coop::UsageError("Conflicting JSON formats");
                context.json_output = true;
                context.json_format = format;
            }
            else if (arg == L"--timings") context.timings = true;
            else arguments.emplace_back(arg);
        }
        // The same table answers `help` and `--help`, so a command cannot be dispatched without
        // being documented or documented without being dispatched.
        if (!arguments.empty() && coop::is_command(coop::utf8(arguments[0]))) {
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
            if (context.json_format == coop::JsonFormat::full) {
                if (command != L"status") throw std::runtime_error("JSON v2 for this command is not available yet");
                const bool local = std::any_of(arguments.begin(),arguments.end(),[](const auto& arg) { return arg == L"-l" || arg == L"--local"; });
                if (!local) throw std::runtime_error("Remote status JSON v2 is not available yet; use -l/--local");
                for (const auto& arg : arguments) if (arg != L"-l" && arg != L"--local") throw coop::UsageError("status accepts only -l/--local");
            }
            // Missing arguments should explain the expected invocation, just like Scoop. Keep
            // Coop's documented usage-error exit code instead of leaking handler exceptions.
            if (arguments.empty()) {
                std::string missing;
                if (command == L"alias" || command == L"shim") missing = "<subcommand> missing";
                else if (command == L"which") missing = "<command> missing";
                else if (command == L"cat" || command == L"depends" || command == L"download" ||
                         command == L"install" || command == L"reset" || command == L"uninstall") missing = "<app> missing";
                else if (command == L"import") missing = "<path/url to scoopfile.json> missing";
                else if (command == L"bucket") missing = "coop bucket: cmd '' not supported";
                const bool usage_only = command == L"hold" || command == L"home" || command == L"info" ||
                    command == L"prefix" || command == L"unhold" || command == L"virustotal" || command == L"create";
                if (!missing.empty() || usage_only) {
                    auto& output = missing.empty() ? std::cout : std::cerr;
                    if (!missing.empty()) output << "ERROR " << missing << '\n';
                    for (const auto& entry : coop::commands()) if (command == coop::wide(entry.name)) {
                        output << "Usage: coop " << entry.name << ' ' << entry.usage << '\n';
                        if (command == L"create") output << "\nCreate your own custom app manifest\n";
                    }
                    return command == L"bucket" ? 1 : 2;
                }
            }
            const bool preview = command == L"update" ? validate_update_arguments(arguments) :
                std::any_of(arguments.begin(),arguments.end(),
                    [](const std::wstring& argument) { return argument == L"--dry-run"; });
            // Move a pre-0.2.5 <root>/.coop into the external state directory once. When
            // COOP_STATE_DIR already points there this is a no-op, which is how the tests pin state.
            if ((command != L"update" || !preview) && context.json_format != coop::JsonFormat::full)
                coop::migrate_legacy_state(context);
            // A write command records what it is doing while it runs, so a process that is killed
            // leaves an explanation behind instead of nothing. A preview writes nothing at all,
            // including this record.
            std::optional<coop::RunRecord> run_record;
            if (!preview && (command == L"install" || command == L"update" || command == L"uninstall" ||
                command == L"reset" || command == L"cleanup" || command == L"import")) {
                std::vector<std::string> packages;
                for (const auto& argument : arguments)
                    if (!argument.starts_with(L"-")) packages.push_back(coop::utf8(argument));
                run_record.emplace(context,coop::utf8(command),std::move(packages));
            }
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
            if (command == L"create") return coop::create_command(context,arguments);
            if (command == L"virustotal") return coop::virustotal_command(context,arguments);
            if (command == L"shim") return coop::shim_command(context,arguments);
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
                // A silent step must not look like a frozen process: the watchdog prints when the
                // command has produced no output for a while.
                std::optional<coop::StallWatchdog> watchdog;
                if (!context.json_output && !quiet) watchdog.emplace();
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
