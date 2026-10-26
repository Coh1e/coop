#pragma once
#include "app.hpp"
#include <optional>

// Package IR: the normalized contract between a package source adapter, the IR validator, the
// planner and every backend. It deliberately contains no Scoop JSON types, no Windows API handles
// and no execution policy, so a second source adapter or backend can reuse it.
namespace coop::ir {

// Every diagnostic names the layer that owns the constraint. Query and planning report all layers
// instead of hiding a package because one later stage cannot execute it.
enum class Layer { syntax, adapter, validation, environment, capability, verification };
const char* layer_name(Layer layer);

struct Diagnostic { Layer layer; std::string code; std::string message; };

// Digests keep the declared algorithm instead of assuming SHA256. The validator decides which
// algorithms the product can currently honor.
enum class DigestAlgorithm { missing, sha256, sha512, sha1, md5, other };
const char* digest_algorithm_name(DigestAlgorithm algorithm);
struct Digest {
    DigestAlgorithm algorithm = DigestAlgorithm::missing;
    std::string value;
    std::string spelling;
    bool declared = false;
};

enum class ArchiveFormat { file, zip, seven_zip, tar, msi };
const char* archive_format_name(ArchiveFormat format);

struct Download {
    std::string url;
    std::string filename;
    Digest digest;
    ArchiveFormat format = ArchiveFormat::file;
    std::string extract_directory;
    std::string extract_destination;
    bool renamed = false;
};

// Command entries are identified by their package-relative target and alias; the host kind is
// derived once by the exposure layer, so the IR does not duplicate launcher semantics.
struct Entry { std::string target; std::string alias; std::string arguments; std::string host; };
struct Shortcut { std::string target; std::string name; std::string arguments; std::string icon; };

struct PersistenceMapping { std::string source; std::string target; };

// Environment changes are user-scoped: a PATH or variable declared by a package must be visible in
// a new terminal. The IR records the intended user effect; the backend owns reverting it safely.
struct EnvironmentEntry { std::string variable; std::string value; bool path_entry = false; };

enum class HookStage { pre_install, installer, post_install, pre_uninstall, uninstaller, post_uninstall };
const char* hook_stage_name(HookStage stage);
struct Hook { HookStage stage; std::string text; std::string declared_by; };

struct InstallerProgram { std::string file; std::vector<std::string> arguments; bool keep = false; };
struct Dependency { std::string source; std::string name; std::string version; };

// Capability entries state what the IR requires from the product independently of any execution
// path, so preview and query can report gaps without each caller re-deriving them.
struct Capability { std::string id; bool supported; std::string detail; };

struct Package {
    std::string name;
    std::string bucket;
    std::string version;
    std::string architecture;
    std::string manifest_path;
    std::string manifest_digest;
    std::string source_url;

    std::vector<Download> downloads;
    std::vector<Entry> entries;
    std::vector<Shortcut> shortcuts;
    std::vector<PersistenceMapping> persistence;
    std::vector<EnvironmentEntry> environment;
    std::vector<Hook> hooks;
    std::optional<InstallerProgram> installer;
    std::optional<InstallerProgram> uninstaller;
    std::vector<Dependency> dependencies;
    std::vector<Capability> capabilities;
    std::vector<Diagnostic> diagnostics;

    // Adapter evidence: the source declared URL and hash as parallel arrays. The validator uses the
    // declared count to distinguish a missing hash from a malformed one.
    std::size_t declared_hash_count = 0;
};

// Installation facts come from the shared Scoop layout (apps/<name>/current plus its saved
// manifest and install records). Coop's own records are never consulted here, so a missing, stale
// or corrupt private record cannot hide or block an installed package.
struct InstalledFact {
    bool present = false;
    std::string name;
    std::string version;
    std::string bucket;
    std::string architecture;
    std::string scope = "user";
    std::string source;
    fs::path directory;
    std::vector<PersistenceMapping> persistence;
    std::vector<Diagnostic> diagnostics;
};

enum class Action { install, update, uninstall, adopt };
enum class Operation {
    download, verify, extract, hook, installer, publish_current, entries, shortcuts, environment,
    persistence, commit_state, remove_entries, remove_shortcuts, remove_environment,
    unlink_persistence, unlink_current, remove_version, adopt_state
};
const char* operation_name(Operation operation);

// A high-level operation and the effect it will have. The same sequence is what preview reports and
// what the execution backend consumes, so preview and execution cannot drift apart.
struct Step { Operation operation; std::size_t index = 0; bool previous = false; std::string effect; };
struct Precondition { fs::path path; std::string digest; std::string role; };

struct Plan {
    Action action = Action::install;
    Package package;
    std::optional<Package> previous;
    std::vector<Step> steps;
    std::vector<Precondition> preconditions;
    std::vector<Diagnostic> diagnostics;
    bool execution_available = false;
};

// Source adapter: Scoop manifest JSON -> normalized IR. It only normalizes meaning; it never
// downloads, extracts, runs scripts or writes state.
Package adapt_manifest(const fs::path& path, const std::string& name, const std::string& bucket,
                       const std::string& architecture);
// Source adapter: shared installation records -> facts. Also read-only.
std::vector<InstalledFact> read_installations(const fs::path& root, const std::string& scope);
// Validator: normalized IR contract, digest support, path/identity constraints and the capability
// requirements of the requested package. Consumes IR only; it does not re-read source fields.
void validate(Package& package);
// Planner: the single operation sequence for one package action, including the effects shown in a
// preview. The caller binds preconditions from current state before executing.
Plan plan(Action action, const Package& package, const Package* previous, bool retain_previous_version);
}
