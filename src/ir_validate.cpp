#include "ir.hpp"
#include <algorithm>
#include <cctype>
#include <set>

// The validator only reads normalized IR. It owns the IR contract, the currently honourable digest
// algorithms and the capability requirements a package implies; it never re-interprets source fields.
namespace coop::ir {
namespace {
bool hexadecimal(const std::string& value) {
    return std::all_of(value.begin(),value.end(),[](unsigned char character) { return std::isxdigit(character) != 0; });
}
std::string lower(std::string text) {
    for (auto& character : text) character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    return text;
}
void report(Package& package, Layer layer, const char* code, std::string message) {
    package.diagnostics.push_back({layer,code,std::move(message)});
}
std::size_t digest_length(DigestAlgorithm algorithm) {
    switch (algorithm) {
    case DigestAlgorithm::sha256: return 64;
    case DigestAlgorithm::sha512: return 128;
    case DigestAlgorithm::sha1: return 40;
    case DigestAlgorithm::md5: return 32;
    case DigestAlgorithm::missing:
    case DigestAlgorithm::other:
        break;
    }
    return 0;
}
bool supported_digest(const Digest& digest) {
    // Coop verifies the digest with the algorithm the Manifest declared. An unknown algorithm or a
    // mismatched value length stays an explicit IR gap instead of being read as SHA256.
    const auto length = digest_length(digest.algorithm);
    return length != 0 && digest.value.size() == length && hexadecimal(digest.value);
}
bool supported_url(const std::string& url) {
    return url.starts_with("https://") || url.starts_with("http://") || url.starts_with("file://");
}
void capability(Package& package, std::string id, bool supported, std::string detail) {
    const auto existing = std::find_if(package.capabilities.begin(),package.capabilities.end(),
        [&](const Capability& item) { return item.id == id; });
    if (existing != package.capabilities.end()) return;
    package.capabilities.push_back({std::move(id),supported,std::move(detail)});
}
}
void validate(Package& package) {
    if (package.name.empty()) report(package,Layer::validation,"missing-name","Package identity is missing a name");
    if (package.version.empty()) report(package,Layer::validation,"missing-version","Package identity is missing a version");
    if (package.version == "nightly")
        report(package,Layer::validation,"nightly-tracking","Nightly version tracking is not yet supported");
    if (package.downloads.empty())
        report(package,Layer::validation,"missing-artifact","No artifact for selected architecture");
    if (package.declared_hash_count != package.downloads.size())
        report(package,Layer::validation,"artifact-hash-count","Each artifact requires its own hash");
    for (const auto& download : package.downloads) {
        if (download.digest.declared && !supported_digest(download.digest)) {
            const auto expected = digest_length(download.digest.algorithm);
            report(package,Layer::validation,"unsupported-hash",expected ?
                "A valid "+std::string(digest_algorithm_name(download.digest.algorithm))+" digest is required for "+download.filename :
                "Unsupported declared digest algorithm for "+download.filename+"; native verification covers SHA256, SHA512, SHA1 and MD5");
        }
        if (!supported_url(download.url))
            report(package,Layer::validation,"unsupported-download","Artifact URL scheme is not supported");
        if (download.format == ArchiveFormat::msi)
            capability(package,"windows-installer",false,
                "MSI artifacts need Windows Installer; administrative extraction writes the machine cache under %WINDIR%\\Installer outside the selected root");
        else if (download.format != ArchiveFormat::file)
            capability(package,"archive-"+std::string(archive_format_name(download.format)),true,
                "Native libarchive extraction of "+std::string(archive_format_name(download.format))+" with declared extract_dir/extract_to layout");
    }
    if (!package.downloads.empty())
        capability(package,"native-download",true,"Native HTTPS/file download with declared digest verification");
    std::set<std::string> sources, targets;
    for (const auto& mapping : package.persistence) {
        if (mapping.source.empty() || mapping.target.empty()) {
            report(package,Layer::validation,"invalid-persist-mapping","Persist mapping must name a source and target");
            continue;
        }
        if (!sources.insert(lower(mapping.source)).second)
            report(package,Layer::validation,"duplicate-persist-source","Duplicate persist source: "+mapping.source);
        if (!targets.insert(lower(mapping.target)).second)
            report(package,Layer::validation,"duplicate-persist-target","Duplicate persist target: "+mapping.target);
    }
    for (const auto& dependency : package.dependencies) {
        if (dependency.name.empty())
            report(package,Layer::validation,"dependency-invalid","Dependency name is empty: "+dependency.source);
        if (!dependency.version.empty())
            report(package,Layer::validation,"dependency-version","Version-constrained dependencies are not supported");
    }
    if (package.installer || package.uninstaller) {
        capability(package,"installer-process",true,
            "Declared installer/uninstaller programs run through the same real PowerShell host and pinned Scoop compatibility library that run hook scripts, so the upstream Invoke-Installer owns the $dir containment and missing-file checks, the $dir/$global/$version argument substitution, .ps1 invocation, exit-code propagation and the keep=false removal; the program is external code whose effects outside the managed package and persist roots are not rolled back and is never re-run automatically");
    }
    if (!package.hooks.empty()) {
        capability(package,"lifecycle-hooks",true,
            "Declared lifecycle hooks run as trusted script text in the fixed Scoop order with a real PowerShell host that loads the pinned Scoop compatibility library and the Scoop context");
    }
    if (!package.entries.empty()) {
        capability(package,"command-entry",true,
            "Entry host and argument forwarding follow the target file type");
    }
    if (!package.environment.empty()) {
        std::set<std::string> names;
        bool path_entries = false;
        for (const auto& entry : package.environment)
            if (entry.path_entry) path_entries = true;
        for (const auto& entry : package.environment) {
            if (entry.variable.empty() || entry.variable.find('=') != std::string::npos) {
                report(package,Layer::validation,"environment-name","Environment variable name is invalid");
                continue;
            }
            // env_add_path may legitimately contribute several PATH entries; env_set PATH is one
            // value and cannot be combined with them without a defined precedence.
            if (entry.path_entry) continue;
            if (!names.insert(lower(entry.variable)).second)
                report(package,Layer::validation,"duplicate-environment","Duplicate environment variable: "+entry.variable);
            if (lower(entry.variable) == "path" && path_entries)
                report(package,Layer::validation,"environment-path-conflict","env_set PATH conflicts with env_add_path declarations");
        }
        capability(package,"user-environment",true,
            "Declared PATH and environment values are written to the current user's environment, recorded with their previous values, broadcast to new processes and reverted only while ownership still matches");
    }
    if (!package.shortcuts.empty())
        capability(package,"start-menu-shortcut",true,"Shortcuts are created under the Scoop Apps Start Menu folder with recorded identity");
}
}
