#include "package.hpp"
#include "data.hpp"
#include <algorithm>
#include <cctype>
#include <set>
#include <stdexcept>

namespace coop {
namespace {
bool effective(const Json& value) {
    if (value.is_null()) return false;
    if (value.is_boolean()) return value.get<bool>();
    if (value.is_string() || value.is_array()) return !value.empty();
    if (value.is_number()) return value != 0;
    return true;
}
std::vector<std::string> strings(const Json& value, const char* field) {
    if (value.is_null()) return {};
    if (value.is_string()) return {value.get<std::string>()};
    if (!value.is_array()) throw std::runtime_error(std::string(field)+" must be a string or string array");
    std::vector<std::string> result;
    for (const auto& item : value) {
        if (!item.is_string()) throw std::runtime_error(std::string(field)+" contains a non-string value");
        result.push_back(item.get<std::string>());
    }
    return result;
}
fs::path relative_path(const std::string& value, bool root_allowed = false) {
    fs::path path(wide(value));
    if (path.is_absolute() || path.has_root_name() || path.has_root_directory())
        throw std::runtime_error("Manifest path must be relative to its package");
    for (const auto& component : path) {
        if (component == L".") continue;
        validate_component(path_text(component));
    }
    path = path.lexically_normal();
    if (!root_allowed && (path.empty() || path == L".")) throw std::runtime_error("Manifest file path is empty");
    return path;
}
std::string lower(std::string text) {
    for (auto& c : text) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return text;
}
ArchiveKind archive_kind(const std::string& filename) {
    const auto name = lower(filename);
    if (name.ends_with(".zip")) return ArchiveKind::zip;
    if (name.ends_with(".7z")) return ArchiveKind::seven_zip;
    if (name.ends_with(".msi")) return ArchiveKind::msi;
    for (const auto* suffix : {".tar",".tar.gz",".tgz",".tar.xz",".txz",".tar.bz2",".tbz2",".tar.zst"})
        if (name.ends_with(suffix)) return ArchiveKind::tar;
    return ArchiveKind::none;
}
std::string script_text(const Json& value, const char* field) {
    std::string text;
    for (const auto& line : strings(value,field)) { if (!text.empty()) text += '\n'; text += line; }
    return text;
}
void unknown_fields(Package& package, const Json& object) {
    static const std::set<std::string> known = {"version","description","homepage","license","notes","suggest",
        "checkver","autoupdate","architecture","url","hash","bin","shortcuts","persist","env_add_path","env_set",
        "depends","extract_dir","extract_to","pre_install","post_install","pre_uninstall","post_uninstall",
        "installer","uninstaller","innosetup","psmodule","cookie","referer","##","_comment"};
    for (auto item = object.begin(); item != object.end(); ++item) {
        if (!known.contains(item.key())) package.diagnostics.push_back({DiagnosticKind::adapter,"unsupported-field","Unsupported Manifest field: "+item.key()});
    }
}
}
Package parse_package(const fs::path& path, const std::string& name, const std::string& bucket,
                      const std::string& architecture) {
    Package package;
    package.name = name;
    package.bucket = bucket;
    package.architecture = architecture;
    package.manifest_path = path;
    try {
        validate_component(name);
        if (!bucket.empty()) validate_component(bucket);
        if (architecture != "64bit" && architecture != "32bit" && architecture != "arm64")
            throw std::runtime_error("Unsupported architecture identifier");
        if (fs::file_size(path) > 16*1024*1024) throw std::runtime_error("Manifest exceeds 16 MiB limit");
        package.manifest_sha256 = sha256_file(path);
        const auto manifest = read_json(path);
        if (sha256_file(path) != package.manifest_sha256) throw std::runtime_error("Manifest changed while being read");
        if (!manifest.is_object()) throw std::runtime_error("Manifest must be an object");
        unknown_fields(package,manifest);
        package.version = manifest.at("version").get<std::string>();
        validate_component(package.version);
        const Json* selected = nullptr;
        if (manifest.contains("architecture")) {
            const auto& architectures = manifest.at("architecture");
            if (!architectures.is_object()) throw std::runtime_error("architecture must be an object");
            if (architectures.contains(architecture)) {
                if (!architectures.at(architecture).is_object()) throw std::runtime_error("Selected architecture must be an object");
                selected = &architectures.at(architecture);
                unknown_fields(package,*selected);
            }
        }
        const auto pick = [&](const char* field) -> Json {
            if (selected && selected->contains(field) && effective(selected->at(field))) return selected->at(field);
            return manifest.contains(field) ? manifest.at(field) : Json();
        };
        const auto urls = strings(pick("url"),"url");
        const auto hashes = strings(pick("hash"),"hash");
        const auto extract_dirs = strings(pick("extract_dir"),"extract_dir");
        const auto extract_targets = strings(pick("extract_to"),"extract_to");
        if (urls.empty()) package.diagnostics.push_back({DiagnosticKind::validation,"missing-artifact","No artifact for selected architecture"});
        if (urls.size() != hashes.size()) package.diagnostics.push_back({DiagnosticKind::validation,"artifact-hash-count","Each artifact requires its own hash"});
        std::size_t archive_index = 0;
        for (std::size_t i = 0; i < urls.size(); ++i) {
            Artifact artifact;
            const auto fragment = urls[i].find('#');
            artifact.url = urls[i].substr(0,fragment);
            // Scoop's url_filename uses the leaf after a #/ rename, then removes ?query.
            auto local_name = urls[i].substr(urls[i].find_last_of("/\\")+1);
            local_name = local_name.substr(0,local_name.find('?'));
            validate_component(local_name);
            artifact.filename = local_name;
            artifact.archive = archive_kind(local_name);
            if (i < hashes.size()) artifact.sha256 = lower(hashes[i]);
            if (artifact.sha256.starts_with("sha256:")) artifact.sha256.erase(0,7);
            if (artifact.sha256.size() != 64 || !std::all_of(artifact.sha256.begin(),artifact.sha256.end(),[](unsigned char c) { return std::isxdigit(c) != 0; }))
                package.diagnostics.push_back({DiagnosticKind::validation,"unsupported-hash","A valid SHA256 is required for "+artifact.filename});
            if (!artifact.url.starts_with("https://") && !artifact.url.starts_with("http://") && !artifact.url.starts_with("file://"))
                package.diagnostics.push_back({DiagnosticKind::adapter,"unsupported-download","Artifact URL scheme is not supported"});
            if (artifact.archive != ArchiveKind::none) {
                if (archive_index < extract_dirs.size()) artifact.extract_directory = relative_path(extract_dirs[archive_index],true);
                if (archive_index < extract_targets.size()) artifact.extract_destination = relative_path(extract_targets[archive_index],true);
                ++archive_index;
            }
            package.artifacts.push_back(std::move(artifact));
        }
        const auto bins = pick("bin");
        if (!bins.is_null()) {
            const auto items = bins.is_string() ? Json::array({bins}) : bins;
            if (!items.is_array()) throw std::runtime_error("bin must be a string or array");
            std::set<std::string> aliases;
            for (const auto& item : items) {
                const auto parts = strings(item,"bin entry");
                if (parts.empty() || parts.size() > 3) throw std::runtime_error("Invalid bin entry");
                CommandExposure command;
                command.target = relative_path(parts[0]);
                command.name = parts.size() > 1 ? parts[1] : path_text(command.target.stem());
                validate_component(command.name);
                if (!aliases.insert(lower(command.name)).second) throw std::runtime_error("Duplicate command alias");
                if (parts.size() > 2) command.arguments = parts[2];
                package.commands.push_back(std::move(command));
            }
        }
        const auto shortcuts = pick("shortcuts");
        if (!shortcuts.is_null()) {
            if (!shortcuts.is_array()) throw std::runtime_error("shortcuts must be an array");
            std::set<std::string> names;
            for (const auto& item : shortcuts) {
                const auto parts = strings(item,"shortcut");
                if (parts.size() < 2 || parts.size() > 4) throw std::runtime_error("Invalid shortcut");
                ShortcutExposure shortcut{relative_path(parts[0]),path_text(relative_path(parts[1])),{}, {}};
                // Scoop allows shortcut names such as "Git\\Git Bash" that create subfolders
                // below its Start Menu folder; they are still package-independent relative names.
                if (!names.insert(lower(shortcut.name)).second) throw std::runtime_error("Duplicate shortcut name");
                if (parts.size() > 2) shortcut.arguments = parts[2];
                if (parts.size() > 3) shortcut.icon = relative_path(parts[3]);
                package.shortcuts.push_back(std::move(shortcut));
            }
        }
        const auto persist = pick("persist");
        if (!persist.is_null()) {
            const auto items = persist.is_string() ? Json::array({persist}) : persist;
            if (!items.is_array()) throw std::runtime_error("persist must be a string or array");
            std::set<std::string> persist_sources, persist_targets;
            for (const auto& item : items) {
                const auto parts = strings(item,"persist entry");
                if (parts.empty() || parts.size() > 2) throw std::runtime_error("Invalid persist mapping");
                const auto source = relative_path(parts[0]);
                const auto target = relative_path(parts.size() == 2 ? parts[1] : parts[0]);
                if (!persist_sources.insert(lower(path_text(source))).second)
                    package.diagnostics.push_back({DiagnosticKind::validation,"duplicate-persist-source","Duplicate persist source: "+path_text(source)});
                if (!persist_targets.insert(lower(path_text(target))).second)
                    package.diagnostics.push_back({DiagnosticKind::validation,"duplicate-persist-target","Duplicate persist target: "+path_text(target)});
                package.persistence.push_back({source,target});
            }
        }
        package.dependencies = strings(pick("depends"),"depends");
        for (const auto& dependency : package.dependencies) {
            const auto slash = dependency.find('/');
            if (slash != std::string::npos) validate_component(dependency.substr(0,slash));
            validate_component(dependency.substr(slash == std::string::npos ? 0 : slash+1));
            if (dependency.find('@') != std::string::npos) package.diagnostics.push_back({DiagnosticKind::adapter,"dependency-version","Version-constrained dependencies are not supported"});
        }
        for (const auto& entry : strings(pick("env_add_path"),"env_add_path")) package.path_entries.push_back(relative_path(entry,true));
        const auto environment = pick("env_set");
        if (!environment.is_null()) {
            if (!environment.is_object()) throw std::runtime_error("env_set must be an object");
            for (auto item = environment.begin(); item != environment.end(); ++item) {
                if (item.key().empty() || item.key().find('=') != std::string::npos || item.key().find('\0') != std::string::npos)
                    throw std::runtime_error("Invalid environment variable name");
                package.environment.push_back({item.key(),item.value().get<std::string>()});
            }
        }
        for (const auto& entry : {std::pair{"pre_install",ScriptPhase::before_install}, {"post_install",ScriptPhase::after_install},
                                  {"pre_uninstall",ScriptPhase::before_uninstall}, {"post_uninstall",ScriptPhase::after_uninstall}}) {
            const auto text = script_text(pick(entry.first),entry.first);
            if (!text.empty()) package.scripts.push_back({entry.second,text});
        }
        for (const auto& field : {"installer","uninstaller"}) {
            const auto operation = pick(field);
            if (operation.is_null()) continue;
            if (!operation.is_object()) throw std::runtime_error(std::string(field)+" must be an object");
            const bool uninstall = std::string(field) == "uninstaller";
            if (operation.contains("file") || operation.contains("args")) {
                InstallerProcess process;
                const auto fallback = package.artifacts.empty() ? std::string{} : package.artifacts.front().filename;
                process.file = relative_path(operation.value("file",fallback));
                process.arguments = strings(operation.value("args",Json()),"installer arguments");
                process.keep = operation.value("keep",false);
                if (uninstall) package.uninstaller = std::move(process);
                else package.installer = std::move(process);
            }
            const auto script = script_text(operation.value("script",Json()),field);
            if (!script.empty()) package.scripts.push_back({uninstall ? ScriptPhase::uninstaller : ScriptPhase::installer,script});
            for (auto item = operation.begin(); item != operation.end(); ++item)
                if (item.key() != "file" && item.key() != "args" && item.key() != "keep" && item.key() != "script")
                    package.diagnostics.push_back({DiagnosticKind::adapter,"installer-field","Unsupported installer option: "+item.key()});
        }
        for (const auto* field : {"innosetup","psmodule","cookie","referer"})
            if (effective(pick(field))) package.diagnostics.push_back({DiagnosticKind::adapter,"unsupported-capability",std::string("Not yet supported: ")+field});
        if (package.version == "nightly") package.diagnostics.push_back({DiagnosticKind::adapter,"nightly-tracking","Nightly version tracking is not yet supported"});
    } catch (const Json::parse_error& error) {
        package.diagnostics.push_back({DiagnosticKind::syntax,"manifest-json",error.what()});
    } catch (const std::exception& error) {
        package.diagnostics.push_back({DiagnosticKind::adapter,"manifest-shape",error.what()});
    }
    return package;
}
}
