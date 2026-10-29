#include "catalog_index.hpp"
#include "data.hpp"
#include "ir.hpp"
#include "persist.hpp"
#include "progress.hpp"
#include "recovery.hpp"
#include "versions.hpp"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <cctype>
#include <map>
#include <set>
#include <windows.h>

namespace coop {
static std::string lowercase(std::string value);
// While an update or uninstall is pending, the old management record may already have been
// moved into the transaction. Readers then use that last committed record instead of the
// partially published current link, so query output never presents an intermediate version as
// the installed fact.
static Json previous_record(const Context& context, const std::string& name, const Json& recovery) {
    const auto action = recovery.value("action",std::string{});
    if (action != "update" && action != "uninstall") return Json();
    const auto journal_path = fs::path(wide(recovery.value("journal",std::string{})));
    if (!fs::is_regular_file(journal_path)) return Json();
    try {
        const auto journal = read_json(journal_path);
        for (const auto& move : journal.value("moves",Json::array())) {
            if (!move.is_object() || !move.contains("to") || !move.at("to").is_string()) continue;
            const fs::path candidate(wide(move.at("to").get<std::string>()));
            const auto filename = candidate.filename().wstring();
            if (filename != L"old-managed-record.json" && filename != L"managed-record.json") continue;
            if (!recovery_record_path_allowed(context,candidate) || !fs::is_regular_file(candidate)) continue;
            const auto record = read_json(candidate);
            if (!record.is_object() || !record.contains("name") || !record.at("name").is_string() ||
                !equal_name(record.at("name").get<std::string>(),name)) continue;
            return record;
        }
    } catch (const std::exception&) { /* The current published record remains the fallback. */ }
    return Json();
}
static void list_scope(Json& result, const Context& context, const fs::path& root, const std::string& scope,
                       bool recovery_protected) {
    // Installation facts come from the shared Scoop layout through the IR adapter. Coop's private
    // records are optional management metadata read separately below, so they can never decide
    // whether an installed package is visible or block a query when they are missing or stale.
    for (const auto& fact : ir::read_installations(root)) {
        Json item = {{"name",fact.name}, {"version",fact.present ? Json(fact.version) : Json(nullptr)},
            {"scope",scope}, {"read_only",scope == "global"}, {"management","unadopted"}, {"diagnostics",Json::array()}};
        Json details = Json::array();
        for (const auto& diagnostic : fact.diagnostics) {
            item["diagnostics"].push_back(diagnostic.message);
            details.push_back({{"layer",ir::layer_name(diagnostic.layer)},{"code",diagnostic.code},{"message",diagnostic.message}});
        }
        if (fact.present) {
            item["bucket"] = fact.bucket;
            item["source"] = fact.source;
            item["synced_at"] = nullptr;
            item["architecture"] = fact.architecture;
            item["directory"] = path_text(fact.directory);
            // `hold` lives in the install record Scoop itself writes, so a hold set by either client
            // is visible here without any Coop-private state.
            item["hold"] = package_is_held(fact.directory);
            item["status"] = "installed";
            if (scope == "user")
                item["persistence"] = persistence_plan_json(context,fact.name,fact.persistence,fact.directory);
        }
        if (scope == "user") {
            const auto managed = root/L".coop"/L"packages"/(wide(fact.name)+L".json");
            if (fs::exists(managed)) try {
                const auto record = read_json(managed);
                item["management"] = "managed";
                item["status"] = record.value("status",std::string("unknown"));
                item["origin"] = record.value("origin",std::string("coop"));
            } catch (const std::exception& error) {
                const auto message = std::string("Coop management record is unreadable; shared installation facts are still reported: ")+error.what();
                item["diagnostics"].push_back(message);
                details.push_back({{"layer","adapter"},{"code","coop-record-unreadable"},{"message",message}});
            }
        }
        item["diagnostic_details"] = std::move(details);
        if (scope == "user") {
            const auto current_version = item.at("version").is_string() ? item.at("version").get<std::string>() : std::string{};
            item["older_versions"] = retained_versions(context,item.at("name").get<std::string>(),current_version);
            item["old_versions"] = version_cleanup_inventory(context,item.at("name").get<std::string>(),current_version,recovery_protected);
        }
        result.push_back(std::move(item));
    }
}
std::vector<std::string> installed_package_names(const Context& context) {
    std::vector<std::string> names;
    for (const auto& fact : ir::read_installations(context.root))
        if (fact.present) names.push_back(fact.name);
    std::sort(names.begin(),names.end());
    return names;
}
Json installed_packages(const Context& context) {
    // One journal scan serves both the pending-recovery entries and the old-version inventory's
    // recovery protection flag; re-reading the whole transaction history per package made a listing
    // slower as settled journals accumulated.
    const Json recovery_report = pending_recovery_report(context,false);
    const bool recovery_protected = !recovery_report.empty();
    Json result = Json::array();
    list_scope(result,context,context.root, "user", recovery_protected);
    if (context.global_root) list_scope(result,context,*context.global_root, "global", recovery_protected);
    std::map<std::string,std::pair<fs::file_time_type,Json>> operations;
    const auto transactions = context.root/L".coop"/L"transactions";
    if (fs::is_directory(transactions)) for (const auto& entry : fs::directory_iterator(transactions)) {
        const auto path = entry.path()/L"journal.json";
        if (!fs::is_regular_file(path)) continue;
        try {
            const auto journal = read_json(path);
            const auto name = lowercase(journal.at("package").get<std::string>());
            const auto time = fs::last_write_time(path);
            const auto found = operations.find(name);
            if (found == operations.end()) operations[name] = {time,journal};
            else {
                const bool pending = journal.value("state",std::string{}) == "pending";
                const bool previous_pending = found->second.second.value("state",std::string{}) == "pending";
                if (pending != previous_pending ? pending : time > found->second.first) operations[name] = {time,journal};
            }
        } catch (const std::exception&) { /* A malformed journal does not hide queryable installations. */ }
    }
    std::map<std::string,Json> recoveries;
    for (const auto& entry : recovery_report)
        if (entry.is_object() && entry.contains("package") && entry.at("package").is_string()) {
            const auto name = entry.at("package").get<std::string>();
            if (!name.empty()) recoveries[lowercase(name)] = entry;
        }
    std::set<std::string> listed;
    for (auto& item : result) {
        if (item.at("scope") != "user") continue;
        const auto key = lowercase(item.at("name").get<std::string>());
        listed.insert(key);
        const auto operation = operations.find(key);
        if (operation == operations.end()) item["last_operation"] = "none";
        else {
            const auto& journal = operation->second.second;
            const auto state = journal.value("state",std::string{});
            item["last_operation"] = state == "committed" ? "succeeded" : state == "rolled-back" ? "failed" : "pending-recovery";
            item["operation_action"] = journal.value("action",std::string("unknown"));
            if (state == "committed" && journal.value("action",std::string{}) == "uninstall" && !fs::is_directory(context.root/L"apps"/wide(item.at("name"))/L"current")) {
                item["status"] = "uninstalled"; item["management"] = "none"; item["diagnostics"] = Json::array();
            }
        }
        const auto recovery = recoveries.find(key);
        if (recovery != recoveries.end()) {
            item["last_operation"] = "pending-recovery";
            item["operation_action"] = recovery->second.value("action",std::string("unknown"));
            const auto old = previous_record(context,item.at("name").get<std::string>(),recovery->second);
            if (old.is_object()) {
                for (const auto* field : {"version","bucket","source","architecture","directory","origin","status"})
                    if (old.contains(field)) item[field] = old.at(field);
                item["management"] = "managed";
                item["diagnostics"] = Json::array();
            } else if (recovery->second.value("action",std::string{}) == "install" && item.at("version").is_null()) {
                item["version"] = Json(nullptr);
                item["management"] = "none";
                item["status"] = "pending-recovery";
                item["diagnostics"] = Json::array();
            } else if (recovery->second.value("action",std::string{}) == "install") {
                // A later Scoop operation installed the same package while Coop's own install is
                // still pending. Report the installation that actually exists now and keep the
                // pending transaction visible instead of hiding either fact.
                item["last_operation"] = "pending-recovery";
                item["status"] = "pending-recovery";
                item["diagnostics"].push_back("A pending Coop install coexists with an installation readable from the shared layout");
            } else {
                // The current link can already be staged in the transaction while the last
                // committed management record is still in place. Report that record's version as
                // the installed fact instead of an intermediate null, and keep the fact reader's
                // diagnostic that explains the missing link.
                const auto live = context.root/L".coop"/L"packages"/(wide(item.at("name").get<std::string>())+L".json");
                if (fs::is_regular_file(live)) try {
                    const auto record = read_json(live);
                    if (record.is_object() && equal_name(record.value("name",std::string{}),item.at("name").get<std::string>())) {
                        if (item.at("version").is_null() && record.contains("version")) item["version"] = record.at("version");
                        for (const auto* field : {"bucket","architecture","directory","origin"})
                            if (!item.contains(field) && record.contains(field)) item[field] = record.at(field);
                        item["management"] = "managed";
                        item["status"] = record.value("status",std::string("ready"));
                    }
                } catch (const std::exception&) { /* The pending journal remains the authoritative diagnostic. */ }
            }
            item["recovery"] = recovery->second;
        }
    }
    for (const auto& [key,recovery] : recoveries) {
        if (listed.contains(key)) continue;
        result.push_back({{"name",recovery.value("package",std::string{})},{"version",Json(nullptr)},
            {"scope","user"},{"management","none"},{"status","pending-recovery"},
            {"diagnostics",Json::array()},{"last_operation","pending-recovery"},
            {"operation_action",recovery.value("action",std::string("unknown"))},{"recovery",recovery}});
    }
    std::sort(result.begin(), result.end(), [](const Json& a, const Json& b) {
        return a.at("name").get<std::string>() < b.at("name").get<std::string>();
    });
    return result;
}
static Json catalog_item(const Json& source, const Json& entry, const fs::path& directory) {
    const auto name = entry.at("name").get<std::string>();
    Json item = {{"name",name}, {"bucket",source.at("name")},
        {"path",path_text(directory/(wide(name)+L".json"))}, {"source",source.at("url")},
        {"synced_at",source.value("synced_at",Json(nullptr))},
        {"diagnostics",entry.value("diagnostics",Json::array())}};
    if (entry.contains("version")) item["version"] = entry.at("version");
    if (entry.contains("description")) item["description"] = entry.at("description");
    if (entry.contains("homepage")) item["homepage"] = entry.at("homepage");
    return item;
}
static void sort_catalog(Json& result) {
    std::sort(result.begin(), result.end(), [](const Json& a, const Json& b) {
        return a.at("bucket").get<std::string>()+"/"+a.at("name").get<std::string>() <
               b.at("bucket").get<std::string>()+"/"+b.at("name").get<std::string>();
    });
}
static std::string lowercase(std::string value) {
    for (auto& character : value) character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    return value;
}
// `search`/`info` only need the entries that match, so the published bucket metadata is filtered
// while it is read. Building and sorting the whole catalogue first made a single-package lookup
// cost as much as listing every package in the bucket.
static Json matching_catalog(const Context& context, const std::wstring& command, const std::string& needle) {
    Json result = Json::array();
    for (const auto& source : bucket_sources(context)) {
        if (source.value("kind",std::string{}) == "removed") continue;
        const fs::path location(wide(source.at("path").get<std::string>()));
        if (!fs::is_directory(location)) continue;
        const auto directory = fs::is_directory(location/L"bucket") ? location/L"bucket" : location;
        const auto bucket = source.at("name").get<std::string>();
        for (const auto& entry : catalog_entries(context,source)) {
            if (!entry.is_object() || !entry.contains("name") || !entry.at("name").is_string()) continue;
            const auto name = entry.at("name").get<std::string>();
            const auto qualified = bucket+"/"+name;
            const bool match = command == L"info" ? lowercase(name) == needle || lowercase(qualified) == needle :
                lowercase(qualified+" "+entry.value("description",std::string{})).find(needle) != std::string::npos;
            if (match) result.push_back(catalog_item(source,entry,directory));
        }
    }
    sort_catalog(result);
    return result;
}
std::vector<ir::CatalogueEntry> catalogue(const Context& context) {
    std::vector<ir::CatalogueEntry> result;
    for (const auto& source : bucket_sources(context)) {
        if (source.value("kind",std::string{}) == "removed") continue;
        const fs::path location(wide(source.at("path").get<std::string>()));
        if (!fs::is_directory(location)) continue;
        const auto directory = fs::is_directory(location/L"bucket") ? location/L"bucket" : location;
        const auto bucket = source.at("name").get<std::string>();
        for (const auto& entry : catalog_entries(context,source)) {
            if (!entry.is_object() || !entry.contains("name") || !entry.at("name").is_string()) continue;
            const auto name = entry.at("name").get<std::string>();
            result.push_back({name,bucket,directory/(wide(name)+L".json")});
        }
    }
    std::sort(result.begin(), result.end(), [](const ir::CatalogueEntry& a, const ir::CatalogueEntry& b) {
        return a.bucket+"/"+a.name < b.bucket+"/"+b.name;
    });
    return result;
}
// The architecture only selects the manifest variant for one package. Installed facts for the whole
// root are still read (each package's current manifest and install record), but the old-version
// inventories and repeated transaction-journal scans that `installed_packages` adds are not needed
// here. A missing current link can still be described by the last committed record of a pending
// transaction, which the full listing supplies.
static std::string installed_architecture(const Context& context, const std::string& name) {
    bool pending_fact = false;
    for (const auto& fact : ir::read_installations(context.root)) {
        if (!equal_name(fact.name,name)) continue;
        if (fact.present) return fact.architecture.empty() ? std::string("64bit") : fact.architecture;
        pending_fact = true;
        break;
    }
    if (pending_fact) {
        for (const auto& installed : installed_packages(context)) {
            if (installed.value("scope",std::string{}) == "global" ||
                !equal_name(installed.value("name",std::string{}),name)) continue;
            const auto value = installed.value("architecture",std::string{});
            if (!value.empty()) return value;
            break;
        }
    }
    return "64bit";
}
static Json validation_json(const Context& context, const Json& item) {
    // `info` reports the normalized IR and its layered diagnostics: a package that cannot currently be
    // executed still appears with the reason. The adapter and validator only read the manifest bytes.
    const auto architecture = installed_architecture(context,item.at("name").get<std::string>());
    Json validation = {{"architecture",architecture},{"manifest_digest",nullptr},
        {"artifacts",Json::array()},{"diagnostics",Json::array()},{"warnings",Json::array()},{"capabilities",Json::array()}};
    try {
        auto validated = ir::adapt_manifest(fs::path(wide(item.at("path").get<std::string>())),
            item.at("name").get<std::string>(),item.at("bucket").get<std::string>(),architecture);
        ir::validate(validated);
        validation["manifest_digest"] = validated.manifest_digest;
        validation["version"] = validated.version;
        validation["downloads"] = validated.downloads.size();
        if (validated.psmodule) validation["psmodule"] = {{"name",validated.psmodule->name}};
        for (const auto& download : validated.downloads)
            validation["artifacts"].push_back({{"url",download.url},{"filename",download.filename},
                {"renamed",download.renamed},{"algorithm",ir::digest_algorithm_name(download.digest.algorithm)},
                {"digest",download.digest.value},{"archive",ir::archive_format_name(download.format)}});
        for (const auto& diagnostic : validated.diagnostics)
            validation["diagnostics"].push_back({{"layer",ir::layer_name(diagnostic.layer)},{"code",diagnostic.code},{"message",diagnostic.message}});
        // Non-blocking source observations stay beside the diagnostics; `info` never hides them.
        for (const auto& warning : validated.warnings)
            validation["warnings"].push_back({{"layer",ir::layer_name(warning.layer)},{"code",warning.code},{"message",warning.message}});
        for (const auto& capability : validated.capabilities)
            validation["capabilities"].push_back({{"id",capability.id},{"supported",capability.supported},{"detail",capability.detail}});
    } catch (const std::exception& error) {
        validation["diagnostics"].push_back({{"layer","adapter"},{"code","manifest-unreadable"},{"message",error.what()}});
    }
    return validation;
}
// ---------------------------------------------------------------------------
// Default (non-`--json`) output follows Scoop's shapes: one header line, a blank line, then a table
// whose columns are as wide as their widest cell. `--json` is unaffected and stays the machine
// contract; every provenance field the old table printed (management, scope, synced, status, last
// operation) still lives there. The table renderer itself lives in progress.cpp so `cache show`
// prints the same shape.
// ---------------------------------------------------------------------------
static std::string field_text(const Json& item, const char* key) {
    if (!item.contains(key) || !item.at(key).is_string()) return {};
    return item.at(key).get<std::string>();
}
// Scoop reports the install record's write time; `scoop-install.json` is the current name and
// `install.json` the legacy one, the same order the fact reader accepts.
static std::string record_time(const fs::path& directory) {
    for (const auto* name : {L"scoop-install.json", L"install.json"}) {
        WIN32_FILE_ATTRIBUTE_DATA data{};
        if (!GetFileAttributesExW((directory/name).wstring().c_str(),GetFileExInfoStandard,&data)) continue;
        FILETIME local_time{};
        if (!FileTimeToLocalFileTime(&data.ftLastWriteTime,&local_time)) continue;
        SYSTEMTIME time{};
        if (!FileTimeToSystemTime(&local_time,&time)) continue;
        char buffer[32]{};
        std::snprintf(buffer,sizeof buffer,"%04u-%02u-%02u %02u:%02u:%02u",
            time.wYear,time.wMonth,time.wDay,time.wHour,time.wMinute,time.wSecond);
        return buffer;
    }
    return {};
}
// Deleting a manifest only moves it to the bucket's `deprecated` directory, so the package still
// resolves but Scoop marks it in `list`/`info`.
static std::set<std::string> deprecated_names(const Context& context) {
    std::set<std::string> names;
    for (const auto& source : bucket_sources(context)) {
        if (source.value("kind",std::string{}) == "removed") continue;
        std::error_code error;
        const fs::path directory = fs::path(wide(source.at("path").get<std::string>()))/L"deprecated";
        if (!fs::is_directory(directory,error)) continue;
        for (fs::recursive_directory_iterator entry(directory,fs::directory_options::skip_permission_denied,error), end;
             !error && entry != end; entry.increment(error)) {
            std::error_code type_error;
            if (!entry->is_regular_file(type_error)) continue;
            if (entry->path().extension() == L".json")
                names.insert(lowercase(utf8(entry->path().stem().wstring())));
        }
    }
    return names;
}
// Scoop's `Info` column carries exceptions only: `Deprecated package`, `Global install`, `Held
// package` and a non-default architecture. Coop adds its own pending-recovery state there because a
// write that needs recovery must be visible without reading `--json`.
static std::string exception_labels(const Json& item, const std::set<std::string>& deprecated) {
    std::vector<std::string> labels;
    if (field_text(item,"scope") == "global") labels.push_back("Global install");
    if (item.value("hold",false)) labels.push_back("Held package");
    if (const auto architecture = field_text(item,"architecture"); !architecture.empty() && architecture != "64bit")
        labels.push_back(architecture);
    if (item.contains("version") && item.at("version").is_null()) labels.push_back("Install failed");
    if (deprecated.contains(lowercase(field_text(item,"name")))) labels.push_back("Deprecated package");
    std::string text;
    for (const auto& label : labels) text += (text.empty() ? "" : ", ")+label;
    return text;
}
// Non-verbose `info` prints every root variable as the literal `<root>` placeholder, exactly as
// Scoop does. `env_set` values are narrower: Scoop substitutes only `$dir` there, so `$persist_dir`
// stays literal in that block.
static std::string substitute_roots(std::string value) {
    for (const auto* token : {"$original_dir", "$persist_dir", "$dir"}) {
        const auto length = std::char_traits<char>::length(token);
        for (std::size_t at = value.find(token); at != std::string::npos; at = value.find(token,at+length))
            value.replace(at,length,"<root>");
    }
    return value;
}
static std::string substitute_dir(std::string value) {
    for (std::size_t at = value.find("$dir"); at != std::string::npos; at = value.find("$dir",at+4))
        value.replace(at,4,"<root>");
    return value;
}
// A manifest property may be overridden inside `architecture.<arch>`; that override wins, exactly as
// Scoop's `arch_specific` does.
static Json arch_value(const Json& manifest, const char* key, const std::string& architecture) {
    if (manifest.contains("architecture") && manifest.at("architecture").is_object()) {
        const auto& variants = manifest.at("architecture");
        if (variants.contains(architecture) && variants.at(architecture).is_object() &&
            variants.at(architecture).contains(key)) return variants.at(architecture).at(key);
    }
    return manifest.contains(key) ? manifest.at(key) : Json();
}
static std::string joined(const Json& value) {
    // A Manifest may declare one entry as a bare string or as a list; Scoop's `@()`/`-join` treats
    // both as a one-element list, so the display must too.
    if (value.is_string()) return value.get<std::string>();
    std::string text;
    if (value.is_array()) for (const auto& element : value) {
        if (!element.is_string()) continue;
        text += (text.empty() ? "" : " | ")+element.get<std::string>();
    }
    return text;
}
static std::string binaries_text(const Json& manifest, const std::string& architecture) {
    const auto binaries = arch_value(manifest,"bin",architecture);
    if (binaries.is_string()) return binaries.get<std::string>();
    if (!binaries.is_array()) return {};
    std::string text;
    for (const auto& entry : binaries) {
        std::string cell;
        if (entry.is_string()) cell = entry.get<std::string>();
        else if (entry.is_array() && entry.size() >= 2 && entry.at(0).is_string() && entry.at(1).is_string()) {
            // `["target.exe","alias"]` publishes `alias.exe`: the alias replaces the name, the
            // extension is inherited from the target.
            const auto target = entry.at(0).get<std::string>();
            const auto dot = target.find_last_of('.');
            const auto extension = dot == std::string::npos ? std::string{} : target.substr(dot);
            cell = entry.at(1).get<std::string>()+extension;
        } else return {};
        if (!cell.empty()) text += (text.empty() ? "" : " | ")+cell;
    }
    return text;
}
static std::string shortcuts_text(const Json& manifest, const std::string& architecture) {
    const auto shortcuts = arch_value(manifest,"shortcuts",architecture);
    if (shortcuts.is_string()) return shortcuts.get<std::string>();
    if (!shortcuts.is_array()) return {};
    std::string text;
    for (const auto& entry : shortcuts) {
        std::string cell;
        if (entry.is_array() && entry.size() >= 2 && entry.at(1).is_string()) cell = entry.at(1).get<std::string>();
        else if (entry.is_string()) cell = entry.get<std::string>();
        if (!cell.empty()) text += (text.empty() ? "" : " | ")+cell;
    }
    return text;
}
static std::string environment_text(const Json& manifest, const std::string& architecture) {
    const auto environment = arch_value(manifest,"env_set",architecture);
    if (!environment.is_object()) return {};
    std::string text;
    for (const auto& [variable,value] : environment.items()) {
        if (!value.is_string()) continue;
        text += (text.empty() ? "" : "\n")+variable+" = "+substitute_dir(value.get<std::string>());
    }
    return text;
}
static std::string path_added_text(const Json& manifest, const std::string& architecture) {
    const auto entries = arch_value(manifest,"env_add_path",architecture);
    if (entries.is_string()) return "<root>\\"+entries.get<std::string>();
    if (!entries.is_array()) return {};
    std::string text;
    for (const auto& entry : entries) {
        if (!entry.is_string()) continue;
        const auto value = entry.get<std::string>();
        const auto relative = value == "." || value == "./" || value.empty() ? std::string{} :
            value+((value.back() == '\\' || value.back() == '/') ? "" : "\\");
        text += (text.empty() ? std::string{} : std::string{"\n"})+"<root>\\"+relative;
    }
    return text;
}
static std::string suggestions_text(const Json& manifest) {
    if (!manifest.contains("suggest") || !manifest.at("suggest").is_object()) return {};
    std::string text;
    for (const auto& [feature,candidates] : manifest.at("suggest").items()) {
        const auto cells = joined(candidates);
        if (cells.empty()) continue;
        text += (text.empty() ? "" : " | ")+cells;
    }
    return text;
}
static std::string notes_text(const Json& manifest) {
    if (!manifest.contains("notes")) return {};
    const auto& notes = manifest.at("notes");
    std::string text;
    const auto append = [&text](const std::string& value) {
        text += (text.empty() ? "" : "\n")+substitute_roots(value);
    };
    if (notes.is_string()) append(notes.get<std::string>());
    else if (notes.is_array()) for (const auto& line : notes) if (line.is_string()) append(line.get<std::string>());
    return text;
}
// Installed versions are the version directories beside the `current` link; `current` itself is a
// link, not a version. Lexical order is what the directory listing gives and what Scoop prints.
static std::vector<std::string> installed_versions(const Context& context, const std::string& name) {
    std::vector<std::string> versions;
    const auto directory = context.root/L"apps"/wide(name);
    std::error_code error;
    if (!fs::is_directory(directory,error)) return versions;
    for (const auto& entry : fs::directory_iterator(directory,error)) {
        if (error) break;
        if (entry.path().filename() == L"current") continue;
        std::error_code type_error;
        if (!entry.is_directory(type_error)) continue;
        versions.push_back(utf8(entry.path().filename().wstring()));
    }
    std::sort(versions.begin(),versions.end());
    return versions;
}
static std::string current_version(const Context& context, const std::string& name) {
    std::error_code error;
    const auto target = fs::canonical(context.root/L"apps"/wide(name)/L"current",error);
    if (error) return {};
    return utf8(target.filename().wstring());
}
static void print_installed_table(const Context& context, const Json& result, const std::string& query,
                                  bool any_installed) {
    // Scoop warns only when nothing is installed at all, and warns before any header; a query that
    // matches nothing still prints the header over an empty table.
    if (!any_installed) {
        std::cout << "WARN  There aren't any apps installed.\n";
        return;
    }
    std::cout << "Installed apps";
    if (!query.empty()) std::cout << " matching '" << query << "'";
    std::cout << ":\n\n";
    const auto deprecated = deprecated_names(context);
    std::vector<std::vector<std::string>> rows;
    for (const auto& item : result) {
        const auto version = field_text(item,"version");
        const auto directory = field_text(item,"directory");
        rows.push_back({field_text(item,"name"),version,field_text(item,"bucket"),
            directory.empty() ? std::string{} : record_time(wide(directory)),
            exception_labels(item,deprecated)});
    }
    print_table({"Name","Version","Source","Updated","Info"},rows);
    // A pending write needs recovery, which Scoop has no concept of. It stays out of Scoop's `Info`
    // labels and is reported as a warning after the table instead of widening the compat surface.
    for (const auto& item : result) {
        if (field_text(item,"last_operation") != "pending-recovery") continue;
        const auto name = field_text(item,"name");
        std::cout << "WARN  " << name << ": pending recovery; run 'coop recover " << name << "'\n";
    }
}
static void print_search_table(const Json& result) {
    if (result.empty()) {
        std::cout << "WARN  No matches found.\n";
        return;
    }
    std::cout << "Results from local buckets...\n\n";
    std::vector<std::vector<std::string>> rows;
    for (const auto& item : result) {
        std::string binaries;
        try {
            const auto manifest = read_json(fs::path(wide(item.at("path").get<std::string>())));
            const auto architecture = field_text(item,"architecture");
            binaries = binaries_text(manifest,architecture.empty() ? std::string("64bit") : architecture);
        } catch (const std::exception&) { /* A manifest the adapter rejects still appears in search. */ }
        rows.push_back({field_text(item,"name"),field_text(item,"version"),
            field_text(item,"bucket"),binaries});
    }
    print_table({"Name","Version","Source","Binaries"},rows);
}
static void print_info_block(const Context& context, const Json& item, const std::set<std::string>& deprecated) {
    const auto name = field_text(item,"name");
    Json manifest = Json::object();
    try { manifest = read_json(fs::path(wide(item.at("path").get<std::string>()))); }
    catch (const std::exception&) { /* The declared metadata is shown when it can be read. */ }
    const auto architecture = [&context,&name] {
        for (const auto& fact : ir::read_installations(context.root)) {
            if (!equal_name(fact.name,name) || !fact.present) continue;
            return fact.architecture.empty() ? std::string("64bit") : fact.architecture;
        }
        return std::string("64bit");
    }();
    std::vector<std::pair<std::string,std::string>> lines;
    const auto add = [&lines](std::string key, std::string value) {
        if (!value.empty()) lines.emplace_back(std::move(key),std::move(value));
    };
    add("Name",name+(deprecated.contains(lowercase(name)) ? " (DEPRECATED)" : ""));
    if (manifest.contains("description") && manifest.at("description").is_string())
        add("Description",manifest.at("description").get<std::string>());
    const auto manifest_version = manifest.value("version",field_text(item,"version"));
    const auto installed = current_version(context,name);
    auto version_text = manifest_version;
    if (!installed.empty() && installed != manifest_version)
        version_text = installed+" (Update to "+manifest_version+" available)";
    add("Version",version_text);
    add("Source",field_text(item,"bucket"));
    if (manifest.contains("homepage") && manifest.at("homepage").is_string()) {
        auto homepage = manifest.at("homepage").get<std::string>();
        while (!homepage.empty() && homepage.back() == '/') homepage.pop_back();
        add("Website",homepage);
    }
    if (manifest.contains("license")) {
        const auto& license = manifest.at("license");
        if (license.is_string()) add("License",license.get<std::string>());
        else if (license.is_object() && license.contains("identifier") && license.at("identifier").is_string())
            add("License",license.at("identifier").get<std::string>());
    }
    if (manifest.contains("depends")) add("Dependencies",joined(manifest.at("depends")));
    if (const auto versions = installed_versions(context,name); !versions.empty()) {
        std::string text;
        for (const auto& version : versions) text += (text.empty() ? "" : "\n")+version;
        add("Installed",text);
    }
    add("Binaries",binaries_text(manifest,architecture));
    add("Shortcuts",shortcuts_text(manifest,architecture));
    add("Environment",environment_text(manifest,architecture));
    add("Path Added",path_added_text(manifest,architecture));
    add("Suggestions",suggestions_text(manifest));
    add("Notes",notes_text(manifest));
    std::size_t width = 0;
    for (const auto& [key,value] : lines) width = (std::max)(width,display_width(key));
    for (const auto& [key,value] : lines) {
        // Scoop's formatter aligns a multi-line value under the first line, so the key column width
        // sets the indent of continuation lines too.
        std::string text = value;
        const auto indent = std::string(width+3,' ');
        for (std::size_t at = text.find('\n'); at != std::string::npos; at = text.find('\n',at+indent.size()+1))
            text.replace(at,1,"\n"+indent);
        std::cout << key << std::string(width-display_width(key)+1,' ') << ": " << text << '\n';
    }
}
// ---------------------------------------------------------------------------
// Read-only inspection commands: `status`, `prefix`, `cat`, `which`, `home`. They answer questions
// about the local state and never write it; `home` only opens the declared homepage.
// ---------------------------------------------------------------------------
static std::string friendly_path(std::string value) {
    // Scoop prints shim paths with the profile replaced by `~\`.
    wchar_t profile[32768]{};
    const auto length = GetEnvironmentVariableW(L"USERPROFILE",profile,32768);
    if (!length || length >= 32768) return value;
    const auto home = path_text(fs::path(std::wstring(profile,length)));
    if (value.size() <= home.size()) return value;
    if (CompareStringOrdinal(wide(value.substr(0,home.size())).c_str(),-1,wide(home).c_str(),-1,TRUE) != CSTR_EQUAL)
        return value;
    auto rest = value.substr(home.size());
    while (!rest.empty() && (rest.front() == '\\' || rest.front() == '/')) rest.erase(rest.begin());
    return "~\\"+rest;
}
// A Manifest may declare `depends` as one string or as a list; Scoop's `@()` treats both as a list.
static std::vector<std::string> depends_entries(const Json& manifest) {
    std::vector<std::string> spelled;
    if (!manifest.contains("depends")) return spelled;
    const auto add = [&spelled](const Json& value) {
        if (value.is_string()) spelled.push_back(value.get<std::string>());
    };
    const auto& depends = manifest.at("depends");
    if (depends.is_string()) add(depends);
    else if (depends.is_array()) for (const auto& entry : depends) add(entry);
    return spelled;
}
static std::vector<std::string> declared_depends(const fs::path& path) {
    std::vector<std::string> names;
    try {
        for (auto name : depends_entries(read_json(path))) {
            if (const auto at = name.find('@'); at != std::string::npos) name.resize(at);
            if (const auto slash = name.find('/'); slash != std::string::npos) name.erase(0,slash+1);
            if (!name.empty()) names.push_back(name);
        }
    } catch (const std::exception&) { /* An unreadable manifest reports no dependencies, not a failure. */ }
    return names;
}
static std::string manifest_version_text(const fs::path& path) {
    try { return read_json(path).value("version",std::string{}); }
    catch (const std::exception&) { return {}; }
}
static int status_command(const Context& context) {
    std::map<std::string,fs::path> catalogue_paths;
    for (const auto& entry : catalogue(context))
        if (!catalogue_paths.contains(lowercase(entry.name))) catalogue_paths[lowercase(entry.name)] = entry.manifest_path;
    const auto installed = installed_packages(context);
    std::set<std::string> installed_names;
    for (const auto& item : installed) installed_names.insert(lowercase(field_text(item,"name")));
    const auto deprecated = deprecated_names(context);
    std::vector<std::vector<std::string>> rows;
    Json json = Json::array();
    for (const auto& item : installed) {
        const auto name = field_text(item,"name");
        const auto current = field_text(item,"version");
        const auto found = catalogue_paths.find(lowercase(name));
        std::string latest, missing, info;
        if (found == catalogue_paths.end()) info = "Manifest removed";
        else {
            const auto candidate = manifest_version_text(found->second);
            // `update` changes a package whenever the manifest names a different version, so `status`
            // answers with the same predicate instead of a second, differently-ordered comparison.
            if (!candidate.empty() && candidate != current) latest = candidate;
            std::vector<std::string> absent;
            for (const auto& dependency : declared_depends(found->second))
                if (!installed_names.contains(lowercase(dependency))) absent.push_back(dependency);
            for (const auto& dependency : absent) missing += (missing.empty() ? "" : " | ")+dependency;
        }
        std::string flags;
        for (const auto& flag : {current.empty() ? "Install failed" : "",
                 deprecated.contains(lowercase(name)) ? "Deprecated" : ""})
            if (*flag) flags += (flags.empty() ? "" : ", ")+std::string(flag);
        if (latest.empty() && missing.empty() && flags.empty() && info.empty()) continue;
        rows.push_back({name,current,latest,missing,info.empty() ? flags : info});
        json.push_back({{"name",name},{"installed_version",current},{"latest_version",latest},
            {"missing_dependencies",missing},{"info",info.empty() ? flags : info}});
    }
    if (context.json_output) { std::cout << json.dump(2,' ',false,Json::error_handler_t::replace) << '\n'; return 0; }
    if (rows.empty()) { std::cout << "Everything is ok!\n"; return 0; }
    print_table({"Name","Installed Version","Latest Version","Missing Dependencies","Info"},rows);
    return 0;
}
static const Json& single_catalog_item(const Context& context, const std::string& needle) {
    static Json item;
    auto result = matching_catalog(context,L"info",lowercase(needle));
    if (result.empty()) throw std::runtime_error("Couldn't find manifest for '"+needle+"'.");
    if (result.size() > 1) throw std::runtime_error("Ambiguous package; qualify it with its bucket");
    item = std::move(result.front());
    return item;
}
static std::string read_text_file(const fs::path& path) {
    std::ifstream stream(path,std::ios::binary);
    if (!stream) throw std::runtime_error("Cannot read "+path_text(path));
    return std::string(std::istreambuf_iterator<char>(stream),{});
}
static int prefix_command(const Context& context, const std::string& name) {
    // Scoop prints the `current` path itself, not the version directory it points at.
    std::vector<const fs::path*> roots{&context.root};
    if (context.global_root && !context.global_root->empty()) roots.push_back(&*context.global_root);
    for (const auto* root : roots) {
        std::error_code error;
        const auto current = *root/L"apps"/wide(name)/L"current";
        if (!fs::exists(current,error)) continue;
        std::cout << path_text(current) << '\n';
        return 0;
    }
    throw std::runtime_error("Could not find app path for '"+name+"'.");
}
static int cat_command(const Context& context, const std::string& name) {
    const auto& item = single_catalog_item(context,name);
    // The Manifest is printed as it is on disk. Scoop pretty-prints it and loses the declaration
    // order; showing the stored bytes is the honest form of "show the content".
    const auto text = read_text_file(fs::path(wide(item.at("path").get<std::string>())));
    std::cout << text;
    if (text.empty() || text.back() != '\n') std::cout << '\n';
    return 0;
}
static int which_command(const Context& context, const std::string& name) {
    // Scoop prints the shim's target: `<shims>\<name>.shim` records `path = "<target>"`.
    std::error_code error;
    const auto shim = context.root/L"shims"/(wide(name)+L".shim");
    if (fs::is_regular_file(shim,error)) {
        const auto text = read_text_file(shim);
        const auto marker = text.find("path = ");
        const auto quote = marker == std::string::npos ? std::string::npos : text.find('"',marker);
        const auto end = quote == std::string::npos ? std::string::npos : text.find('"',quote+1);
        if (end != std::string::npos) {
            const auto target = text.substr(quote+1,end-quote-1);
            if (!target.empty()) {
                std::cout << friendly_path(target) << '\n';
                return 0;
            }
        }
    }
    // Script-host wrappers publish no `.shim`; their own file is the answer.
    for (const auto* extension : {L".cmd", L".ps1", L".sh", L".exe", L".bat"}) {
        const auto candidate = context.root/L"shims"/(wide(name)+extension);
        if (!fs::is_regular_file(candidate,error)) continue;
        std::cout << friendly_path(path_text(candidate)) << '\n';
        return 0;
    }
    // Scoop exits 2 here; Coop keeps its own 0/1/2 contract, where 2 means the command line was
    // wrong. The message is Scoop's.
    std::cout << "WARN  '" << name << "' not found, not a scoop shim, or a broken shim.\n";
    return 1;
}
static int home_command(const Context& context, const std::string& name) {
    const auto& item = single_catalog_item(context,name);
    const auto manifest = read_json(fs::path(wide(item.at("path").get<std::string>())));
    const auto homepage = manifest.value("homepage",std::string{});
    if (homepage.empty()) throw std::runtime_error("No homepage is declared for '"+name+"'.");
    if (reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr,L"open",wide(homepage).c_str(),nullptr,nullptr,SW_SHOWNORMAL)) <= 32)
        throw std::runtime_error("Could not open "+homepage);
    return 0;
}
// ---------------------------------------------------------------------------
// `help`, `depends`, `export` and `checkup`. Command names, usage strings and summaries follow
// Scoop 0.6.0's own help headers; the `implemented` flag is Coop's, so help never promises a command
// that does not exist yet.
// ---------------------------------------------------------------------------
struct HelpEntry { const char* name; const char* usage; const char* summary; bool implemented; };
static const HelpEntry kHelpEntries[] = {
    {"alias","<subcommand> [options] [<args>]","Manage scoop aliases",true},
    {"bucket","add|list|known|rm [<args>]","Manage Scoop buckets",true},
    {"cache","show|rm [app(s)]","Show or clear the download cache",true},
    {"cat","<app>","Show content of specified manifest",true},
    {"checkup","","Check for potential problems",true},
    {"cleanup","<app> [options]","Cleanup apps by removing old versions",true},
    {"config","[rm] name [value]","Get or set configuration values",true},
    {"create","<url>","Create a custom app manifest",false},
    {"depends","<app>","List dependencies for an app, in the order they'll be installed",true},
    {"download","<app> [options]","Download apps in the cache folder and verify hashes",true},
    {"export","","Exports installed apps, buckets (and optionally configs) in JSON format",true},
    {"help","<command>","Show help for a command",true},
    {"hold","<apps>","Hold an app to disable updates",true},
    {"home","<app>","Opens the app homepage",true},
    {"import","<path/url to scoopfile.json>","Imports apps, buckets and configs from a Scoopfile in JSON format",true},
    {"info","<app> [options]","Display information about an app",true},
    {"install","<app> [options]","Install apps",true},
    {"list","[query]","List installed apps",true},
    {"prefix","<app>","Returns the path to the specified app",true},
    {"reset","<app>","Reset an app to resolve conflicts",true},
    {"search","<query>","Search available apps",true},
    {"shim","<subcommand> [<shim_name>...] [options] [other_args]","Manipulate Scoop shims",true},
    {"status","","Show status and check for new app versions",true},
    {"unhold","<app>","Unhold an app to enable updates",true},
    {"uninstall","<app> [options]","Uninstall an app",true},
    {"update","<app> [options]","Update apps, or Scoop itself",true},
    {"virustotal","[* | app1 app2 ...] [options]","Look for app's hash or url on virustotal.com",false},
    {"which","<command>","Locate a shim/executable",true}
};
static int help_command(const std::vector<std::wstring>& args) {
    if (args.size() > 1) throw UsageError("help accepts at most one command");
    if (args.empty()) {
        std::cout << "Available commands are listed below.\n\n"
                     "Type 'coop help <command>' to get more help for a specific command.\n\n";
        std::vector<std::vector<std::string>> rows;
        for (const auto& entry : kHelpEntries)
            rows.push_back({entry.name,std::string(entry.summary)+(entry.implemented ? "" : " (not implemented yet)")});
        print_table({"Command","Summary"},rows);
        return 0;
    }
    const auto name = lowercase(utf8(args.front()));
    for (const auto& entry : kHelpEntries) {
        if (name != entry.name) continue;
        std::cout << "Usage: coop " << entry.name;
        if (*entry.usage) std::cout << ' ' << entry.usage;
        std::cout << "\n\n" << entry.summary << '\n';
        if (entry.implemented) return 0;
        std::cout << "\nWARN  this Scoop command is not implemented in Coop yet.\n";
        return 1;
    }
    throw UsageError("unknown command; use --help");
}
static int depends_command(const Context& context, const std::string& request) {
    const auto& item = single_catalog_item(context,request);
    std::map<std::string,fs::path> paths;
    std::map<std::string,std::string> buckets;
    for (const auto& entry : catalogue(context)) {
        const auto key = lowercase(entry.name);
        if (!paths.contains(key)) { paths[key] = entry.manifest_path; buckets[key] = entry.bucket; }
    }
    std::vector<std::pair<std::string,std::string>> order;
    std::set<std::string> seen;
    std::function<void(const fs::path&)> visit = [&](const fs::path& manifest_path) {
        Json manifest;
        try { manifest = read_json(manifest_path); } catch (const std::exception&) { return; }
        for (auto spelled : depends_entries(manifest)) {
            if (const auto at = spelled.find('@'); at != std::string::npos) spelled.resize(at);
            std::string bucket;
            auto name = spelled;
            if (const auto slash = spelled.find('/'); slash != std::string::npos) {
                bucket = spelled.substr(0,slash);
                name = spelled.substr(slash+1);
            }
            const auto key = lowercase(name);
            if (!seen.insert(key).second) continue;
            const auto found = paths.find(key);
            if (found != paths.end()) visit(found->second);
            // A dependency the bucket does not publish still appears: it is declared, and a missing
            // manifest is a fact the user must see rather than a reason to hide the line.
            order.emplace_back(bucket.empty() ? buckets[key] : bucket,name);
        }
    };
    visit(fs::path(wide(item.at("path").get<std::string>())));
    // Scoop's list ends with the requested app itself: it installs after its dependencies.
    order.emplace_back(item.value("bucket",std::string{}),item.at("name").get<std::string>());
    if (context.json_output) {
        Json output = Json::array();
        for (const auto& [source,name] : order) output.push_back({{"source",source},{"name",name}});
        std::cout << output.dump(2,' ',false,Json::error_handler_t::replace) << '\n';
        return 0;
    }
    if (order.empty()) return 0;
    std::vector<std::vector<std::string>> rows;
    for (const auto& [source,name] : order) rows.push_back({source,name});
    print_table({"Source","Name"},rows);
    return 0;
}
static int export_command(const Context& context) {
    Json buckets = Json::array();
    for (const auto& source : bucket_sources(context)) {
        if (source.value("kind",std::string{}) == "removed") continue;
        const fs::path location(wide(source.at("path").get<std::string>()));
        const auto directory = fs::is_directory(location/L"bucket") ? location/L"bucket" : location;
        std::uintmax_t manifests = 0;
        std::error_code error;
        for (fs::recursive_directory_iterator entry(directory,fs::directory_options::skip_permission_denied,error), end;
             !error && entry != end; entry.increment(error)) {
            std::error_code type_error;
            if (entry->is_regular_file(type_error) && entry->path().extension() == L".json") ++manifests;
        }
        buckets.push_back({{"Name",source.at("name")},{"Source",source.value("url",std::string{})},
            {"Manifests",manifests}});
    }
    Json apps = Json::array();
    for (const auto& item : installed_packages(context)) {
        if (item.value("scope",std::string{}) != "user") continue;
        apps.push_back({{"Name",item.at("name")},{"Version",item.value("version",Json(nullptr))},
            {"Source",item.value("bucket",std::string{})},{"Info",""}});
    }
    Json output = {{"buckets",buckets},{"apps",apps}};
    std::cout << output.dump(2,' ',false,Json::error_handler_t::replace) << '\n';
    return 0;
}
static int checkup_command(const Context& context) {
    int issues = 0;
    const auto report = [&issues](const std::string& text) {
        std::cout << "WARN  " << text << '\n';
        ++issues;
    };
    // Long paths: without this switch a deep package path fails at MAX_PATH during extraction.
    DWORD long_paths = 0, size = sizeof(long_paths);
    const auto status = RegGetValueW(HKEY_LOCAL_MACHINE,L"SYSTEM\\CurrentControlSet\\Control\\FileSystem",
        L"LongPathsEnabled",RRF_RT_REG_DWORD,nullptr,&long_paths,&size);
    if (status != ERROR_SUCCESS || long_paths == 0)
        report("Long paths are disabled; set HKLM\\SYSTEM\\CurrentControlSet\\Control\\FileSystem\\LongPathsEnabled to 1.");
    bool main_bucket = false;
    for (const auto& source : bucket_sources(context)) {
        if (source.value("kind",std::string{}) == "removed") continue;
        if (source.at("name") == "main") main_bucket = true;
        const fs::path location(wide(source.at("path").get<std::string>()));
        std::error_code error;
        if (!fs::is_directory(location,error))
            report("Bucket '"+source.at("name").get<std::string>()+"' is registered but its directory is missing: "+path_text(location));
    }
    if (!main_bucket) report("The 'main' bucket is not installed.");
    // A pending transaction blocks new writes; it must be visible here, not only in `list`.
    const auto transactions = context.root/L".coop"/L"transactions";
    std::error_code error;
    if (fs::is_directory(transactions,error)) for (const auto& entry : fs::directory_iterator(transactions,error)) {
        if (error) break;
        const auto journal_path = entry.path()/L"journal.json";
        if (!fs::is_regular_file(journal_path,error)) continue;
        try {
            const auto journal = read_json(journal_path);
            if (journal.value("state",std::string{}) != "pending") continue;
            report("Package '"+journal.value("package",std::string{})+"' has a pending transaction; run 'coop recover'.");
        } catch (const std::exception&) { /* An unreadable journal is reported by `list`, not here. */ }
    }
    // A shim whose target disappeared leaves a broken command on PATH.
    const auto shims = context.root/L"shims";
    std::size_t checked_shims = 0;
    if (fs::is_directory(shims,error)) for (const auto& entry : fs::directory_iterator(shims,error)) {
        if (error || checked_shims > 1000) break;
        if (entry.path().extension() != L".shim") continue;
        ++checked_shims;
        try {
            const auto text = read_text_file(entry.path());
            const auto marker = text.find("path = ");
            const auto quote = marker == std::string::npos ? std::string::npos : text.find('"',marker);
            const auto end = quote == std::string::npos ? std::string::npos : text.find('"',quote+1);
            if (end == std::string::npos) continue;
            const auto target = text.substr(quote+1,end-quote-1);
            std::error_code target_error;
            if (!target.empty() && !fs::is_regular_file(fs::path(wide(target)),target_error))
                report("Shim '"+utf8(entry.path().stem().wstring())+"' points to a missing target: "+target);
        } catch (const std::exception&) { /* A shim that cannot be read is not a problem this check proves. */ }
    }
    if (issues == 0) { std::cout << "No problems identified!\n"; return 0; }
    std::cout << "Found " << issues << " potential problem" << (issues == 1 ? "" : "s") << ".\n";
    return 0;
}
int query(const Context& context, const std::wstring& command, const std::vector<std::wstring>& args) {
    if (command == L"help") return help_command(args);
    if (command == L"checkup") {
        if (!args.empty()) throw UsageError("checkup takes no arguments");
        return checkup_command(context);
    }
    if (command == L"export") {
        if (!args.empty()) throw UsageError("export takes no arguments");
        return export_command(context);
    }
    if (command == L"depends") {
        if (args.size() != 1) throw UsageError("depends requires exactly one package");
        return depends_command(context,utf8(args.front()));
    }
    if (command == L"status" || command == L"prefix" || command == L"cat" || command == L"which" || command == L"home") {
        if (command == L"status") {
            // `scoop status -l` only disables remote fetching, and Coop never fetches here, so both
            // spellings mean the same thing.
            for (const auto& argument : args)
                if (argument != L"-l" && argument != L"--local") throw UsageError("status accepts only -l/--local");
            return status_command(context);
        }
        if (args.size() != 1) throw UsageError(utf8(command)+" requires exactly one package or command");
        const auto name = utf8(args.front());
        if (command == L"prefix") return prefix_command(context,name);
        if (command == L"cat") return cat_command(context,name);
        if (command == L"which") return which_command(context,name);
        return home_command(context,name);
    }
    Json result = Json::array();
    std::string query_text;
    bool any_installed = false;
    if (command == L"list") {
        // `scoop list [query]` filters installed apps; the filter is a case-insensitive substring
        // here rather than Scoop's regular expression, which is the one deliberate difference.
        if (args.size() > 1) throw UsageError("list accepts at most one query");
        if (!args.empty()) query_text = utf8(args[0]);
        result = installed_packages(context);
        any_installed = !result.empty();
        if (!query_text.empty()) {
            Json filtered = Json::array();
            for (auto& item : result)
                if (lowercase(field_text(item,"name")).find(lowercase(query_text)) != std::string::npos)
                    filtered.push_back(item);
            result = std::move(filtered);
        }
    } else {
        if (command == L"search" && args.empty()) {
            result = matching_catalog(context,command,std::string{});
        } else {
            if (args.size() != 1) throw UsageError("search/info accepts exactly one package or query");
            if (!args.empty()) query_text = utf8(args[0]);
            result = matching_catalog(context,command,lowercase(query_text));
        }
        if (command == L"info" && result.empty()) throw std::runtime_error("Package not found in local buckets");
        if (command == L"info" && result.size() > 1)
            throw std::runtime_error("Ambiguous package; qualify it with its bucket");
        if (command == L"info") for (auto& item : result) item["validation"] = validation_json(context,item);
    }
    if (context.json_output) std::cout << result.dump(2, ' ', false, Json::error_handler_t::replace) << '\n';
    else if (command == L"list") print_installed_table(context,result,query_text,any_installed);
    else if (command == L"search") print_search_table(result);
    else {
        const auto deprecated = deprecated_names(context);
        for (const auto& item : result) print_info_block(context,item,deprecated);
    }
    if (!context.json_output) for (const auto& item : result)
        for (const auto& error : item.value("diagnostics",Json::array()))
            if (error.is_string()) std::cerr << "coop: " << error.get<std::string>() << '\n';
    return 0;
}
}
