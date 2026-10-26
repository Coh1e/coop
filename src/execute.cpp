#include "package.hpp"
#include "data.hpp"
#include "native.hpp"
#include "archive.hpp"
#include "persist.hpp"
#include "versions.hpp"
#include "exposure.hpp"
#include "user_environment.hpp"
#include "script.hpp"
#include "shim.hpp"
#include "inno.hpp"
#include "msi.hpp"
#include "nsis.hpp"
#include "faults.hpp"
#include <windows.h>
#include <cstdint>
#include <array>
#include <cctype>
#include <iostream>
#include <stdexcept>
#include <algorithm>
#include <iterator>
#include <fstream>
#include <map>

namespace coop {
namespace {
void ordinary_parents(const fs::path& root, const fs::path& path) {
    const auto relative = path.lexically_relative(root);
    if (relative.empty() || relative.is_absolute()) throw std::runtime_error("Operation outside selected root");
    auto current = root;
    for (const auto& part : relative) {
        validate_component(path_text(part));
        current /= part;
        const auto attributes = GetFileAttributesW(current.c_str());
        if (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_REPARSE_POINT))
            throw std::runtime_error("Managed destination contains a reparse point");
    }
}
void require_capabilities(const Context& context, const Package& package) {
    if (!package.diagnostics.empty()) throw std::runtime_error("Manifest has unsupported or invalid requirements; inspect --dry-run");
    if (package.artifacts.empty()) throw std::runtime_error("Package has no install artifacts");
    // Hook scripts and installer/uninstaller programs share one host requirement: a real PowerShell
    // interpreter plus the pinned Scoop compatibility library. Both are reported before any write.
    if (!package.scripts.empty() || package.installer || package.uninstaller) {
        const auto host = script_host();
        if (!host.problem.empty()) throw std::runtime_error(host.problem);
    }
    const auto lower_name = [](std::string value) {
        for (auto& character : value) character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
        return value;
    };
    for (const auto& artifact : package.artifacts) {
        switch (artifact.archive) {
        case ArchiveKind::none:
        case ArchiveKind::zip:
            break;
        case ArchiveKind::tar: {
            const auto name = lower_name(artifact.filename);
            const bool supported = name.ends_with(".tar") || name.ends_with(".tar.gz") || name.ends_with(".tgz") ||
                name.ends_with(".tar.xz") || name.ends_with(".txz") || name.ends_with(".tar.lzma") ||
                name.ends_with(".tlz") || name.ends_with(".tar.bz2") || name.ends_with(".tbz") ||
                name.ends_with(".tbz2") || name.ends_with(".tar.zst") || name.ends_with(".tzst");
            if (!supported) throw std::runtime_error("This tar compression is not supported; gzip, xz, lzma, bzip2 and zstd tar streams are enabled");
            break;
        }
        case ArchiveKind::seven_zip:
            break;
        case ArchiveKind::msi:
            if (!msi_database_api() || !cabinet_api())
                throw std::runtime_error("MSI extraction requires the Windows Installer database API (msi.dll) and the Windows cabinet decompression API (cabinet.dll), Windows system components that were not found; Coop never downloads or installs external tools, and it never falls back to msiexec.exe");
            break;
        case ArchiveKind::inno_setup: {
            const auto helper = inno_helper(context);
            if (helper.path.empty()) throw std::runtime_error(helper.problem);
            break;
        }
        }
    }
    for (const auto& command : package.commands)
        if (!launcher_kind(command.target))
            throw std::runtime_error("Command entry target type is not supported: "+path_text(command.target)+
                "; supported entries are EXE, COM, BAT, CMD, PS1 and JAR");
}
fs::path record_relative_path(const std::string& value) {
    fs::path path(wide(value));
    if (path.empty() || path.is_absolute() || path.has_root_name() || path.has_root_directory())
        throw std::runtime_error("Managed command target is not a package-relative path");
    for (const auto& part : path) validate_component(path_text(part));
    return path.lexically_normal();
}
void verify_installed_files(const Json& managed, const fs::path& directory, const Package& installed) {
    if (managed.contains("command_targets") && managed.at("command_targets").is_array()) {
        for (const auto& command : installed.commands) {
            const auto entry = std::find_if(managed.at("command_targets").begin(),managed.at("command_targets").end(),[&](const Json& item) {
                return item.is_object() && equal_name(item.value("path",std::string{}),path_text(command.target));
            });
            if (entry == managed.at("command_targets").end()) throw std::runtime_error("Managed command target record is missing");
            const auto target = directory/record_relative_path(entry->at("path").get<std::string>());
            if (!fs::is_regular_file(target)) throw std::runtime_error("Managed command target is missing");
            if (sha256_file(target) != entry->at("sha256").get<std::string>()) throw std::runtime_error("Managed command target changed; refusing operation");
        }
        return;
    }
    for (const auto& artifact : installed.artifacts) {
        if (artifact.archive != ArchiveKind::none)
            throw std::runtime_error("Installed archive layout has no verified file evidence; refusing operation");
        const auto path = directory/wide(artifact.filename);
        if (!fs::is_regular_file(path)) throw std::runtime_error("Installed artifact is missing; refusing operation");
        if (digest_file(path,artifact.algorithm) != artifact.digest)
            throw std::runtime_error("Installed artifact changed; refusing operation");
    }
}
bool verify_shortcut_ownership(const Context& context, const Package& installed, const Json& managed,
                               const ShortcutExposure& shortcut, const fs::path& link,
                               const fs::path& installed_directory) {
    // A shortcut removed outside Coop is already revoked: there is nothing left to own or
    // protect, so update/uninstall records the observation and continues. A shortcut that is
    // still present but changed is still refused below.
    if (!fs::is_regular_file(link)) return false;
    const auto expected_arguments = expand_exposure_arguments(context,installed.name,
        context.root/L"apps"/wide(installed.name)/L"current",shortcut.arguments);
    std::string expected;
    fs::path recorded;
    bool has_record = false;
    if (managed.contains("legacy_shortcuts") && managed.at("legacy_shortcuts").is_object() &&
        managed.at("legacy_shortcuts").contains(shortcut.name)) {
        const auto& entry = managed.at("legacy_shortcuts").at(shortcut.name);
        recorded = fs::path(wide(entry.at("path").get<std::string>()));
        expected = entry.at("sha256").get<std::string>();
        has_record = true;
    } else if (managed.contains("shortcuts") && managed.at("shortcuts").is_array()) {
        const auto& entries = managed.at("shortcuts");
        const auto found = std::find_if(entries.begin(),entries.end(),[&](const Json& item) {
            return item.is_object() && equal_name(item.value("name",std::string{}),shortcut.name);
        });
        if (found == entries.end()) throw std::runtime_error("Managed shortcut record is missing");
        recorded = fs::path(wide(found->at("path").get<std::string>()));
        expected = found->at("sha256").get<std::string>();
        has_record = true;
    }
    if (has_record) {
        if (!same_identity(recorded,link)) throw std::runtime_error("Managed shortcut path changed");
        if (sha256_file(link) != expected) {
            // The other client may rewrite an equivalent shortcut (for example Scoop reset).
            // Ownership is confirmed by the launch identity, not by one client's exact bytes;
            // an unreadable or different target/argument/icon is still refused.
            const auto identity = read_shortcut(link);
            const bool same_launch = identity && same_identity(identity->target,installed_directory/shortcut.target) &&
                identity->arguments == expected_arguments &&
                (shortcut.icon.empty() || identity->icon.empty() || same_identity(identity->icon,installed_directory/shortcut.icon));
            if (!same_launch)
                throw std::runtime_error("Shortcut was modified externally; refusing to remove or replace it: "+path_text(link));
        }
        return true;
    }
    // A shared Scoop installation has no Coop record. Its shortcut is still owned only when the
    // current identity matches the package manifest exactly; otherwise it is left untouched.
    const auto identity = read_shortcut(link);
    if (!identity) throw std::runtime_error("Shared shortcut cannot be read: "+path_text(link));
    const auto target = installed_directory/shortcut.target;
    if (!same_identity(identity->target,target))
        throw std::runtime_error("Shared shortcut points to a different target: "+path_text(link));
    if (identity->arguments != expected_arguments)
        throw std::runtime_error("Shared shortcut uses different arguments: "+path_text(link));
    if (!shortcut.icon.empty() && !identity->icon.empty() && !same_identity(identity->icon,installed_directory/shortcut.icon))
        throw std::runtime_error("Shared shortcut uses a different icon: "+path_text(link));
    return true;
}
void prune_empty_shortcut_directories(const Context& context, const std::vector<fs::path>& links) {
    const auto base = shortcut_directory(context).lexically_normal();
    for (const auto& link : links) {
        auto directory = link.parent_path().lexically_normal();
        for (;;) {
            const auto relative = directory.lexically_relative(base);
            if (relative.empty() || relative.is_absolute() || relative == L".") break;
            if (relative.begin() != relative.end() && *relative.begin() == L"..") break;
            std::error_code error;
            if (!fs::is_directory(directory,error) || error) break;
            if (!fs::is_empty(directory,error) || error) break;
            if (!fs::remove(directory,error) || error) break;
            directory = directory.parent_path();
        }
    }
}
void publish_new(const fs::path& source, const fs::path& destination) {
    DWORD error = ERROR_SUCCESS;
    // Antivirus scanners and just-exited programs can hold a published file briefly. Retry
    // within a bounded window instead of killing a user process or claiming a false success.
    for (int attempt = 0; attempt < 15; ++attempt) {
        if (MoveFileExW(source.c_str(),destination.c_str(),MOVEFILE_WRITE_THROUGH)) return;
        error = GetLastError();
        if (error != ERROR_SHARING_VIOLATION && error != ERROR_LOCK_VIOLATION && error != ERROR_ACCESS_DENIED) break;
        Sleep(200);
    }
    throw std::runtime_error("Destination cannot be published (Windows error "+std::to_string(error)+"); close the program and retry");
}
// A shared Scoop installation has no Coop record. Its direct-file artifacts are still verifiable
// from the saved Manifest: each declared file must exist in the version directory and match the
// declared algorithm. An archive installation is an extracted tree, and Scoop records no digest
// for that tree. For it, the installation facts are the standard apps/<name>/current layout, the
// saved Manifest/install record already parsed into the package, every declared command or
// shortcut target existing below the version directory, and an inspectable tree with no reparse
// point at its root. This is the same ownership boundary Scoop uses for reset/uninstall; the
// version directory itself is package-owned, while declared persistent data is handled separately.
void verify_shared_artifacts(const Package& installed, const fs::path& directory) {
    if (installed.artifacts.empty()) throw std::runtime_error("Shared installation has no recorded artifacts");
    bool archive_layout = false;
    for (const auto& artifact : installed.artifacts) {
        if (artifact.archive != ArchiveKind::none) { archive_layout = true; continue; }
        const auto path = directory/wide(artifact.filename);
        if (!fs::is_regular_file(path)) throw std::runtime_error("Shared installation artifact is missing: "+artifact.filename);
        if (digest_file(path,artifact.algorithm) != artifact.digest)
            throw std::runtime_error("Shared installation artifact changed: "+artifact.filename);
    }
    if (!archive_layout) return;
    if (!fs::is_directory(directory)) throw std::runtime_error("Shared archive installation directory is missing");
    try { version_tree_stamp(directory); }
    catch (const std::exception& error) {
        throw std::runtime_error(std::string("Shared archive layout cannot be inspected: ")+error.what());
    }
    for (const auto& command : installed.commands) {
        const auto target = directory/command.target;
        if (!fs::is_regular_file(target))
            throw std::runtime_error("Shared archive command target is missing: "+path_text(command.target));
    }
    for (const auto& shortcut : installed.shortcuts) {
        const auto target = directory/shortcut.target;
        if (!fs::is_regular_file(target))
            throw std::runtime_error("Shared archive shortcut target is missing: "+path_text(shortcut.target));
    }
}
bool path_is_under(const fs::path& path, const fs::path& base) {
    const auto normalized = path.lexically_normal();
    const auto normalized_base = base.lexically_normal();
    auto entry = normalized.begin();
    for (auto base_entry = normalized_base.begin(); base_entry != normalized_base.end(); ++base_entry,++entry) {
        if (entry == normalized.end() ||
            CompareStringOrdinal(entry->c_str(),-1,base_entry->c_str(),-1,TRUE) != CSTR_EQUAL) return false;
    }
    return entry != normalized.end();
}
// Journal paths are absolute. Recovery accepts only Coop's root and the isolated shortcut
// directory, rejects parent reparse points, and permits a reparse point only as the final
// managed junction (for example apps/<package>/current).
bool recovery_path_allowed(const Context& context, const fs::path& path) {
    if (path.empty() || !path.is_absolute()) return false;
    // Journal paths are only trusted inside the managed subtrees that the execution protocol
    // writes. Requiring the expected depth prevents a corrupt journal from naming "apps" or a
    // whole package directory as a created path and deleting more than one transaction owns.
    const std::vector<std::pair<fs::path,std::size_t>> roots = {
        {context.root/L"apps",2},
        {context.root/L"shims",1},
        {context.root/L".coop"/L"packages",1},
        {context.root/L".coop"/L"transactions",2},
        {context.root/L".coop"/L"retained",1},
        {shortcut_directory(context),1}};
    fs::path base;
    std::size_t minimum = 0;
    std::size_t best = 0;
    for (const auto& [root,depth] : roots) {
        if (!path_is_under(path,root)) continue;
        const auto normalized_root = root.lexically_normal();
        const auto size = static_cast<std::size_t>(std::distance(normalized_root.begin(),normalized_root.end()));
        if (base.empty() || size > best) { base = root; best = size; minimum = depth; }
    }
    if (base.empty()) return false;
    const auto normalized = path.lexically_normal();
    const auto normalized_base = base.lexically_normal();
    auto entry = normalized.begin();
    for (auto base_entry = normalized_base.begin(); base_entry != normalized_base.end(); ++base_entry) ++entry;
    if (static_cast<std::size_t>(std::distance(entry,normalized.end())) < minimum) return false;
    auto current = base;
    for (; entry != normalized.end(); ++entry) {
        validate_component(path_text(*entry));
        current /= *entry;
        const auto attributes = GetFileAttributesW(current.c_str());
        if (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_REPARSE_POINT) &&
            std::next(entry) != normalized.end()) return false;
    }
    return true;
}
// Creation evidence. Recovery may only delete an object that is still the one Coop created.
// The file identity (volume serial + file index) survives content changes and detects a replaced
// object; a created regular file also records its digest, and a created reparse point records its
// target so a later repoint is visible. Directory contents legitimately change after creation
// (extraction, hooks, installers, persistence links), so directories use identity only.
struct FileIdentity { std::uint64_t volume = 0; std::uint64_t index = 0; };
bool file_identity(const fs::path& path, FileIdentity& identity) {
    const auto handle = CreateFileW(path.c_str(),FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,nullptr);
    if (handle == INVALID_HANDLE_VALUE) return false;
    BY_HANDLE_FILE_INFORMATION info{};
    const auto ok = GetFileInformationByHandle(handle,&info);
    CloseHandle(handle);
    if (!ok) return false;
    identity.volume = info.dwVolumeSerialNumber;
    identity.index = (static_cast<std::uint64_t>(info.nFileIndexHigh)<<32)|info.nFileIndexLow;
    return true;
}
Json ownership_evidence(const fs::path& path) {
    Json evidence = Json::object();
    FileIdentity identity;
    if (file_identity(path,identity))
        evidence["file_identity"] = {{"volume",identity.volume},{"index",identity.index}};
    const auto attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES) return evidence;
    if (attributes & FILE_ATTRIBUTE_REPARSE_POINT) {
        evidence["kind"] = "reparse";
        std::error_code error;
        const auto target = fs::read_symlink(path,error);
        if (!error) evidence["target"] = path_text(target);
    } else if (attributes & FILE_ATTRIBUTE_DIRECTORY) {
        evidence["kind"] = "directory";
    } else {
        evidence["kind"] = "file";
        if (fs::is_regular_file(path)) evidence["sha256"] = sha256_file(path);
    }
    return evidence;
}
// Returns an empty string when the journaled creation evidence still describes this object, a
// stable conflict code and detail otherwise. Journals written before creation evidence existed
// report "not-recorded" and keep the older owned-flag behavior.
std::string ownership_conflict(const Json& evidence, const fs::path& path, std::string& detail) {
    detail.clear();
    if (!evidence.is_object() || evidence.empty()) return "ownership-evidence-not-recorded";
    if (evidence.contains("file_identity")) {
        FileIdentity current;
        if (file_identity(path,current)) {
            const auto& recorded = evidence.at("file_identity");
            if (recorded.value("volume",std::uint64_t{0}) != current.volume ||
                recorded.value("index",std::uint64_t{0}) != current.index) {
                detail = "The created path is a different object than the one Coop recorded: "+path_text(path);
                return "created-path-replaced";
            }
        } else {
            detail = "The created path can no longer be opened for its recorded identity: "+path_text(path);
            return "created-path-unreadable";
        }
    }
    const auto kind = evidence.value("kind",std::string{});
    if (kind == "file" && evidence.contains("sha256") && evidence.at("sha256").is_string()) {
        if (!fs::is_regular_file(path)) {
            detail = "The created file was replaced by a directory: "+path_text(path);
            return "created-path-replaced";
        }
        if (sha256_file(path) != evidence.at("sha256").get<std::string>()) {
            detail = "The created file was modified after Coop created it: "+path_text(path);
            return "created-file-modified";
        }
    }
    if (kind == "reparse" && evidence.contains("target") && evidence.at("target").is_string()) {
        std::error_code error;
        const auto target = fs::read_symlink(path,error);
        if (error || path_text(target) != evidence.at("target").get<std::string>()) {
            detail = "The created link now points somewhere else than Coop recorded: "+path_text(path);
            return "created-link-repointed";
        }
    }
    return {};
}
bool same_path_text(const fs::path& a, const fs::path& b) {
    const auto left = a.lexically_normal().wstring();
    const auto right = b.lexically_normal().wstring();
    return CompareStringOrdinal(left.c_str(),-1,right.c_str(),-1,TRUE) == CSTR_EQUAL;
}
std::string coop_launcher_hash() {
    std::array<wchar_t,32768> module{};
    const auto length = GetModuleFileNameW(nullptr,module.data(),static_cast<DWORD>(module.size()));
    if (!length || length >= module.size()) throw std::runtime_error("Cannot find native command launcher");
    return sha256_file(fs::path(module.data()));
}
// Scoop copies the same shim executable for every command it creates. A launcher whose bytes are
// shared with another .shim entry in the same root is therefore Scoop-generated even when a future
// Scoop release changes the shim program markers.
bool shared_scoop_launcher(const Context& context, const std::string& name, const std::string& digest) {
    const auto shims = context.root/L"shims";
    if (!fs::is_directory(shims)) return false;
    for (const auto& entry : fs::directory_iterator(shims)) {
        if (!entry.is_regular_file() || entry.path().extension() != L".shim") continue;
        const auto other_name = path_text(entry.path().stem());
        if (equal_name(other_name,name)) continue;
        const auto executable = shims/(entry.path().stem().wstring()+L".exe");
        if (fs::is_regular_file(executable) && sha256_file(executable) == digest) return true;
    }
    return false;
}
// Direct EXE/COM entries have an exact Scoop-compatible representation (path + optional args).
// Other host kinds need Coop's explicit launcher metadata, so they keep the .coop-shim.json form.
bool prefer_scoop_shim(const Package& package) {
    return package.environment.empty() && package.path_entries.empty() &&
        std::all_of(package.commands.begin(),package.commands.end(),[](const CommandExposure& command) {
            const auto kind = launcher_kind(command.target);
            return kind && *kind == LauncherKind::direct;
        });
}
struct InstalledEntry {
    std::string name;
    std::string format;
    fs::path executable;
    fs::path metadata;
    std::string executable_hash;
    std::string metadata_hash;
};
// Preview and execution must agree on whether an existing shared entry can be replaced/removed.
// The .shim target/arguments are the ownership evidence; the launcher must either be Coop's own
// binary, the exact launcher recorded by Coop, or a Scoop shim identified by its program markers.
std::string command_entry_blocker(const Context& context, const Package& installed) {
    const auto shims = context.root/L"shims";
    const auto module_hash = coop_launcher_hash();
    Json record = Json::object();
    const auto record_path = context.root/L".coop"/L"packages"/(wide(installed.name)+L".json");
    if (fs::is_regular_file(record_path)) {
        try { record = read_json(record_path); }
        catch (const std::exception&) { /* The record is optional evidence; shared facts remain authoritative. */ }
    }
    for (const auto& command : installed.commands) {
        const auto expected_arguments = expand_exposure_arguments(context,installed.name,
            context.root/L"apps"/wide(installed.name)/L"current",command.arguments);
        const auto exe = shims/(wide(command.name)+L".exe");
        const auto coop_metadata = shims/(wide(command.name)+L".coop-shim.json");
        const auto scoop_metadata = shims/(wide(command.name)+L".shim");
        if (!fs::is_regular_file(exe)) {
            if (fs::exists(coop_metadata) || fs::exists(scoop_metadata)) return "Managed command entry is missing: "+command.name;
            if (!scoop_entry_wrappers(context,installed.name,{command.name}).empty()) continue;
            return "Managed command entry is missing: "+command.name;
        }
        if (fs::exists(coop_metadata) && fs::exists(scoop_metadata))
            return "Command entry has conflicting Coop and Scoop metadata: "+command.name;
        if (fs::exists(coop_metadata)) {
            Json metadata;
            try { metadata = read_json(coop_metadata); }
            catch (const std::exception& error) { return "Managed command metadata cannot be read: "+std::string(error.what()); }
            if (!equal_name(metadata.value("package",std::string{}),installed.name) ||
                !same_identity(fs::path(wide(metadata.value("target",std::string{}))),context.root/L"apps"/wide(installed.name)/L"current"/command.target) ||
                metadata.value("arguments",std::string{}) != expected_arguments ||
                metadata.value("launcher",std::string{}) != command_launcher_name(command.target))
                return "Managed command entry ownership changed: "+command.name;
        } else if (fs::exists(scoop_metadata)) {
            ShimMetadata metadata;
            try { metadata = read_shim_metadata(scoop_metadata); }
            catch (const std::exception& error) { return "Scoop command metadata cannot be read: "+std::string(error.what()); }
            if (!same_identity(fs::path(wide(metadata.target)),context.root/L"apps"/wide(installed.name)/L"current"/command.target) ||
                (!expected_arguments.empty() && metadata.arguments != expected_arguments))
                return "Scoop command entry points to a different package or arguments: "+command.name;
            const auto executable_hash = sha256_file(exe);
            bool known = executable_hash == module_hash || looks_like_scoop_shim(exe) ||
                shared_scoop_launcher(context,command.name,executable_hash);
            if (record.contains("legacy_shims") && record.at("legacy_shims").is_object() &&
                record.at("legacy_shims").contains(command.name))
                known = known || executable_hash ==
                    record.at("legacy_shims").at(command.name).value("executable_sha256",std::string{});
            if (!known) return "Shared Scoop command launcher is not recognized and is not recorded by Coop: "+command.name;
        } else {
            return "Managed command entry metadata is missing: "+command.name;
        }
    }
    return {};
}
}
std::string package_execution_blocker(const Context& context, const Package& package) {
    try { require_capabilities(context,package); } catch (const std::exception& error) { return error.what(); }
    return {};
}
std::string execution_blocker(const Context& context, const Plan& plan) {
    if (plan.action == Action::adopt) {
        if (plan.adoption && plan.adoption->eligibility == AdoptionEligibility::already_managed) return {};
        for (const auto& dependency : plan.dependencies)
            if (!dependency.installed)
                return "Declared dependency is not installed: "+dependency.request;
        if (!plan.adoption || plan.adoption->eligibility != AdoptionEligibility::eligible)
            return "Package is not eligible for in-place adoption; inspect --dry-run";
        return {};
    }
    if (plan.action != Action::install && plan.action != Action::uninstall && plan.action != Action::update &&
        plan.action != Action::reset) return "This action is not executable yet";
    // Reverse dependency protection is the first reason an uninstall can be refused. Reporting it
    // before unrelated lifecycle gaps keeps the user-facing failure about the dependent package.
    if (plan.action == Action::uninstall) {
        if (!plan.blocking_dependents.empty()) return "Installed packages still depend on this package: "+plan.blocking_dependents.front();
        if (!plan.unverified_dependents.empty()) return "Dependency evidence is incomplete for installed packages: "+plan.unverified_dependents.front();
    }
    try {
        require_capabilities(context,plan.package);
        if (plan.previous) require_capabilities(context,*plan.previous);
    } catch (const std::exception& error) { return error.what(); }
    if (plan.action == Action::update && plan.previous && !same_persistence(*plan.previous,plan.package))
        return "Persistence mapping changes are not verified; refusing to update declared data";
    if (plan.action == Action::reset && plan.previous && !same_persistence(*plan.previous,plan.package))
        return "Persistence mapping changes are not verified; refusing to roll back declared data";
    if (plan.action == Action::update || plan.action == Action::uninstall || plan.action == Action::reset) {
        const auto& current = plan.action == Action::uninstall ? plan.package : *plan.previous;
        try { verify_persistence(context,current,plan.local.directory); }
        catch (const std::exception& error) { return std::string("Managed persistence state cannot be verified: ")+error.what(); }
    }
    if (plan.action == Action::reset) {
        // Rollback re-publishes a version directory that is already on disk. It is not a download
        // path: the saved Manifest, installation record and actual files are the whole input.
        if (!plan.previous || !plan.local.exists) return "No usable current installation exists for this package";
        if (plan.package.version.empty()) return "Reset target version is missing";
        const auto target = context.root/L"apps"/wide(plan.package.name)/wide(plan.package.version);
        const auto attributes = GetFileAttributesW(target.c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES || !(attributes & FILE_ATTRIBUTE_DIRECTORY))
            return "Local version directory is missing: "+path_text(target);
        if (attributes & FILE_ATTRIBUTE_REPARSE_POINT)
            return "Local version directory is a reparse point; reset does not follow it";
        try { verify_shared_artifacts(plan.package,target); }
        catch (const std::exception& error) { return "Local version cannot be verified for rollback: "+std::string(error.what()); }
        try { verify_persistence(context,plan.package,target); }
        catch (const std::exception& error) { return "Local version persistence cannot be verified for rollback: "+std::string(error.what()); }
    }
    if (plan.purge) {
        if (plan.action != Action::uninstall) return "--purge is only supported by uninstall";
        const auto record = context.root/L".coop"/L"packages"/(wide(plan.package.name)+L".json");
        if (!fs::is_regular_file(record)) return "Package is unadopted; purge is refused";
        try {
            const auto managed = read_json(record);
            purge_scope(context,plan.package,plan.local.directory,managed.value("persistence",Json::array()));
        } catch (const std::exception& error) {
            return std::string("Purge scope cannot be verified: ")+error.what();
        }
    }
    if (plan.action == Action::update || plan.action == Action::reset) {
        for (const auto& dependency : plan.dependencies)
            if (!dependency.installed)
                return "Declared dependency is not installed: "+dependency.request;
    }
    // Installs may carry planned dependencies; their own plans are executed before this package.
    // A dependency that is neither installed nor planned cannot happen in a resolved plan, but a
    // missing IR sequence would make that state silently acceptable, so refuse it explicitly.
    if (plan.action == Action::install) {
        for (const auto& dependency : plan.dependencies)
            if (!dependency.installed && dependency.steps.empty())
                return "Declared dependency has no executable plan: "+dependency.request;
    }
    if (!plan.blocking_dependents.empty()) return "Installed packages still depend on this package: "+plan.blocking_dependents.front();
    if (!plan.unverified_dependents.empty()) return "Dependency evidence is incomplete for installed packages: "+plan.unverified_dependents.front();
    if (!plan.diagnostics.empty()) return "Plan has unresolved diagnostics";
    if (plan.ir_steps.empty()) return "Plan contains no IR operations; execution is refused";
    if (plan.action == Action::install && plan.local.exists) return "Package already exists; use update";
    if ((plan.action == Action::uninstall || plan.action == Action::update || plan.action == Action::reset) && !plan.local.exists)
        return "No usable current installation exists for this package";
    // Shared Scoop installations have no Coop private record. Direct-file artifacts (including
    // multiple downloads) are verified from the saved Manifest and actual files. Archive layouts
    // are verified from the standard apps/<name>/current tree, the saved records and every declared
    // entry target; no private Coop record is a precondition.
    if ((plan.action == Action::uninstall || plan.action == Action::update || plan.action == Action::reset) &&
        !fs::exists(context.root/L".coop"/L"packages"/(wide(plan.package.name)+L".json"))) {
        const auto& facts = (plan.action == Action::update || plan.action == Action::reset) && plan.previous ? *plan.previous : plan.package;
        try { verify_shared_artifacts(facts,plan.local.directory); }
        catch (const std::exception& error) { return error.what(); }
    }
    if (plan.action == Action::uninstall || plan.action == Action::update || plan.action == Action::reset) {
        const auto& facts = (plan.action == Action::update || plan.action == Action::reset) && plan.previous ? *plan.previous : plan.package;
        const auto entry_blocker = command_entry_blocker(context,facts);
        if (!entry_blocker.empty()) return entry_blocker;
    }
    return {};
}
int execute_plan(const Context& context, const Plan& plan) {
    if (plan.purge && plan.action == Action::uninstall && !context.json_output) {
        try {
            const auto record = context.root/L".coop"/L"packages"/(wide(plan.package.name)+L".json");
            const auto managed = read_json(record);
            const auto scope = purge_scope(context,plan.package,plan.local.directory,
                managed.value("persistence",Json::array()));
            std::cout << "Purge scope (declared persistent data only):\n";
            for (const auto& entry : scope) std::cout << "  " << entry.at("store").get<std::string>() << '\n';
        } catch (const std::exception&) {
            // The execution blocker reports the same verification failure without deleting data.
        }
    }
    const auto result = execute_plan_result(context,plan);
    if (plan.action == Action::adopt) {
        std::cout << result.dump(2) << '\n';
        return 0;
    }
    const bool partial = result.value("status",std::string{}) == "partial";
    if (context.json_output) {
        std::cout << result.dump(2) << '\n';
        return partial ? 1 : 0;
    }
    if (result.value("status",std::string{}) == "up-to-date") {
        std::cout << plan.package.name << ": up-to-date\n";
        return 0;
    }
    if (partial) {
        std::cout << plan.package.name << ": partial\n";
        std::cerr << "coop: " << result.value("reason",std::string("Operation did not fully complete")) << '\n';
        for (const auto& entry : result.value("purge",Json::object()).value("failed",Json::array()))
            std::cerr << "coop: " << entry.value("store",std::string{}) << ": " << entry.value("reason",std::string{}) << '\n';
        return 1;
    }
    std::cout << plan.package.name << ": success\n";
    if (plan.purge) {
        for (const auto& entry : result.value("purge",Json::object()).value("deleted",Json::array()))
            std::cout << "Deleted persisted data: " << entry.get<std::string>() << '\n';
        for (const auto& entry : result.value("purge",Json::object()).value("already_absent",Json::array()))
            std::cout << "Persisted data already absent: " << entry.get<std::string>() << '\n';
    } else {
        const Json persistence = result.contains("persistence") ? result.at("persistence") : Json::array();
        if (persistence.is_array() && !persistence.empty())
            std::cout << "Persistent data retained; old program versions and stored data are reported separately\n";
    }
    return 0;
}
Json execute_plan_result(const Context& context, const Plan& plan) {
    const auto blocker = execution_blocker(context,plan);
    if (!blocker.empty()) throw std::runtime_error(blocker);
    const auto& package = plan.package;
    const bool updating = plan.action == Action::update;
    const bool resetting = plan.action == Action::reset;
    const auto& installed = (updating || resetting) ? plan.previous.value() : package;
    const auto state = context.root/L".coop";
    const auto record_path = state/L"packages"/(wide(package.name)+L".json");
    const auto app = context.root/L"apps"/wide(package.name);
    const auto version = app/wide(package.version);
    const auto shims = context.root/L"shims";
    ordinary_parents(context.root,state);
    ordinary_parents(context.root,version);
    ordinary_parents(context.root,shims);
    ordinary_parents(context.root,record_path);
    RootLock lock(context.root);
    recheck_plan(plan);
    if (fs::exists(state/L"transactions")) for (const auto& entry : fs::directory_iterator(state/L"transactions")) {
        if (!entry.is_directory()) continue;
        const auto journal_path = entry.path()/L"journal.json";
        if (fs::exists(journal_path) && read_json(journal_path).value("state",std::string{}) == "pending") {
            if (plan.action == Action::adopt && recover_adoption(context,plan,journal_path)) continue;
            throw std::runtime_error("Pending transaction requires recovery: "+path_text(journal_path));
        }
    }
    if (plan.action == Action::adopt) return commit_adoption_result(context,plan);
    Json managed = Json::object();
    Json persistence = Json::array();
    Json version_history = Json::array();
    Json purge_entries = Json::array();
    std::vector<FilePrecondition> owned_inputs;
    const bool has_managed_record = fs::exists(record_path);
    if (plan.action == Action::install) {
        if (plan.local.exists || fs::exists(version)) throw std::runtime_error("Package already exists; use update");
    } else {
        // Shared Scoop state is the authority. A Coop record is optional evidence: when it is
        // missing or stale, the current installation records and actual files are re-read instead
        // of refusing management or demanding an adoption step.
        if (has_managed_record) managed = read_json(record_path);
        if (!same_identity(fs::path(wide(managed.value("directory",path_text(plan.local.directory)))),plan.local.directory) ||
            managed.value("manifest_sha256",std::string{}) != installed.manifest_sha256) {
            managed["directory"] = path_text(plan.local.directory);
            managed["manifest_sha256"] = installed.manifest_sha256;
            managed["version"] = installed.version;
            managed["architecture"] = installed.architecture;
            managed["bucket"] = installed.bucket;
        }
        if (has_managed_record) verify_installed_files(managed,plan.local.directory,installed);
        else verify_shared_artifacts(installed,plan.local.directory);
        persistence = verify_persistence(context,installed,plan.local.directory);
        if (plan.purge) purge_entries = purge_scope(context,installed,plan.local.directory,
            managed.value("persistence",Json::array()));
        version_history = managed.value("versions",Json::array());
        if (!version_history.is_array()) version_history = Json::array();
        if (version_history.empty()) version_history = scan_version_evidence(app);
        if (plan.action == Action::update || resetting) {
            const bool recorded = std::any_of(version_history.begin(),version_history.end(),[&](const Json& entry) {
                return entry.is_object() && equal_name(entry.value("version",std::string{}),installed.version);
            });
            if (!recorded) {
                const auto install_record = installed_record(plan.local.directory,L"install");
                version_history.push_back({{"version",installed.version},
                    {"directory",path_text(operating_path(fs::canonical(plan.local.directory)))},
                    {"manifest_sha256",installed.manifest_sha256},
                    {"install_record_sha256",fs::is_regular_file(install_record) ? sha256_file(install_record) : std::string{}},
                    {"tree_stamp",version_tree_stamp(plan.local.directory)},
                    {"provenance","previous-current"}});
            }
        }
        if (has_managed_record) owned_inputs.push_back({record_path,sha256_file(record_path)});
        for (const auto& command : installed.commands) {
            const auto target = plan.local.directory/command.target;
            owned_inputs.push_back({target,sha256_file(target)});
        }
    }
    std::vector<InstalledEntry> installed_entries;
    const auto module_hash = coop_launcher_hash();
    for (const auto& command : installed.commands) {
        const auto expected_arguments = expand_exposure_arguments(context,installed.name,
            context.root/L"apps"/wide(installed.name)/L"current",command.arguments);
        const auto exe = shims/(wide(command.name)+L".exe");
        const auto coop_metadata = shims/(wide(command.name)+L".coop-shim.json");
        const auto scoop_metadata = shims/(wide(command.name)+L".shim");
        if (plan.action == Action::install) {
            if (fs::exists(exe) || fs::exists(coop_metadata) || fs::exists(scoop_metadata))
                throw std::runtime_error("Command entry conflicts with an existing file");
            continue;
        }
        if (!fs::exists(exe)) {
            if (fs::exists(coop_metadata) || fs::exists(scoop_metadata)) throw std::runtime_error("Managed command entry is missing");
            // Scoop's script-host entries are .cmd/.ps1/sh wrappers without an .exe. They are
            // removed through plan.scoop_entry_wrappers after the content check above.
            if (!scoop_entry_wrappers(context,installed.name,{command.name}).empty()) continue;
            throw std::runtime_error("Managed command entry is missing");
        }
        if (fs::exists(coop_metadata) && fs::exists(scoop_metadata))
            throw std::runtime_error("Command entry has conflicting Coop and Scoop metadata");
        InstalledEntry entry{command.name,{},exe,{},sha256_file(exe),{}};
        if (fs::exists(coop_metadata)) {
            entry.format = "coop";
            entry.metadata = coop_metadata;
            entry.metadata_hash = sha256_file(coop_metadata);
            const auto metadata = read_json(coop_metadata);
            if (!equal_name(metadata.value("package",std::string{}),installed.name) ||
                !same_identity(fs::path(wide(metadata.value("target",std::string{}))),plan.local.directory/command.target) ||
                metadata.value("arguments",std::string{}) != expected_arguments ||
                metadata.value("launcher",std::string{}) != command_launcher_name(command.target))
                throw std::runtime_error("Managed command entry ownership changed");
            if (managed.contains("commands") && managed.at("commands").is_array()) {
                const auto& entries = managed.at("commands");
                const auto found = std::find_if(entries.begin(),entries.end(),[&](const Json& item) {
                    return item.is_object() && equal_name(item.value("name",std::string{}),command.name);
                });
                if (found == entries.end()) throw std::runtime_error("Managed command record is missing");
                if (entry.metadata_hash != found->at("metadata_sha256").get<std::string>())
                    throw std::runtime_error("Managed command metadata changed");
                if (entry.executable_hash != found->at("launcher_sha256").get<std::string>())
                    throw std::runtime_error("Managed command launcher changed");
            }
        } else if (fs::exists(scoop_metadata)) {
            entry.format = "scoop";
            entry.metadata = scoop_metadata;
            entry.metadata_hash = sha256_file(scoop_metadata);
            const auto metadata = read_shim_metadata(scoop_metadata);
            if (!same_identity(fs::path(wide(metadata.target)),plan.local.directory/command.target) ||
                (!expected_arguments.empty() && metadata.arguments != expected_arguments))
                throw std::runtime_error("Scoop command entry points to a different package or arguments");
            // Scoop may legitimately replace its shim executable (for example after scoop reset).
            // Accept the launcher only when it is Scoop's known shim, Coop's own launcher, or the
            // exact executable recorded by Coop; a foreign replacement is refused.
            bool known_executable = looks_like_scoop_shim(entry.executable) || entry.executable_hash == module_hash ||
                shared_scoop_launcher(context,command.name,entry.executable_hash);
            if (managed.contains("legacy_shims") && managed.at("legacy_shims").is_object() &&
                managed.at("legacy_shims").contains(command.name))
                known_executable = known_executable || entry.executable_hash ==
                    managed.at("legacy_shims").at(command.name).value("executable_sha256",std::string{});
            if (!known_executable) throw std::runtime_error("Shared Scoop command launcher changed");
        } else throw std::runtime_error("Managed command entry metadata is missing");
        owned_inputs.push_back({entry.executable,entry.executable_hash});
        owned_inputs.push_back({entry.metadata,entry.metadata_hash});
        installed_entries.push_back(std::move(entry));
    }
    std::vector<std::string> absent_shortcuts;
    for (const auto& shortcut : installed.shortcuts) {
        const auto link = shortcut_link_path(context,shortcut.name);
        if (plan.action == Action::install) {
            if (fs::exists(link)) throw std::runtime_error("Shortcut conflicts with an existing file: "+path_text(link));
            continue;
        }
        if (!verify_shortcut_ownership(context,installed,managed,shortcut,link,plan.local.directory)) {
            absent_shortcuts.push_back(shortcut.name);
            continue;
        }
        owned_inputs.push_back({link,sha256_file(link)});
    }
    if (updating) {
        if (package.version == installed.version && package.manifest_sha256 == installed.manifest_sha256) {
            return Json{{"package",package.name},{"version",package.version},{"status","up-to-date"}};
        }
        if (fs::exists(version)) throw std::runtime_error("Target version already exists; it will not be overwritten");
        for (const auto& command : package.commands) {
            if (std::any_of(installed.commands.begin(),installed.commands.end(),[&](const CommandExposure& old) { return equal_name(old.name,command.name); })) continue;
            if (fs::exists(shims/(wide(command.name)+L".exe")) || fs::exists(shims/(wide(command.name)+L".coop-shim.json")) ||
                fs::exists(shims/(wide(command.name)+L".shim")))
                throw std::runtime_error("New command entry conflicts with an existing file");
        }
        for (const auto& shortcut : package.shortcuts) {
            if (std::any_of(installed.shortcuts.begin(),installed.shortcuts.end(),[&](const ShortcutExposure& old) { return equal_name(old.name,shortcut.name); })) continue;
            const auto link = shortcut_link_path(context,shortcut.name);
            if (fs::exists(link)) throw std::runtime_error("New shortcut conflicts with an existing file: "+path_text(link));
        }
    }
    const auto transaction = state/L"transactions"/(std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));
    ordinary_parents(context.root,transaction);
    fs::create_directories(transaction);
    // Hook sessions bind $manifest to a byte-identical copy inside the transaction. The live path
    // is not usable for every phase: post_uninstall runs after the version directory (and with it
    // the saved Manifest) was removed, exactly as in Scoop, where the Manifest object is loaded
    // before the uninstall hooks and stays in memory. Scoop loads the installed manifest before
    // running any hook, so every Manifest a hook can observe is staged here, before the operation
    // loop removes current or the version directory. Staging also records which bytes the scripts
    // saw.
    const auto scripts_directory = transaction/L"scripts";
    fs::create_directories(scripts_directory);
    std::map<std::wstring,fs::path> staged_manifests;
    const auto staged_manifest = [&](const Package& target) -> fs::path {
        const auto key = target.manifest_path.wstring();
        if (const auto found = staged_manifests.find(key); found != staged_manifests.end()) return found->second;
        if (target.manifest_path.empty() || !fs::is_regular_file(target.manifest_path)) {
            if (target.scripts.empty()) return {};
            throw std::runtime_error("Lifecycle hooks require the package Manifest, but it is missing: "+
                path_text(target.manifest_path));
        }
        const auto destination = scripts_directory/(wide(target.name)+L"-"+wide(target.version)+L".manifest.json");
        fs::copy_file(target.manifest_path,destination,fs::copy_options::overwrite_existing);
        staged_manifests.emplace(key,destination);
        return destination;
    };
    // `installed` aliases `package` for install and uninstall; updates carry both records.
    if (!installed.scripts.empty() || installed.installer || installed.uninstaller) staged_manifest(installed);
    if (!package.scripts.empty() || package.installer || package.uninstaller) staged_manifest(package);
    Json journal = {{"state","pending"},{"package",package.name},{"action",updating ? "update" : resetting ? "reset" : plan.action == Action::install ? "install" : "uninstall"},
        {"created",Json::array()},{"moves",Json::array()},{"scripts",Json::array()},{"installers",Json::array()},
        {"shortcuts_already_absent",absent_shortcuts}};
    // A shared Scoop installation has no Coop ownership record. The installed Manifest still
    // declares the values this package previously wrote, so use those declarations as attribution
    // evidence before deciding whether a current value is package-owned or a later user edit.
    Json user_environment_prior = managed.value("user_environment",Json(nullptr));
    std::string user_environment_source = user_environment_prior.is_null() ? "none" : "coop-record";
    if (user_environment_prior.is_null() && (updating || resetting || plan.action == Action::uninstall) &&
        (!installed.environment.empty() || !installed.path_entries.empty())) {
        // Coop publishes environment and PATH declarations against the stable current path, so
        // previous declarations must be expanded the same way rather than against the concrete
        // apps/<package>/<version> target of the junction.
        auto previous_environment = expanded_environment(context,installed,app/L"current");
        auto previous_path_entries = expanded_path_entries(context,installed,app/L"current");
        journal["environment_previous_declarations"] = {{"environment",previous_environment},
            {"path_entries",previous_path_entries}};
        user_environment_prior = ownership_from_declarations(previous_environment,previous_path_entries);
        user_environment_source = "installed-declaration";
    }
    journal["environment_ownership_source"] = user_environment_source;
    const auto shortcut_was_absent = [&](const std::string& name) {
        return std::any_of(absent_shortcuts.begin(),absent_shortcuts.end(),[&](const std::string& item) { return equal_name(item,name); });
    };
    const auto save = [&]() { write_json(transaction/L"journal.json",journal); };
    std::vector<fs::path> owned;
    std::vector<std::pair<fs::path,fs::path>> moved;
    const auto create = [&](const fs::path& path, const auto& operation) {
        journal["created"].push_back({{"path",path_text(path)},{"owned",false}}); save();
        try { operation(); }
        catch (const std::exception& error) {
            journal["created"].back()["error"] = error.what();
            try { save(); } catch (...) { /* Preserve the original failure. */ }
            throw;
        }
        owned.push_back(path);
        journal["created"].back()["owned"] = true;
        // Creation evidence lets recovery distinguish the object Coop created from a later
        // replacement or edit by the user or another client.
        journal["created"].back()["evidence"] = ownership_evidence(path);
        save();
    };
    const auto publish_json = [&](const fs::path& destination, const Json& value) {
        const auto temporary = transaction/(L"json-"+std::to_wstring(journal["created"].size())+L".json");
        write_json(temporary,value);
        create(destination,[&]() { publish_new(temporary,destination); });
    };
    const auto move = [&](const fs::path& from, const fs::path& to) {
        journal["moves"].push_back({{"from",path_text(from)},{"to",path_text(to)},{"moved",false}}); save();
        try { publish_new(from,to); }
        catch (const std::exception& error) {
            journal["moves"].back()["error"] = error.what();
            try { save(); } catch (...) { /* Preserve the original failure. */ }
            throw;
        }
        moved.emplace_back(from,to);
        journal["moves"].back()["moved"] = true; save();
    };
    Json script_runs = Json::array();
    const auto run_scripts = [&](const Package& hooks, ScriptPhase phase, const fs::path& directory,
                                 const fs::path& original_directory, const char* command, bool previous,
                                 std::size_t only_index = static_cast<std::size_t>(-1)) {
        for (std::size_t index = 0; index < hooks.scripts.size(); ++index) {
            if (hooks.scripts[index].phase != phase) continue;
            if (only_index != static_cast<std::size_t>(-1) && index != only_index) continue;
            journal["scripts"].push_back({{"phase",script_phase_name(phase)},{"index",index},{"package",hooks.name},
                {"previous_package",previous},{"directory",path_text(directory)},{"command",command},{"status","running"},
                {"external_side_effects","unknown; effects outside the managed package and persist roots are not rolled back, and a failed hook is not re-run automatically"}});
            save();
            ScriptRun run;
            try { run = run_package_script(context,hooks,index,directory,original_directory,
                context.root/L"persist"/wide(hooks.name),transaction,command,plan.purge,staged_manifest(hooks)); }
            catch (const std::exception& error) {
                journal["scripts"].back()["status"] = "failed";
                journal["scripts"].back()["error"] = error.what();
                try { save(); } catch (...) { /* Preserve the original failure. */ }
                throw;
            }
            auto& record = journal["scripts"].back();
            record["status"] = run.exit_code == 0 ? "succeeded" : "failed";
            record["exit_code"] = run.exit_code;
            record["interpreter"] = path_text(run.interpreter);
            record["hook"] = path_text(run.hook_path);
            record["host"] = path_text(run.host_path);
            record["manifest"] = path_text(run.manifest_path);
            record["scoop_library"] = path_text(run.library);
            record["scoop_library_version"] = script_host().library_version;
            record["context"] = {{"app",hooks.name},{"bucket",hooks.bucket},{"version",hooks.version},
                {"architecture",hooks.architecture},
                {"fname",hooks.artifacts.empty() ? std::string{} : hooks.artifacts.front().filename},
                {"dir",path_text(directory)},{"original_dir",path_text(original_directory)},
                {"persist_dir",path_text(context.root/L"persist"/wide(hooks.name))},
                {"bucketsdir",path_text(context.root/L"buckets")},{"scoopdir",path_text(context.root)},
                {"global",false},{"purge",plan.action == Action::uninstall && plan.purge}};
            record["stdout_log"] = path_text(run.stdout_path);
            record["stderr_log"] = path_text(run.stderr_path);
            record["stdout_bytes"] = run.stdout_bytes;
            record["stderr_bytes"] = run.stderr_bytes;
            record["stdout_tail"] = script_json_text(run.stdout_tail);
            record["stderr_tail"] = script_json_text(run.stderr_tail);
            save();
            script_runs.push_back(record);
            test_fault_point(context,std::string("after-script:")+script_phase_name(phase));
            if (run.exit_code != 0)
                throw std::runtime_error(std::string(script_phase_name(phase))+" hook failed with exit code "+
                    std::to_string(run.exit_code)+"; output was captured in "+path_text(run.stdout_path)+
                    " and "+path_text(run.stderr_path));
        }
    };
    // Installer and uninstaller programs are executed from the IR declaration the plan carries, in
    // the order the same IR sequence places them. The upstream Invoke-Installer helper owns the
    // declared program's checks, argument substitution, exit code and keep=false removal, so this
    // backend only binds the directory/stage context and records the evidence.
    Json installer_runs = Json::array();
    const auto run_installer = [&](const Package& target, const ir::InstallerProgram& program,
                                   bool uninstall, const fs::path& directory, const char* command,
                                   bool previous) {
        const auto phase = std::string(uninstall ? "uninstaller" : "installer");
        const auto declared_path = directory/wide(program.file);
        journal["installers"].push_back({{"phase",phase},{"package",target.name},{"previous_package",previous},
            {"directory",path_text(directory)},{"command",command},
            {"declared_file",program.file},{"declared_program_path",path_text(declared_path)},
            {"declared_arguments",program.arguments},{"keep",program.keep},{"status","running"},
            {"external_side_effects","external program declared by the Manifest; effects outside the managed package and persist roots cannot be predicted or rolled back, and the program is never re-run automatically"}});
        save();
        InstallerRun run;
        try { run = run_installer_program(context,target,uninstall,0,directory,directory,
            context.root/L"persist"/wide(target.name),transaction,command,plan.purge,staged_manifest(target)); }
        catch (const std::exception& error) {
            journal["installers"].back()["status"] = "failed";
            journal["installers"].back()["error"] = error.what();
            try { save(); } catch (...) { /* Preserve the original failure. */ }
            throw;
        }
        auto& record = journal["installers"].back();
        record["status"] = run.exit_code == 0 ? "succeeded" : "failed";
        record["exit_code"] = run.exit_code;
        record["interpreter"] = path_text(run.interpreter);
        record["host"] = path_text(run.host_path);
        record["manifest"] = path_text(run.manifest_path);
        record["scoop_library"] = path_text(run.library);
        record["scoop_library_version"] = script_host().library_version;
        record["program_present_after_run"] = fs::is_regular_file(declared_path);
        record["context"] = {{"app",target.name},{"bucket",target.bucket},{"version",target.version},
            {"architecture",target.architecture},{"dir",path_text(directory)},
            {"original_dir",path_text(directory)},
            {"persist_dir",path_text(context.root/L"persist"/wide(target.name))},
            {"scoopdir",path_text(context.root)},{"bucketsdir",path_text(context.root/L"buckets")},
            {"global",false}};
        record["stdout_log"] = path_text(run.stdout_path);
        record["stderr_log"] = path_text(run.stderr_path);
        record["stdout_bytes"] = run.stdout_bytes;
        record["stderr_bytes"] = run.stderr_bytes;
        record["stdout_tail"] = script_json_text(run.stdout_tail);
        record["stderr_tail"] = script_json_text(run.stderr_tail);
        save();
        installer_runs.push_back(record);
        test_fault_point(context,"after-installer");
        if (run.exit_code != 0)
            throw std::runtime_error(phase+" program failed with exit code "+std::to_string(run.exit_code)+
                "; output was captured in "+path_text(run.stdout_path)+" and "+path_text(run.stderr_path));
    };
    // Preserve the declared source of every artifact in the transaction journal, including a
    // fragment rename and the declared digest algorithm, so preview, execution and recovery
    // evidence describe the same inputs.
    journal["artifacts"] = Json::array();
    for (std::size_t index = 0; index < package.artifacts.size(); ++index) {
        const auto& artifact = package.artifacts[index];
        journal["artifacts"].push_back({{"index",index},{"url",artifact.url},{"filename",artifact.filename},
            {"renamed",artifact.renamed},{"algorithm",ir::digest_algorithm_name(artifact.algorithm)},
            {"digest",artifact.digest}});
    }
    journal["downloads"] = Json::array();
    save();
    Json user_environment = Json(nullptr);
    Json environment_undo = Json::array();
    try {
        const auto stage = transaction/L"payload";
        const auto downloads = transaction/L"downloads";
        std::vector<fs::path> downloaded_files(package.artifacts.size());
        bool stage_ready = false;
        bool version_published = false;
        bool preparation_checked = false;
        Json command_targets = Json::array();
        Json command_records = Json::array();
        Json legacy_shims = Json::object();
        Json shortcut_records = Json::array();
        Json environment = Json::array();
        Json path_entries = Json::array();
        const auto ensure_preparation = [&]() {
            if (preparation_checked) return;
            journal["preparation_steps"] = journal.value("observed_steps",Json::array());
            Json inputs = Json::array();
            for (const auto& input : owned_inputs)
                inputs.push_back({{"path",path_text(input.path)},{"expected",input.sha256},{"actual",sha256_file(input.path)}});
            Json plan_inputs = Json::array();
            for (const auto& input : plan.preconditions)
                plan_inputs.push_back({{"path",path_text(input.path)},{"expected",input.sha256},{"actual",sha256_file(input.path)}});
            journal["preparation_inputs"] = std::move(inputs);
            journal["plan_preconditions"] = std::move(plan_inputs); save();
            recheck_plan(plan);
            for (const auto& input : owned_inputs)
                if (sha256_file(input.path) != input.sha256)
                    throw std::runtime_error("Managed input changed during preparation; regenerate the plan");
            preparation_checked = true;
        };
        const auto ensure_stage = [&]() {
            if (resetting)
                throw std::runtime_error("A reset reuses the existing version directory and never stages a download");
            if (stage_ready) return;
            fs::create_directories(stage);
            fs::create_directories(downloads);
            fs::copy_file(package.manifest_path,stage/L"scoop-manifest.json",fs::copy_options::overwrite_existing);
            write_json(stage/L"scoop-install.json",{{"architecture",package.architecture},{"bucket",package.bucket}});
            stage_ready = true;
        };
        const auto ensure_version = [&]() {
            if (resetting) {
                if (!fs::is_directory(version))
                    throw std::runtime_error("Local version directory disappeared before the reset could publish it");
                version_published = true;
                return;
            }
            if (version_published) return;
            ensure_stage();
            fs::create_directories(app);
            create(version,[&]() { publish_new(stage,version); });
            version_published = true;
            test_fault_point(context,"after-version-publish");
        };
        std::size_t text_sequence = 0;
        const auto publish_text = [&](const fs::path& destination, const std::string& text) {
            const auto temporary = transaction/(L"text-"+std::to_wstring(text_sequence++));
            std::ofstream output(temporary,std::ios::binary);
            if (!output) throw std::runtime_error("Cannot create command metadata");
            output.write(text.data(),static_cast<std::streamsize>(text.size()));
            output.close();
            if (!output) throw std::runtime_error("Cannot write command metadata");
            create(destination,[&]() { publish_new(temporary,destination); });
        };
        // Every package action is driven by the IR sequence the plan carries. The switch below is
        // the execution backend for each operation, never a second source of package ordering.
        for (const auto& step : plan.ir_steps) {
            journal["stage"] = ir::operation_name(step.operation);
            if (!journal.contains("observed_steps")) journal["observed_steps"] = Json::array();
            journal["observed_steps"].push_back(ir::operation_name(step.operation));
            save();
            switch (step.operation) {
            case ir::Operation::download: {
                ensure_stage();
                if (step.index >= package.artifacts.size()) throw std::runtime_error("Plan download index is out of range");
                const auto& artifact = package.artifacts[step.index];
                const auto downloaded = downloads/(std::to_wstring(step.index)+L"-"+wide(artifact.filename));
                download_file(artifact.url,downloaded);
                downloaded_files[step.index] = downloaded;
                journal["downloads"].push_back({{"index",step.index},{"url",artifact.url},
                    {"filename",artifact.filename},{"renamed",artifact.renamed},
                    {"algorithm",ir::digest_algorithm_name(artifact.algorithm)},{"expected_digest",artifact.digest},
                    {"bytes",fs::file_size(downloaded)}});
                save();
                break;
            }
            case ir::Operation::verify: {
                if (step.index >= package.artifacts.size() || downloaded_files[step.index].empty())
                    throw std::runtime_error("Plan verification has no downloaded artifact");
                const auto& artifact = package.artifacts[step.index];
                // The IR declaration is authority for the algorithm; the projected record only
                // mirrors it for the legacy helpers. Never fall back to SHA256 for a SHA512 or
                // SHA1 declaration.
                auto algorithm = artifact.algorithm;
                auto expected = artifact.digest;
                if (package.definition && step.index < package.definition->downloads.size()) {
                    algorithm = package.definition->downloads[step.index].digest.algorithm;
                    expected = package.definition->downloads[step.index].digest.value;
                }
                const auto actual = digest_file(downloaded_files[step.index],algorithm);
                if (actual != expected)
                    throw std::runtime_error("Artifact "+std::string(ir::digest_algorithm_name(algorithm))+
                        " mismatch: "+artifact.filename+" (expected "+expected+", observed "+actual+")");
                journal["downloads"][std::size_t(step.index)]["observed_digest"] = actual;
                journal["downloads"][std::size_t(step.index)]["verified"] = true;
                save();
                if (artifact.archive == ArchiveKind::none) {
                    ensure_stage();
                    const auto target = stage/wide(artifact.filename);
                    if (!fs::copy_file(downloaded_files[step.index],target,fs::copy_options::none))
                        throw std::runtime_error("Artifact path collides with another package file");
                }
                break;
            }
            case ir::Operation::extract: {
                if (step.index >= package.artifacts.size() || downloaded_files[step.index].empty())
                    throw std::runtime_error("Plan extraction has no downloaded artifact");
                ensure_stage();
                const auto& artifact = package.artifacts[step.index];
                const auto raw = transaction/(L"extract-"+std::to_wstring(step.index));
                // Inno Setup extraction selects the declared Inno directory with innounp's own -c
                // switch, so the merge below starts at the extracted root instead of applying
                // extract_dir a second time.
                fs::path merge_directory = artifact.extract_directory;
                if (artifact.archive == ArchiveKind::msi) {
                    // MSI artifacts are extracted from a read-only view of the installer database and
                    // its embedded cabinets. The journal records that no msiexec process, machine
                    // cache entry, elevation or reboot is involved, next to what was actually read.
                    const auto record = extract_msi_image(downloaded_files[step.index],raw,
                        transaction/(L"msi-work-"+std::to_wstring(step.index)));
                    if (!journal.contains("msi_extractions")) journal["msi_extractions"] = Json::array();
                    auto entry = record;
                    entry["index"] = step.index;
                    entry["filename"] = artifact.filename;
                    journal["msi_extractions"].push_back(std::move(entry));
                    save();
                } else if (artifact.archive == ArchiveKind::inno_setup) {
                    const auto helper = inno_helper(context);
                    if (helper.path.empty()) throw std::runtime_error(helper.problem);
                    auto entry = extract_inno_archive(context,helper.path,downloaded_files[step.index],raw,
                        path_text(artifact.extract_directory),transaction,step.index);
                    entry["index"] = step.index;
                    entry["filename"] = artifact.filename;
                    if (!journal.contains("inno_extractions")) journal["inno_extractions"] = Json::array();
                    journal["inno_extractions"].push_back(std::move(entry));
                    save();
                    merge_directory.clear();
                } else if ((artifact.archive == ArchiveKind::zip || artifact.archive == ArchiveKind::seven_zip) &&
                           inspect_nsis_payload(downloaded_files[step.index]).detected) {
                    // The declared suffix only describes the transport. An NSIS installer is
                    // unpacked by the 7-Zip helper that Scoop's Expand-7zipArchive also uses; the
                    // helper is detected in the selected root and never downloaded.
                    const auto helper = nsis_helper(context);
                    if (helper.path.empty()) throw std::runtime_error(helper.problem);
                    auto entry = extract_nsis_archive(context,helper.path,downloaded_files[step.index],raw,
                        path_text(artifact.extract_directory),transaction,step.index);
                    entry["index"] = step.index;
                    entry["filename"] = artifact.filename;
                    if (!journal.contains("nsis_extractions")) journal["nsis_extractions"] = Json::array();
                    journal["nsis_extractions"].push_back(std::move(entry));
                    save();
                } else {
                    extract_archive(downloaded_files[step.index],raw);
                }
                const auto destination = artifact.extract_destination.empty() ? stage : stage/artifact.extract_destination;
                // Scoop 0.6.0 unpacks a compressed tar wrapper first and applies extract_dir while
                // extracting the inner tar; plain tar applies it directly. Merge the tree below the
                // selected directory for every archive kind, so nested layouts behave the same for
                // ZIP, 7z, tar, tar.gz, tar.xz, tar.bz2 and tar.zst.
                merge_archive_tree(raw,merge_directory,destination);
                erase_tree(raw);
                test_fault_point(context,"after-extract");
                break;
            }
            case ir::Operation::hook: {
                const auto& hooks = step.previous ? installed : package;
                if (!hooks.definition || step.index >= hooks.definition->hooks.size())
                    throw std::runtime_error("Plan hook index is out of range");
                const auto stage_kind = hooks.definition->hooks[step.index].stage;
                ScriptPhase phase = ScriptPhase::before_install;
                switch (stage_kind) {
                case ir::HookStage::pre_install: phase = ScriptPhase::before_install; break;
                case ir::HookStage::installer: phase = ScriptPhase::installer; break;
                case ir::HookStage::post_install: phase = ScriptPhase::after_install; break;
                case ir::HookStage::pre_uninstall: phase = ScriptPhase::before_uninstall; break;
                case ir::HookStage::uninstaller: phase = ScriptPhase::uninstaller; break;
                case ir::HookStage::post_uninstall: phase = ScriptPhase::after_uninstall; break;
                }
                if (step.previous || plan.action == Action::uninstall) {
                    ensure_preparation();
                    run_scripts(installed,phase,plan.local.directory,plan.local.directory,
                        step.previous && updating ? "update" : "uninstall",step.previous,step.index);
                } else {
                    ensure_preparation();
                    ensure_version();
                    const bool after = stage_kind == ir::HookStage::post_install;
                    const auto directory = after ? app/L"current" : version;
                    const auto original = after ? version : version;
                    run_scripts(package,phase,directory,original,updating ? "update" : "install",false,step.index);
                }
                break;
            }
            case ir::Operation::installer: {
                // The declared program is read from the package IR, never re-derived from the
                // Manifest here. The plan already placed this step after pre_install and before
                // the installer hook or, for a removal, after pre_uninstall and before the
                // uninstaller hook.
                const auto& target = step.previous ? installed : package;
                const bool uninstall = step.previous || plan.action == Action::uninstall;
                const ir::InstallerProgram* program = nullptr;
                if (target.definition) {
                    const auto& section = uninstall ? target.definition->uninstaller : target.definition->installer;
                    if (section) program = &*section;
                }
                if (!program)
                    throw std::runtime_error("Plan installer step has no declared "+
                        std::string(uninstall ? "uninstaller" : "installer")+" program in the package IR");
                ensure_preparation();
                const bool old_version = step.previous || plan.action == Action::uninstall;
                if (!old_version) ensure_version();
                const auto directory = old_version ? plan.local.directory : version;
                const auto command_name = old_version ? (step.previous && updating ? "update" : "uninstall") :
                    (updating ? "update" : "install");
                run_installer(target,*program,uninstall,directory,command_name,step.previous);
                break;
            }
            case ir::Operation::unlink_current:
                ensure_preparation();
                move(app/L"current",transaction/(step.previous ? L"old-current" : L"current"));
                break;
            case ir::Operation::remove_entries: {
                ensure_preparation();
                for (const auto& entry : installed_entries) {
                    move(entry.executable,transaction/(wide(entry.name)+(step.previous ? L".old.exe" : L".exe")));
                    move(entry.metadata,transaction/(wide(entry.name)+(step.previous ? L".old-metadata" : L".metadata")));
                }
                if (!journal.contains("scoop_entry_wrappers")) journal["scoop_entry_wrappers"] = Json::array();
                std::size_t wrapper_index = journal["scoop_entry_wrappers"].size();
                for (const auto& wrapper : plan.scoop_entry_wrappers) {
                    if (!scoop_wrapper_belongs_to_package(wrapper,installed.name))
                        throw std::runtime_error("Scoop command wrapper changed and no longer identifies this package");
                    journal["scoop_entry_wrappers"].push_back(path_text(wrapper));
                    move(wrapper,transaction/((step.previous ? L"old-scoop-wrapper-" : L"scoop-wrapper-")+std::to_wstring(wrapper_index++)+wrapper.extension().wstring()));
                }
                break;
            }
            case ir::Operation::remove_shortcuts: {
                ensure_preparation();
                for (std::size_t index = 0; index < installed.shortcuts.size(); ++index)
                    if (!shortcut_was_absent(installed.shortcuts[index].name))
                        move(shortcut_link_path(context,installed.shortcuts[index].name),
                            transaction/((step.previous ? L"old-shortcut-" : L"shortcut-")+std::to_wstring(index)+L".lnk"));
                break;
            }
            case ir::Operation::remove_environment: {
                // During an update or reset the old and new declarations are reconciled by the
                // single environment operation below, so the installed package keeps its user
                // values until the replacement is ready. An operation without any new declarations
                // and a normal uninstall revert immediately.
                bool environment_reverted_now = false;
                if ((updating || resetting) && !(package.environment.empty() && package.path_entries.empty())) {
                    journal["environment_reversion"] = "deferred; the replacement's environment operation reconciles old and new declarations";
                } else {
                    auto reverted = revert_user_environment(user_environment_prior);
                    environment_undo.push_back(reverted.value("undo",Json::object()));
                    journal["environment_reverted"] = std::move(reverted);
                    if (!journal.contains("environment_undo")) journal["environment_undo"] = Json::array();
                    journal["environment_undo"].push_back(environment_undo.back());
                    environment_reverted_now = true;
                }
                save();
                if (environment_reverted_now) test_fault_point(context,"after-environment");
                break;
            }
            case ir::Operation::unlink_persistence:
                // Persistence links live inside the version directory. Moving that directory at
                // remove-version removes the links without deleting the stored data.
                journal["persistence_unlinked"] = "Persistence links travel with the version directory; stored data is retained";
                save();
                break;
            case ir::Operation::remove_version:
                ensure_preparation();
                move(version,transaction/L"removed-version");
                break;
            case ir::Operation::publish_current: {
                ensure_preparation();
                ensure_version();
                ordinary_parents(context.root,app);
                fs::create_directories(app);
                make_junction(transaction/L"new-current",version);
                create(app/L"current",[&]() { publish_new(transaction/L"new-current",app/L"current"); });
                break;
            }
            case ir::Operation::entries: {
                ensure_version();
                // The plan places entries before the environment operation, but launcher metadata
                // already records the expanded values so command processes see the same effect.
                if (environment.empty() && path_entries.empty()) {
                    environment = expanded_environment(context,package,app/L"current");
                    path_entries = expanded_path_entries(context,package,app/L"current");
                }
                fs::create_directories(shims);
                std::array<wchar_t,32768> module{};
                const auto length = GetModuleFileNameW(nullptr,module.data(),static_cast<DWORD>(module.size()));
                if (!length || length >= module.size()) throw std::runtime_error("Cannot find native command launcher");
                const auto scoop_shims = prefer_scoop_shim(package);
                for (const auto& command : package.commands) {
                    const auto command_arguments = expand_exposure_arguments(context,package.name,app/L"current",command.arguments);
                    const auto kind = launcher_kind(command.target);
                    if (!kind) throw std::runtime_error("Command entry target type is not supported: "+path_text(command.target));
                    const auto target = version/command.target;
                    ordinary_parents(version,target);
                    if (!fs::is_regular_file(target)) throw std::runtime_error("Command entry target is missing after extraction: "+path_text(command.target));
                    command_targets.push_back({{"path",path_text(command.target)},{"sha256",sha256_file(target)}});
                    const auto exe = shims/(wide(command.name)+L".exe");
                    const bool gui = *kind == LauncherKind::direct && is_gui_executable(target);
                    const auto prepared = transaction/(wide(command.name)+L".prepared.exe");
                    fs::copy_file(fs::path(module.data()),prepared);
                    if (gui) mark_launcher_gui(prepared);
                    const auto launcher_hash = sha256_file(prepared);
                    if (*kind == LauncherKind::direct && scoop_shims) {
                        const auto metadata = shims/(wide(command.name)+L".shim");
                        std::string text = "path = \""+path_text(app/L"current"/command.target)+"\"\r\n";
                        if (!command_arguments.empty()) text += "args = "+command_arguments+"\r\n";
                        publish_text(metadata,text);
                        create(exe,[&]() { publish_new(prepared,exe); });
                        test_fault_point(context,"after-entry");
                        legacy_shims[command.name] = {{"executable_sha256",launcher_hash},{"metadata_sha256",sha256_file(metadata)}};
                        command_records.push_back({{"name",command.name},{"target",path_text(command.target)},
                            {"arguments",command_arguments},{"launcher","direct"},{"gui",gui},{"format","scoop"},
                            {"launcher_sha256",launcher_hash},{"metadata_sha256",sha256_file(metadata)}});
                    } else {
                        const auto metadata = shims/(wide(command.name)+L".coop-shim.json");
                        publish_json(metadata,{{"package",package.name},{"target",path_text(app/L"current"/command.target)},
                            {"launcher",launcher_text(*kind)},{"arguments",command_arguments},{"gui",gui},
                            {"environment",environment},{"path_entries",path_entries}});
                        create(exe,[&]() { publish_new(prepared,exe); });
                        test_fault_point(context,"after-entry");
                        command_records.push_back({{"name",command.name},{"target",path_text(command.target)},
                            {"arguments",command_arguments},{"launcher",launcher_text(*kind)},{"gui",gui},{"format","coop"},
                            {"launcher_sha256",launcher_hash},{"metadata_sha256",sha256_file(metadata)}});
                    }
                }
                break;
            }
            case ir::Operation::shortcuts: {
                for (const auto& shortcut : package.shortcuts) {
                    const auto link = shortcut_link_path(context,shortcut.name);
                    const auto target = app/L"current"/shortcut.target;
                    if (!fs::is_regular_file(target)) throw std::runtime_error("Shortcut target is missing after extraction: "+path_text(shortcut.target));
                    const auto icon = shortcut.icon.empty() ? fs::path{} : app/L"current"/shortcut.icon;
                    if (!icon.empty() && !fs::is_regular_file(icon)) throw std::runtime_error("Shortcut icon is missing after extraction: "+path_text(shortcut.icon));
                    const auto shortcut_arguments = expand_exposure_arguments(context,package.name,app/L"current",shortcut.arguments);
                    std::error_code error;
                    fs::create_directories(link.parent_path(),error);
                    if (error) throw std::runtime_error("Cannot create the shortcut directory: "+path_text(link.parent_path()));
                    const auto temporary = link.parent_path()/(link.filename().wstring()+L".coop-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(shortcut_records.size()));
                    write_shortcut(temporary,target,shortcut_arguments,icon);
                    try { create(link,[&]() { publish_new(temporary,link); }); }
                    catch (...) { DeleteFileW(temporary.c_str()); throw; }
                    test_fault_point(context,"after-shortcut");
                    shortcut_records.push_back({{"name",shortcut.name},{"path",path_text(link)},
                        {"target",path_text(target)},{"arguments",shortcut_arguments},{"sha256",sha256_file(link)}});
                }
                break;
            }
            case ir::Operation::environment: {
                environment = expanded_environment(context,package,app/L"current");
                path_entries = expanded_path_entries(context,package,app/L"current");
                auto applied = apply_user_environment(environment,path_entries,user_environment_prior);
                environment_undo.push_back(applied.value("undo",Json::object()));
                user_environment = applied.value("ownership",Json(nullptr));
                journal["environment_applied"] = std::move(applied);
                // Persist the undo record before the next write so an interrupted process can
                // restore exactly the values Coop changed.
                if (!journal.contains("environment_undo")) journal["environment_undo"] = Json::array();
                journal["environment_undo"].push_back(journal["environment_applied"].value("undo",Json::object()));
                save();
                test_fault_point(context,"after-environment");
                break;
            }
            case ir::Operation::persistence:
                ensure_version();
                if (resetting) {
                    // The retained version already owns the declared links. Resetting verifies them
                    // in place instead of re-running the migration used for a new version.
                    persistence = verify_persistence(context,package,version);
                    journal["persistence_reused"] = "Declared links of the retained version were verified; stored data was not moved or rolled back";
                    save();
                    break;
                }
                persistence = prepare_persistence(context,package,version);
                persistence = verify_persistence(context,package,version);
                test_fault_point(context,"after-persistence");
                break;
            case ir::Operation::commit_state: {
                Json kept_versions = Json::array();
                if (plan.action == Action::uninstall) {
                    for (const auto& entry : recorded_version_evidence(context,package.name))
                        if (!equal_name(entry.value("version",std::string{}),package.version)) kept_versions.push_back(entry);
                }
                if (has_managed_record && fs::exists(record_path))
                    move(record_path,transaction/((updating || resetting) ? L"old-managed-record.json" : L"managed-record.json"));
                if (plan.action == Action::uninstall) {
                    if (!kept_versions.empty()) {
                        const auto retained_path = state/L"retained"/(wide(package.name)+L".json");
                        ordinary_parents(context.root,retained_path);
                        fs::create_directories(retained_path.parent_path());
                        if (fs::exists(retained_path)) move(retained_path,transaction/L"retained-previous.json");
                        publish_json(retained_path,{{"package",package.name},
                            {"scope","Old versions kept after uninstall; persistent data is separate"},{"versions",kept_versions}});
                    }
                    // Scoop lists apps by the presence of apps/<name>; an empty directory would be
                    // reported as a failed installation even though nothing is published.
                    std::error_code error;
                    if (fs::is_directory(app,error) && fs::is_empty(app,error) && !error)
                        fs::remove(app,error);
                } else {
                    ordinary_parents(context.root,record_path.parent_path());
                    fs::create_directories(record_path.parent_path());
                    version_history.erase(std::remove_if(version_history.begin(),version_history.end(),[&](const Json& entry) {
                        return entry.is_object() && equal_name(entry.value("version",std::string{}),package.version);
                    }),version_history.end());
                    const auto installed_record_path = installed_record(version,L"install");
                    version_history.push_back({{"version",package.version},{"directory",path_text(operating_path(fs::canonical(version)))},
                        {"manifest_sha256",package.manifest_sha256},
                        {"install_record_sha256",fs::is_regular_file(installed_record_path) ? sha256_file(installed_record_path) : std::string{}},
                        {"tree_stamp",version_tree_stamp(version)},
                        {"provenance",resetting ? "coop-reset" : updating ? "coop-update" : "coop-install"}});
                    publish_json(record_path,{{"name",package.name},{"version",package.version},{"architecture",package.architecture},
                        {"bucket",package.bucket},{"directory",path_text(operating_path(fs::canonical(version)))},{"manifest_sha256",package.manifest_sha256},
                        {"status","ready"},{"shim_format",legacy_shims.empty() ? "coop" : "scoop"},
                        {"command_targets",command_targets},{"commands",command_records},{"legacy_shims",legacy_shims},
                        {"shortcuts",shortcut_records},{"environment",environment},{"path_entries",path_entries},
                        {"user_environment",user_environment},
                        {"dependencies",package.dependencies},{"persistence",persistence},{"versions",version_history},
                        {"origin",(updating || resetting) ? (has_managed_record ? managed.value("origin",std::string("coop")) : std::string("scoop")) : std::string("coop")},
                        {"adoption_backup",has_managed_record ? managed.value("adoption_backup",Json(nullptr)) : Json(nullptr)}});
                }
                test_fault_point(context,"before-commit");
                break;
            }
            case ir::Operation::adopt_state:
                throw std::runtime_error("Adoption is handled by the dedicated adopt path");
            }
        }
        journal["state"] = "committed"; save();
        if (updating || resetting || plan.action == Action::uninstall) {
            std::vector<fs::path> revoked;
            for (const auto& shortcut : installed.shortcuts)
                if (!shortcut_was_absent(shortcut.name)) revoked.push_back(shortcut_link_path(context,shortcut.name));
            try { prune_empty_shortcut_directories(context,revoked); }
            catch (...) { /* Empty shortcut folders are cosmetic; committed state remains valid. */ }
        }
    } catch (...) {
        if (!environment_undo.empty()) {
            Json environment_rollback = Json::array();
            for (auto entry = environment_undo.rbegin(); entry != environment_undo.rend(); ++entry) {
                try { environment_rollback.push_back(restore_user_environment(*entry)); }
                catch (const std::exception& error) {
                    environment_rollback.push_back({{"status","failed"},{"reason",error.what()}});
                }
            }
            journal["environment_rollback"] = std::move(environment_rollback);
            try { save(); } catch (...) { /* Preserve the original failure. */ }
        }
        try {
            for (auto entry = owned.rbegin(); entry != owned.rend(); ++entry) erase_tree(*entry);
            for (auto entry = moved.rbegin(); entry != moved.rend(); ++entry) {
                const auto& [from,to] = *entry;
                if (GetFileAttributesW(to.c_str()) == INVALID_FILE_ATTRIBUTES || GetFileAttributesW(from.c_str()) != INVALID_FILE_ATTRIBUTES)
                    throw std::runtime_error("Rollback conflict requires recovery");
                publish_new(to,from);
            }
            journal["state"] = "rolled-back"; save();
        } catch (...) { /* Original failure propagates; pending journal preserves recovery evidence. */ }
        throw;
    }
    if (plan.action == Action::uninstall) {
        erase_tree(transaction/L"current");
        erase_tree(transaction/L"removed-version");
    }
    try { erase_tree(transaction/L"downloads"); } catch (...) { /* Keep the committed journal if temporary downloads cannot be removed. */ }
    Json result = {{"package",package.name},{"version",package.version},{"status","success"},
        {"journal",path_text(transaction/L"journal.json")},{"persistence",persistence},
        {"shortcuts_already_absent",absent_shortcuts},{"scripts",script_runs},{"installers",installer_runs}};
    if (plan.action == Action::uninstall) {
        result["retained_versions"] = retained_versions(context,package.name,package.version);
        if (!plan.purge) {
            result["purge"] = {{"requested",false},{"status","not-requested"},{"scope",Json::array()}};
            result["data_retained"] = true;
        } else {
            Json purge = {{"requested",true},{"scope",purge_entries},{"deleted",Json::array()},
                {"already_absent",Json::array()},{"failed",Json::array()}};
            for (const auto& entry : purge_entries) {
                const auto store = entry.at("store").get<std::string>();
                try {
                    if (!verify_purge_target(context,package.name,entry)) purge["already_absent"].push_back(store);
                    else {
                        erase_tree(fs::path(wide(store)));
                        purge["deleted"].push_back(store);
                    }
                } catch (const std::exception& error) {
                    purge["failed"].push_back({{"store",store},{"reason",error.what()}});
                }
            }
            if (!purge.at("failed").empty()) {
                purge["status"] = "partial";
                purge["reason"] = "Declared persistent data was not completely deleted: "+
                    purge.at("failed").front().at("store").get<std::string>();
                result["status"] = "partial";
                result["reason"] = purge.at("reason");
                result["data_retained"] = true;
            } else {
                purge["status"] = purge_entries.empty() ? "nothing-to-delete" : "deleted";
                result["data_retained"] = false;
            }
            result["purge"] = std::move(purge);
        }
    } else if (updating || resetting) {
        result["retained_versions"] = retained_versions(context,package.name,package.version);
        result["data_rollback"] = "none";
        if (resetting) {
            result["reset_from"] = installed.version;
            result["local_version_reference"] = path_text(operating_path(fs::canonical(version)));
            result["lifecycle_hooks"] = "not-run";
        }
    } else {
        result["retained_versions"] = Json::array();
    }
    // A user-scope install never writes the system-level root. Report the read-only installation
    // it was planned beside so the result cannot be mistaken for a change to that copy.
    if (plan.global_installation) result["global_installation"] = {{"scope","global"},{"read_only",true},
        {"directory",path_text(*plan.global_installation)}};
    return result;
}
Json package_recovery_status(const Context& context, const fs::path& journal_path, bool execute) {
    Json result = {{"journal",path_text(journal_path)},{"mode","manual"},{"status","manual"},
        {"reason","Recovery evidence cannot be verified"},{"actions",Json::array()},
        {"diagnostics",Json::array()},{"conflicts",Json::array()}};
    // Conflicts are collected before any mutation. They name the observed external change so a
    // later Scoop or user operation is diagnosed instead of being rolled back blindly.
    Json diagnostics = Json::array();
    bool legacy_evidence = false;
    const auto fail = [&](const std::string& code, const std::string& detail, const std::string& path = {}) -> void {
        Json conflict = {{"code",code},{"detail",detail}};
        if (!path.empty()) conflict["path"] = path;
        diagnostics.push_back(conflict);
        result["conflicts"] = diagnostics;
        result["diagnostics"] = diagnostics;
        throw std::runtime_error(detail);
    };
    bool mutating = false;
    try {
        const auto journal = read_json(journal_path);
        if (!journal.is_object()) throw std::runtime_error("Transaction journal is not an object");
        const auto action = journal.value("action",std::string{});
        const auto package = journal.value("package",std::string{});
        result["action"] = action;
        result["package"] = package;
        if (journal.value("state",std::string{}) != "pending") {
            result["mode"] = "none";
            result["status"] = "not-pending";
            result["reason"] = "Transaction journal is already resolved";
            return result;
        }
        if (action != "install" && action != "update" && action != "uninstall")
            throw std::runtime_error("Transaction action is not a recoverable package operation: "+action);
        if (package.empty()) throw std::runtime_error("Transaction journal does not name a package");
        const auto created = journal.contains("created") && journal.at("created").is_array() ? journal.at("created") : Json::array();
        const auto moves = journal.contains("moves") && journal.at("moves").is_array() ? journal.at("moves") : Json::array();
        const auto scripts = journal.contains("scripts") && journal.at("scripts").is_array() ? journal.at("scripts") : Json::array();
        const auto installers = journal.contains("installers") && journal.at("installers").is_array() ? journal.at("installers") : Json::array();
        const bool scripts_started = !scripts.empty();
        // Installer/uninstaller programs are as unrollbackable as script text: recovery restores
        // Coop-owned paths, keeps the logs as evidence and never re-runs the program.
        const bool programs_started = !installers.empty();
        const bool external_effects_started = scripts_started || programs_started;
        result["scripts_started"] = scripts_started;
        result["installer_programs_started"] = programs_started;
        if (external_effects_started) result["external_side_effects"] =
            "unknown; recovered state does not roll back effects outside Coop's managed paths, and journaled scripts or installer programs are not re-run";
        Json actions = Json::array();
        std::vector<fs::path> removals;
        std::vector<std::pair<fs::path,fs::path>> restores;
        for (const auto& entry : created) {
            if (!entry.is_object() || !entry.contains("path") || !entry.at("path").is_string())
                fail("journal-unreadable","Transaction journal has an unreadable created-path record");
            const fs::path path(wide(entry.at("path").get<std::string>()));
            if (!recovery_path_allowed(context,path))
                fail("created-path-outside-root",
                    "Created path is outside Coop's managed locations or crosses a reparse point: "+path_text(path),path_text(path));
            const bool exists = GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
            const bool owned = entry.value("owned",false);
            if (exists && !owned)
                fail("created-path-ownership-unconfirmed",
                    "Creation ownership was not confirmed for "+path_text(path)+"; refusing to delete it",path_text(path));
            if (exists) {
                const auto evidence = entry.contains("evidence") ? entry.at("evidence") : Json::object();
                std::string detail;
                const auto code = ownership_conflict(evidence,path,detail);
                if (code == "ownership-evidence-not-recorded") legacy_evidence = true;
                else if (!code.empty()) fail(code,detail,path_text(path));
                removals.push_back(path);
                actions.push_back({{"kind","remove"},{"path",path_text(path)}});
            } else {
                actions.push_back({{"kind","already-absent"},{"path",path_text(path)}});
            }
        }
        for (const auto& entry : moves) {
            if (!entry.is_object() || !entry.contains("from") || !entry.at("from").is_string() ||
                !entry.contains("to") || !entry.at("to").is_string())
                throw std::runtime_error("Transaction journal has an unreadable move record");
            const fs::path from(wide(entry.at("from").get<std::string>()));
            const fs::path to(wide(entry.at("to").get<std::string>()));
            if (!recovery_path_allowed(context,from) || !recovery_path_allowed(context,to))
                fail("moved-path-outside-root",
                    "Moved path is outside Coop's managed locations or crosses a reparse point: "+path_text(from));
            bool from_exists = GetFileAttributesW(from.c_str()) != INVALID_FILE_ATTRIBUTES;
            const bool to_exists = GetFileAttributesW(to.c_str()) != INVALID_FILE_ATTRIBUTES;
            // A created destination at the original path (for example a newly published current
            // junction) is removed before moves are restored, exactly as in-process rollback does.
            for (const auto& removal : removals) if (same_path_text(removal,from)) { from_exists = false; break; }
            if (to_exists && !from_exists) {
                restores.emplace_back(from,to);
                actions.push_back({{"kind","restore"},{"from",path_text(from)},{"to",path_text(to)}});
            } else if (!to_exists && from_exists) {
                actions.push_back({{"kind","already-restored"},{"from",path_text(from)}});
            } else if (!to_exists && !from_exists) {
                fail("move-endpoints-missing",
                    "Both endpoints of a journaled move are missing; another client may have removed them: "+path_text(from),path_text(from));
            } else {
                fail("move-endpoint-conflict",
                    "Both endpoints of a journaled move exist; recovery would overwrite data: "+path_text(from),path_text(from));
            }
        }
        result["actions"] = std::move(actions);
        if (legacy_evidence) result["ownership_evidence"] = "not-recorded";
        else result["ownership_evidence"] = "created-object-identity-recorded";
        // User environment values are outside the path rollback. Recovery restores exactly the
        // values this transaction wrote, but a value the user changed in the meantime is kept and
        // reported instead of being overwritten.
        const auto environment_undo = journal.contains("environment_undo") && journal.at("environment_undo").is_array() ?
            journal.at("environment_undo") : Json::array();
        Json environment_preview = Json::array();
        bool environment_conflict = false;
        for (auto entry = environment_undo.rbegin(); entry != environment_undo.rend(); ++entry) {
            const auto preview = preview_user_environment_undo(*entry);
            environment_conflict = environment_conflict || (preview.contains("preserved") && !preview.at("preserved").empty());
            environment_preview.push_back(preview);
        }
        if (!environment_preview.empty()) result["environment_rollback_preview"] = environment_preview;
        if (environment_conflict) {
            diagnostics.push_back({{"code","environment-value-modified"},
                {"detail","A user environment value changed after this transaction wrote it; recovery keeps the newer value"}});
            // A preserved newer user value is a diagnosed conflict even though recovery succeeds
            // without overwriting it.
            result["conflicts"] = diagnostics;
        }
        result["diagnostics"] = diagnostics;
        result["mode"] = "automatic";
        result["status"] = execute ? "pending" : "recoverable";
        result["reason"] = restores.empty() && removals.empty() ?
            "No published state was changed; the interrupted preparation can be discarded" :
            "Journaled Coop-owned paths and moves can be reverted without guessing";
        if (!execute) return result;
        mutating = true;
        for (auto entry = removals.rbegin(); entry != removals.rend(); ++entry) erase_tree(*entry);
        for (auto entry = restores.rbegin(); entry != restores.rend(); ++entry) publish_new(entry->second,entry->first);
        Json environment_rollback = Json::array();
        if (!environment_undo.empty()) {
            for (auto entry = environment_undo.rbegin(); entry != environment_undo.rend(); ++entry)
                environment_rollback.push_back(restore_user_environment(*entry));
            result["environment_rollback"] = environment_rollback;
        }
        auto resolved = read_json(journal_path);
        resolved["state"] = "rolled-back";
        resolved["recovered"] = true;
        if (external_effects_started) resolved["recovery_external_side_effects"] =
            "unknown; journaled scripts and installer programs were not re-run and their effects outside Coop's managed paths were not rolled back";
        if (!environment_undo.empty()) resolved["recovery_environment"] = environment_rollback;
        if (!diagnostics.empty()) resolved["recovery_diagnostics"] = diagnostics;
        write_json(journal_path,resolved);
        if (external_effects_started) {
            // Script and installer-program logs are recovery evidence and must not be treated as
            // ordinary cache.
            result["transaction_evidence_retained"] = path_text(journal_path.parent_path());
        } else {
            try {
                for (const auto& entry : fs::directory_iterator(journal_path.parent_path()))
                    if (entry.path().filename() != L"journal.json") erase_tree(entry.path());
            } catch (const std::exception& error) {
                result["cleanup_warning"] = std::string("Recovered state is valid, but transaction staging could not be removed: ")+error.what();
            }
        }
        result["status"] = external_effects_started ? "recovered-with-unknown-script-effects" :
            environment_conflict ? "recovered-with-user-changes" : "recovered";
        result["reason"] = external_effects_started ?
            "Interrupted Coop state was reverted; script and installer-program side effects outside managed paths remain unknown" :
            environment_conflict ?
            "Interrupted Coop state was reverted; user environment values changed after the transaction were kept" :
            "Interrupted Coop state was reverted";
        return result;
    } catch (const std::exception& error) {
        result["mode"] = "manual";
        result["status"] = mutating ? "failed" : "manual";
        result["reason"] = error.what();
        if (!diagnostics.empty()) {
            result["conflicts"] = diagnostics;
            result["diagnostics"] = diagnostics;
        }
        return result;
    }
}
bool recovery_record_path_allowed(const Context& context, const fs::path& path) {
    return path_is_under(path,context.root/L".coop"/L"transactions") && recovery_path_allowed(context,path);
}
}
