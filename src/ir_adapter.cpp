#include "ir.hpp"
#include "data.hpp"
#include "exposure.hpp"
#include <algorithm>
#include <cctype>
#include <set>
#include <stdexcept>

namespace coop::ir {
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
std::string lower(std::string text) {
    for (auto& character : text) character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    return text;
}
bool hexadecimal(const std::string& value) {
    return std::all_of(value.begin(),value.end(),[](unsigned char character) { return std::isxdigit(character) != 0; });
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
ArchiveFormat archive_format(const std::string& filename, bool innosetup) {
    const auto name = lower(filename);
    // Scoop applies Expand-InnoArchive only to an .exe artifact of an `innosetup` Manifest; every
    // other artifact keeps its ordinary archive handling.
    if (innosetup && name.ends_with(".exe")) return ArchiveFormat::inno_setup;
    // A NuGet package is a ZIP container. Scoop reaches for its external 7-Zip helper because the
    // suffix matches its archive list, but the extracted layout is the same ZIP tree the native
    // reader produces.
    if (name.ends_with(".zip") || name.ends_with(".nupkg")) return ArchiveFormat::zip;
    if (name.ends_with(".7z")) return ArchiveFormat::seven_zip;
    if (name.ends_with(".msi")) return ArchiveFormat::msi;
    // All of these are read by the native libarchive path with the compression filter compiled in:
    // gzip, xz, lzma, bzip2 and zstd all wrap an ordinary tar stream. The suffix list is source
    // recognition only; extraction decides whether the bytes really are a usable tar archive.
    for (const auto* suffix : {".tar",".tar.gz",".tgz",".tar.xz",".txz",".tar.lzma",".tlz",
                               ".tar.bz2",".tbz",".tbz2",".tar.zst",".tzst"})
        if (name.ends_with(suffix)) return ArchiveFormat::tar;
    return ArchiveFormat::file;
}
std::string script_text(const Json& value, const char* field) {
    std::string text;
    for (const auto& line : strings(value,field)) { if (!text.empty()) text += '\n'; text += line; }
    return text;
}
// Unknown source fields are source-level gaps: a later adapter may normalize them, the IR validator
// cannot. They are therefore reported by the adapter layer and never silently dropped.
void unknown_fields(Package& package, const Json& object) {
    static const std::set<std::string> known = {"version","description","homepage","license","notes","suggest",
        "checkver","autoupdate","architecture","url","hash","bin","shortcuts","persist","env_add_path","env_set",
        "depends","extract_dir","extract_to","pre_install","post_install","pre_uninstall","post_uninstall",
        "installer","uninstaller","innosetup","psmodule","cookie","referer","##","_comment"};
    for (auto item = object.begin(); item != object.end(); ++item) {
        if (!known.contains(item.key()))
            package.diagnostics.push_back({Layer::adapter,"unsupported-field","Unsupported Manifest field: "+item.key()});
    }
}
Digest parse_digest(const std::string& raw) {
    Digest digest;
    digest.declared = true;
    const auto colon = raw.find(':');
    if (colon != std::string::npos) {
        digest.spelling = lower(raw.substr(0,colon));
        digest.value = lower(raw.substr(colon+1));
        if (digest.spelling == "sha256") digest.algorithm = DigestAlgorithm::sha256;
        else if (digest.spelling == "sha512") digest.algorithm = DigestAlgorithm::sha512;
        else if (digest.spelling == "sha1") digest.algorithm = DigestAlgorithm::sha1;
        else if (digest.spelling == "md5") digest.algorithm = DigestAlgorithm::md5;
        else digest.algorithm = DigestAlgorithm::other;
        return digest;
    }
    digest.value = lower(raw);
    // Scoop's unprefixed form is the digest value of the manifest's default algorithm.
    digest.algorithm = digest.value.size() == 64 && hexadecimal(digest.value) ?
        DigestAlgorithm::sha256 : DigestAlgorithm::other;
    return digest;
}
std::vector<PersistenceMapping> persistence_mappings(const Json& manifest) {
    std::vector<PersistenceMapping> result;
    if (!manifest.contains("persist") || manifest.at("persist").is_null()) return result;
    const auto add_single = [&](const Json& value) {
        const auto path = path_text(fs::path(wide(value.get<std::string>())));
        result.push_back({path,path});
    };
    const auto add_pair = [&](const Json& value) {
        const auto source = path_text(fs::path(wide(value.at(0).get<std::string>())));
        const auto target = value.size() == 2 ? path_text(fs::path(wide(value.at(1).get<std::string>()))) : source;
        result.push_back({source,target});
    };
    const auto& persist = manifest.at("persist");
    if (persist.is_string()) add_single(persist);
    else if (persist.is_array()) for (const auto& entry : persist) {
        if (entry.is_string()) add_single(entry);
        else if (entry.is_array() && !entry.empty() && entry.size() <= 2 &&
                 std::all_of(entry.begin(),entry.end(),[](const Json& item) { return item.is_string(); })) add_pair(entry);
    }
    return result;
}
}
const char* layer_name(Layer layer) {
    switch (layer) {
    case Layer::syntax: return "syntax";
    case Layer::adapter: return "adapter";
    case Layer::validation: return "ir";
    case Layer::environment: return "environment";
    case Layer::capability: return "capability";
    case Layer::verification: return "verification";
    }
    return "unknown";
}
const char* digest_algorithm_name(DigestAlgorithm algorithm) {
    switch (algorithm) {
    case DigestAlgorithm::missing: return "missing";
    case DigestAlgorithm::sha256: return "sha256";
    case DigestAlgorithm::sha512: return "sha512";
    case DigestAlgorithm::sha1: return "sha1";
    case DigestAlgorithm::md5: return "md5";
    case DigestAlgorithm::other: return "other";
    }
    return "unknown";
}
const char* archive_format_name(ArchiveFormat format) {
    switch (format) {
    case ArchiveFormat::file: return "none";
    case ArchiveFormat::zip: return "zip";
    case ArchiveFormat::seven_zip: return "7z";
    case ArchiveFormat::tar: return "tar";
    case ArchiveFormat::msi: return "msi";
    case ArchiveFormat::inno_setup: return "inno-setup";
    }
    return "unknown";
}
const char* hook_stage_name(HookStage stage) {
    switch (stage) {
    case HookStage::pre_install: return "pre_install";
    case HookStage::installer: return "installer";
    case HookStage::post_install: return "post_install";
    case HookStage::pre_uninstall: return "pre_uninstall";
    case HookStage::uninstaller: return "uninstaller";
    case HookStage::post_uninstall: return "post_uninstall";
    }
    return "unknown";
}
Package adapt_manifest(const fs::path& path, const std::string& name, const std::string& bucket,
                       const std::string& architecture) {
    Package package;
    package.name = name;
    package.bucket = bucket;
    package.architecture = architecture;
    package.manifest_path = path_text(path);
    try {
        validate_component(name);
        if (!bucket.empty()) validate_component(bucket);
        if (architecture != "64bit" && architecture != "32bit" && architecture != "arm64")
            throw std::runtime_error("Unsupported architecture identifier");
        if (fs::file_size(path) > 16*1024*1024) throw std::runtime_error("Manifest exceeds 16 MiB limit");
        package.manifest_digest = sha256_file(path);
        const auto manifest = read_json(path);
        if (sha256_file(path) != package.manifest_digest) throw std::runtime_error("Manifest changed while being read");
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
        const auto extract_directories = strings(pick("extract_dir"),"extract_dir");
        const auto extract_destinations = strings(pick("extract_to"),"extract_to");
        const auto innosetup = effective(pick("innosetup"));
        package.declared_hash_count = hashes.size();
        std::size_t archive_index = 0;
        for (std::size_t index = 0; index < urls.size(); ++index) {
            Download download;
            const auto fragment = urls[index].find('#');
            download.renamed = fragment != std::string::npos;
            download.url = urls[index].substr(0,fragment);
            // Scoop's url_filename uses the leaf after a #/ rename, then removes ?query.
            auto local_name = urls[index].substr(urls[index].find_last_of("/\\")+1);
            local_name = local_name.substr(0,local_name.find('?'));
            validate_component(local_name);
            download.filename = local_name;
            download.format = archive_format(local_name,innosetup);
            // Scoop's `#/name` fragment renames the download. When an executable URL becomes an
            // archive name, the payload is an installer self-extractor; its real format (7z SFX or
            // NSIS) is decided later from the verified content, never by the declared suffix.
            if (download.format != ArchiveFormat::file && download.format != ArchiveFormat::msi &&
                download.format != ArchiveFormat::inno_setup) {
                auto source_name = download.url.substr(download.url.find_last_of("/\\")+1);
                source_name = source_name.substr(0,source_name.find('?'));
                download.installer_payload = lower(source_name).ends_with(".exe");
            }
            if (index < hashes.size()) download.digest = parse_digest(hashes[index]);
            if (download.format != ArchiveFormat::file) {
                if (archive_index < extract_directories.size())
                    download.extract_directory = path_text(relative_path(extract_directories[archive_index],true));
                if (archive_index < extract_destinations.size())
                    download.extract_destination = path_text(relative_path(extract_destinations[archive_index],true));
                ++archive_index;
            }
            package.downloads.push_back(std::move(download));
        }
        const auto bins = pick("bin");
        if (!bins.is_null()) {
            const auto items = bins.is_string() ? Json::array({bins}) : bins;
            if (!items.is_array()) throw std::runtime_error("bin must be a string or array");
            std::set<std::string> aliases;
            for (const auto& item : items) {
                const auto parts = strings(item,"bin entry");
                if (parts.empty() || parts.size() > 3) throw std::runtime_error("Invalid bin entry");
                Entry entry;
                entry.target = path_text(relative_path(parts[0]));
                entry.alias = parts.size() > 1 ? parts[1] : path_text(fs::path(wide(entry.target)).stem());
                validate_component(entry.alias);
                if (!aliases.insert(lower(entry.alias)).second) throw std::runtime_error("Duplicate command alias");
                if (parts.size() > 2) entry.arguments = parts[2];
                if (!launcher_kind(fs::path(wide(entry.target))))
                    package.diagnostics.push_back({Layer::adapter,"unsupported-command-host",
                        "Command entry target type is not supported: "+entry.target+
                        "; supported entries are EXE, COM, BAT, CMD, PS1 and JAR"});
                package.entries.push_back(std::move(entry));
            }
        }
        const auto shortcuts = pick("shortcuts");
        if (!shortcuts.is_null()) {
            if (!shortcuts.is_array()) throw std::runtime_error("shortcuts must be an array");
            std::set<std::string> names;
            for (const auto& item : shortcuts) {
                const auto parts = strings(item,"shortcut");
                if (parts.size() < 2 || parts.size() > 4) throw std::runtime_error("Invalid shortcut");
                Shortcut shortcut{path_text(relative_path(parts[0])),path_text(relative_path(parts[1])),{},{}};
                // Scoop allows shortcut names such as "Git\\Git Bash" that create subfolders
                // below its Start Menu folder; they are still package-independent relative names.
                if (!names.insert(lower(shortcut.name)).second) throw std::runtime_error("Duplicate shortcut name");
                if (parts.size() > 2) shortcut.arguments = parts[2];
                if (parts.size() > 3) shortcut.icon = path_text(relative_path(parts[3]));
                package.shortcuts.push_back(std::move(shortcut));
            }
        }
        const auto persist = pick("persist");
        if (!persist.is_null()) {
            const auto items = persist.is_string() ? Json::array({persist}) : persist;
            if (!items.is_array()) throw std::runtime_error("persist must be a string or array");
            for (const auto& item : items) {
                const auto parts = strings(item,"persist entry");
                if (parts.empty() || parts.size() > 2) throw std::runtime_error("Invalid persist mapping");
                const auto source = relative_path(parts[0]);
                const auto target = relative_path(parts.size() == 2 ? parts[1] : parts[0]);
                package.persistence.push_back({path_text(source),path_text(target)});
            }
        }
        for (const auto& dependency : strings(pick("depends"),"depends")) {
            Dependency resolved;
            resolved.source = dependency;
            auto identity = dependency;
            if (const auto at = identity.find('@'); at != std::string::npos) {
                resolved.version = identity.substr(at+1);
                identity.resize(at);
            }
            if (const auto slash = identity.find('/'); slash != std::string::npos) {
                resolved.bucket = identity.substr(0,slash);
                resolved.name = identity.substr(slash+1);
            } else {
                resolved.name = identity;
            }
            if (resolved.name.empty() || (!resolved.bucket.empty() && resolved.bucket.find('/') != std::string::npos))
                throw std::runtime_error("Invalid dependency name: "+dependency);
            validate_component(resolved.name);
            if (!resolved.bucket.empty()) validate_component(resolved.bucket);
            if (resolved.version.find('/') != std::string::npos)
                throw std::runtime_error("Invalid dependency version: "+dependency);
            package.dependencies.push_back(std::move(resolved));
        }
        for (const auto& entry : strings(pick("env_add_path"),"env_add_path")) {
            EnvironmentEntry setting;
            setting.variable = "PATH";
            setting.value = path_text(relative_path(entry,true));
            setting.path_entry = true;
            package.environment.push_back(std::move(setting));
        }
        const auto environment = pick("env_set");
        if (!environment.is_null()) {
            if (!environment.is_object()) throw std::runtime_error("env_set must be an object");
            for (auto item = environment.begin(); item != environment.end(); ++item) {
                if (item.key().empty() || item.key().find('=') != std::string::npos || item.key().find('\0') != std::string::npos)
                    throw std::runtime_error("Invalid environment variable name");
                package.environment.push_back({item.key(),item.value().get<std::string>(),false});
            }
        }
        for (const auto& entry : {std::pair{"pre_install",HookStage::pre_install},{"post_install",HookStage::post_install},
                                  {"pre_uninstall",HookStage::pre_uninstall},{"post_uninstall",HookStage::post_uninstall}}) {
            const auto text = script_text(pick(entry.first),entry.first);
            if (!text.empty()) package.hooks.push_back({entry.second,text,entry.first});
        }
        for (const auto& field : {"installer","uninstaller"}) {
            const auto operation = pick(field);
            if (operation.is_null()) continue;
            if (!operation.is_object()) throw std::runtime_error(std::string(field)+" must be an object");
            const bool uninstall = std::string(field) == "uninstaller";
            if (operation.contains("file") || operation.contains("args")) {
                InstallerProgram process;
                const auto fallback = package.downloads.empty() ? std::string{} : package.downloads.front().filename;
                process.file = path_text(relative_path(operation.value("file",fallback)));
                process.arguments = strings(operation.value("args",Json()),"installer arguments");
                process.keep = operation.value("keep",false);
                if (uninstall) package.uninstaller = std::move(process);
                else package.installer = std::move(process);
            }
            const auto script = script_text(operation.value("script",Json()),field);
            if (!script.empty())
                package.hooks.push_back({uninstall ? HookStage::uninstaller : HookStage::installer,script,std::string(field)+".script"});
            for (auto item = operation.begin(); item != operation.end(); ++item)
                if (item.key() != "file" && item.key() != "args" && item.key() != "keep" && item.key() != "script")
                    package.diagnostics.push_back({Layer::adapter,"installer-field","Unsupported installer option: "+item.key()});
        }
        // psmodule is translated into the IR module declaration below; `cookie` and `referer` remain
        // unsupported source declarations.
        for (const auto* field : {"cookie","referer"})
            if (effective(pick(field)))
                package.diagnostics.push_back({Layer::adapter,"unsupported-capability",std::string("Not yet supported: ")+field});
        const auto psmodule = pick("psmodule");
        if (!psmodule.is_null()) {
            if (!psmodule.is_object()) throw std::runtime_error("psmodule must be an object");
            if (!psmodule.contains("name") || !psmodule.at("name").is_string())
                throw std::runtime_error("Invalid manifest: The 'name' property is missing from 'psmodule'.");
            const auto module_name = psmodule.at("name").get<std::string>();
            if (module_name.empty())
                throw std::runtime_error("Invalid manifest: The 'name' property is missing from 'psmodule'.");
            // Scoop uses the name verbatim as the <root>/modules directory entry, so it must obey the
            // same safe component boundary as every other managed path.
            validate_component(module_name);
            package.psmodule = PsModule{module_name};
            for (auto item = psmodule.begin(); item != psmodule.end(); ++item)
                if (item.key() != "name")
                    package.diagnostics.push_back({Layer::adapter,"psmodule-field","Unsupported psmodule option: "+item.key()});
        }
    } catch (const Json::parse_error& error) {
        package.diagnostics.push_back({Layer::syntax,"manifest-json",error.what()});
    } catch (const std::exception& error) {
        package.diagnostics.push_back({Layer::adapter,"manifest-shape",error.what()});
    }
    return package;
}
std::vector<InstalledFact> read_installations(const fs::path& root) {
    std::vector<InstalledFact> result;
    const auto apps = root / L"apps";
    if (!fs::exists(apps)) return result;
    for (const auto& app : fs::directory_iterator(apps)) {
        if (!app.is_directory() || app.path().filename() == L"scoop") continue;
        InstalledFact fact;
        fact.name = path_text(app.path().filename());
        try {
            const auto current = app.path() / L"current";
            if (!fs::is_directory(current)) throw std::runtime_error("No usable current directory");
            const auto manifest = read_json(installed_record(current, L"manifest"));
            if (!manifest.is_object()) throw std::runtime_error("Installation records must be objects");
            fact.version = manifest.at("version").get<std::string>();
            fact.persistence = persistence_mappings(manifest);
            fact.present = true;
            // The install record is separate evidence. Losing it must not hide the version that the
            // saved manifest still proves.
            try {
                const auto install = read_json(installed_record(current, L"install"));
                if (!install.is_object()) throw std::runtime_error("Installation records must be objects");
                fact.bucket = install.value("bucket", std::string{});
                fact.source = install.value("url", install.value("bucket",std::string("unknown")));
                fact.architecture = install.value("architecture", std::string{});
            } catch (const Json::parse_error& error) {
                fact.diagnostics.push_back({Layer::syntax,"install-record-syntax",error.what()});
            } catch (const std::exception& error) {
                fact.diagnostics.push_back({Layer::adapter,"install-record-unreadable",error.what()});
            }
            fact.directory = operating_path(fs::canonical(current));
        } catch (const Json::parse_error& error) {
            fact.diagnostics.push_back({Layer::syntax,"install-record-syntax",error.what()});
        } catch (const std::exception& error) {
            fact.diagnostics.push_back({Layer::adapter,"install-record-unreadable",error.what()});
        }
        result.push_back(std::move(fact));
    }
    std::sort(result.begin(), result.end(), [](const InstalledFact& a, const InstalledFact& b) {
        return a.name < b.name;
    });
    return result;
}
}
