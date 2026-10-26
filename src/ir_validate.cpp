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
bool supported_digest(const Digest& digest) {
    // Only SHA256 verification is implemented natively today. Other declared algorithms stay visible
    // as an IR gap instead of being silently treated as SHA256.
    return digest.algorithm == DigestAlgorithm::sha256 && digest.value.size() == 64 && hexadecimal(digest.value);
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
        if (download.digest.declared && !supported_digest(download.digest))
            report(package,Layer::validation,"unsupported-hash","A valid SHA256 is required for "+download.filename);
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
    if (package.installer) {
        capability(package,"installer-process",false,
            "Installer programs declared by installer.file/args are refused until their external effects can be verified");
    }
    bool post_uninstall = false;
    for (const auto& hook : package.hooks) {
        if (hook.stage == HookStage::post_uninstall) post_uninstall = true;
    }
    if (!package.hooks.empty()) {
        capability(package,"lifecycle-hooks",!post_uninstall,
            post_uninstall ? "post_uninstall declarations are outside the supported lifecycle phases" :
            "Declared lifecycle hooks in the supported order with the real PowerShell host");
    }
    if (!package.entries.empty()) {
        capability(package,"command-entry",true,
            "Entry host and argument forwarding follow the target file type");
    }
    if (!package.environment.empty()) {
        capability(package,"user-environment",false,
            "Declared PATH and environment values are currently applied to package launch processes only; user-level persistence is not implemented yet");
    }
    if (!package.shortcuts.empty())
        capability(package,"start-menu-shortcut",true,"Shortcuts are created under the Scoop Apps Start Menu folder with recorded identity");
}
}
