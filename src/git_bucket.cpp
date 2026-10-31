#include "git_bucket.hpp"
#include <git2.h>
#include <git2/sys/errors.h>
#include <windows.h>
#include <algorithm>
#include <cctype>
#include <cwctype>
#include <fstream>
#include <memory>
#include <set>
#include <stdexcept>

namespace coop {
namespace {
void check(int result, const char* operation) {
    if (result < 0) {
        const auto* error = git_error_last();
        throw std::runtime_error(std::string(operation)+": "+(error && error->message ? error->message : "Git error"));
    }
}
template<class T> auto own(T* pointer, void (*release)(T*)) {
    return std::unique_ptr<T,void(*)(T*)>(pointer,release);
}
struct CaseInsensitiveLess {
    bool operator()(const std::wstring& left, const std::wstring& right) const {
        return CompareStringOrdinal(left.c_str(),-1,right.c_str(),-1,TRUE) == CSTR_LESS_THAN;
    }
};
void require_regular_directory(const fs::path& directory) {
    const DWORD attributes = GetFileAttributesW(directory.c_str());
    if (attributes != INVALID_FILE_ATTRIBUTES && (!(attributes & FILE_ATTRIBUTE_DIRECTORY) || (attributes & FILE_ATTRIBUTE_REPARSE_POINT)))
        throw std::runtime_error("Git bucket path is not an ordinary directory: "+path_text(directory));
}
bool local_source_path(const std::string& source) {
    if (source.starts_with("file://")) return true;
    const auto value = wide(source);
    return value.size() >= 3 && std::iswalpha(value[0]) && value[1] == L':' &&
        (value[2] == L'\\' || value[2] == L'/');
}
void require_supported_url(const std::string& url) {
    if (url.starts_with("https://")) {
        const auto slash = url.find('/',8);
        if (url.substr(8,slash == std::string::npos ? slash : slash-8).find('@') != std::string::npos)
            throw std::runtime_error("Embedded credentials are not supported");
        return;
    }
    if (url.starts_with("file://") || local_source_path(url)) return;
    throw std::runtime_error("Only public HTTPS Git and local bucket sources are supported");
}
// libgit2 must not inherit credential helpers, URL rewrites or filter executables from the
// user's Git configuration. The checkout-related core settings are different: a Scoop bucket is
// a working tree that Scoop also uses, so its line-ending policy must be preserved. Only these
// three well-known values are copied into the isolated configuration.
std::string read_text(const fs::path& path) {
    std::ifstream input(path,std::ios::binary);
    if (!input) throw std::runtime_error("Cannot read "+path_text(path));
    return std::string(std::istreambuf_iterator<char>(input),std::istreambuf_iterator<char>());
}
void safe_core_config(git_config* config, const char* key, std::string& value) {
    const char* text = nullptr;
    if (git_config_get_string(&text,config,key) < 0 || !text) { git_error_clear(); return; }
    const std::string candidate(text);
    if (candidate.empty()) return;
    if (std::any_of(candidate.begin(),candidate.end(),[](unsigned char c) {
        return !(std::isalnum(c) || c == '.' || c == '-' || c == '_');
    })) return;
    value = candidate;
}
void write_text_if_changed(const fs::path& path, const std::string& text) {
    try {
        if (fs::is_regular_file(path) && read_text(path) == text) return;
    } catch (const std::exception&) { /* Rewriting the private configuration is harmless. */ }
    std::ofstream output(path,std::ios::binary|std::ios::trunc);
    output.write(text.data(),static_cast<std::streamsize>(text.size()));
    output.close();
    if (!output) throw std::runtime_error("Cannot write isolated Git configuration");
}
void write_isolated_config(const fs::path& directory, const std::string& autocrlf,
                           const std::string& eol, const std::string& safecrlf) {
    std::string text = "[core]\n";
    if (!autocrlf.empty()) text += "\tautocrlf = "+autocrlf+"\n";
    if (!eol.empty()) text += "\teol = "+eol+"\n";
    if (!safecrlf.empty()) text += "\tsafecrlf = "+safecrlf+"\n";
    // libgit2 looks for .gitconfig at the global level, gitconfig at the system level and
    // config at XDG/ProgramData. Keeping all three in the same private directory isolates every
    // level while preserving only the checkout policy copied above.
    for (const auto* name : {".gitconfig","gitconfig","config"})
        write_text_if_changed(directory/wide(name),text);
}
class GitSession {
public:
    explicit GitSession(const fs::path& root) {
        check(git_libgit2_init(),"Initialize Git library");
        try {
            std::string autocrlf,eol,safecrlf;
            git_config* raw = nullptr;
            if (git_config_open_default(&raw) == 0 && raw) {
                const auto config = own(raw,git_config_free);
                safe_core_config(config.get(),"core.autocrlf",autocrlf);
                safe_core_config(config.get(),"core.eol",eol);
                safe_core_config(config.get(),"core.safecrlf",safecrlf);
            } else {
                git_error_clear();
            }
            const auto isolated = state_directory_for_root(root)/L"disabled-user-config";
            require_regular_directory(isolated);
            fs::create_directories(isolated);
            write_isolated_config(isolated,autocrlf,eol,safecrlf);
            for (const auto level : {GIT_CONFIG_LEVEL_SYSTEM,GIT_CONFIG_LEVEL_GLOBAL,GIT_CONFIG_LEVEL_XDG,GIT_CONFIG_LEVEL_PROGRAMDATA})
                check(git_libgit2_opts(GIT_OPT_SET_SEARCH_PATH,level,path_text(isolated).c_str()),"Isolate Git configuration");
        } catch (...) { git_libgit2_shutdown(); throw; }
    }
    ~GitSession() { git_libgit2_shutdown(); }
};
struct GitBuffer {
    git_buf value = GIT_BUF_INIT;
    ~GitBuffer() { git_buf_dispose(&value); }
};
using Repo = std::unique_ptr<git_repository,decltype(&git_repository_free)>;
using Commit = std::unique_ptr<git_commit,decltype(&git_commit_free)>;
std::string oid_text(const git_oid* oid) {
    char text[GIT_OID_HEXSZ+1]{};
    git_oid_tostr(text,sizeof(text),oid);
    return text;
}
struct Transfer { std::size_t bytes = 0; std::size_t base = 0; };
int transferred(const git_indexer_progress* progress, void* payload) {
    auto& transfer = *static_cast<Transfer*>(payload);
    transfer.bytes = transfer.base+progress->received_bytes;
    return 0;
}
int no_credentials(git_credential**, const char*, const char*, unsigned int, void*) {
    git_error_set_str(GIT_ERROR_NET,"Authenticated repositories are outside the first-release scope");
    return GIT_EAUTH;
}
git_fetch_options fetch_options(Transfer& transfer) {
    git_fetch_options options = GIT_FETCH_OPTIONS_INIT;
    // Full history is preserved because Scoop can look up historical manifests in this same
    // working repository. The fetch is still incremental.
    options.depth = 0;
    options.callbacks.transfer_progress = transferred;
    options.callbacks.credentials = no_credentials;
    options.callbacks.payload = &transfer;
    options.proxy_opts.type = GIT_PROXY_AUTO;
    options.proxy_opts.credentials = no_credentials;
    return options;
}
Repo open_shared_bucket(const fs::path& directory) {
    require_regular_directory(directory);
    git_repository* raw = nullptr;
    check(git_repository_open(&raw,path_text(directory).c_str()),"Open shared bucket repository");
    auto repository = Repo(raw,git_repository_free);
    if (git_repository_is_bare(repository.get())) throw std::runtime_error("Shared bucket repository must have a working tree");
    return repository;
}
git_reference* head_reference(git_repository* repository) {
    git_reference* raw = nullptr;
    check(git_repository_head(&raw,repository),"Read current bucket revision");
    auto head = own(raw,git_reference_free);
    if (!git_reference_is_branch(head.get())) throw std::runtime_error("Detached bucket requires an explicit fixed revision");
    return head.release();
}
Commit lookup_commit(git_repository* repository, const git_oid* oid) {
    git_commit* raw = nullptr;
    check(git_commit_lookup(&raw,repository,oid),"Read bucket commit");
    return Commit(raw,git_commit_free);
}
struct BucketSource {
    std::string local_branch;
    std::string remote;
    std::string branch;
    std::string url;
};
BucketSource describe_source(git_repository* repository, const std::string& fallback_remote,
                             const std::string& fallback_branch) {
    const auto head = own(head_reference(repository),git_reference_free);
    BucketSource source;
    source.local_branch = git_reference_shorthand(head.get());
    git_reference* raw_upstream = nullptr;
    if (git_branch_upstream(&raw_upstream,head.get()) == 0 && raw_upstream) {
        const auto upstream = own(raw_upstream,git_reference_free);
        GitBuffer remote_name,merge_reference;
        check(git_branch_upstream_remote(&remote_name.value,repository,git_reference_name(head.get())),"Read tracking remote");
        check(git_branch_upstream_merge(&merge_reference.value,repository,git_reference_name(head.get())),"Read tracking branch");
        const std::string merge = merge_reference.value.ptr ? merge_reference.value.ptr : "";
        if (!merge.starts_with("refs/heads/") || !remote_name.value.ptr || std::string(remote_name.value.ptr) == ".")
            throw std::runtime_error("Unsupported upstream tracking layout; refresh stopped");
        source.remote = remote_name.value.ptr;
        source.branch = merge.substr(std::string("refs/heads/").size());
    } else {
        git_error_clear();
        source.remote = fallback_remote.empty() ? "origin" : fallback_remote;
        source.branch = fallback_branch.empty() ? source.local_branch : fallback_branch;
    }
    git_remote* raw_remote = nullptr;
    check(git_remote_lookup(&raw_remote,repository,source.remote.c_str()),"Read bucket remote");
    const auto remote = own(raw_remote,git_remote_free);
    const char* url = git_remote_url(remote.get());
    if (!url) throw std::runtime_error("Bucket origin URL is missing");
    source.url = url;
    require_supported_url(source.url);
    return source;
}
void validate_component_name(const std::string& value) {
    // Reuse the project guard rather than duplicating path rules. It also rejects reserved
    // Windows names and characters that cannot appear in a shared bucket path.
    validate_component(value);
}
void collect_tree(git_repository* repository, git_tree* tree, const fs::path& relative,
                  Json& files, std::set<std::wstring,CaseInsensitiveLess>& seen) {
    for (std::size_t i = 0; i < git_tree_entrycount(tree); ++i) {
        const auto* entry = git_tree_entry_byindex(tree,i);
        const std::string name = git_tree_entry_name(entry);
        validate_component_name(name);
        if (_stricmp(name.c_str(),".git") == 0) throw std::runtime_error("Git metadata entry is not allowed in a bucket tree");
        const auto path = relative/wide(name);
        if (git_tree_entry_type(entry) == GIT_OBJECT_TREE) {
            if (!seen.insert(path.generic_wstring()).second)
                throw std::runtime_error("Bucket tree has a case-insensitive path collision: "+path_text(path));
            git_tree* raw = nullptr;
            check(git_tree_lookup(&raw,repository,git_tree_entry_id(entry)),"Read bucket directory tree");
            const auto child = own(raw,git_tree_free);
            collect_tree(repository,child.get(),path,files,seen);
        } else if (git_tree_entry_filemode(entry) == GIT_FILEMODE_BLOB ||
                   git_tree_entry_filemode(entry) == GIT_FILEMODE_BLOB_EXECUTABLE) {
            if (!seen.insert(path.generic_wstring()).second)
                throw std::runtime_error("Bucket tree has a case-insensitive path collision: "+path_text(path));
            files[utf8(path.generic_wstring())] = oid_text(git_tree_entry_id(entry));
        } else {
            throw std::runtime_error("Git symlinks and submodules are not supported in shared buckets");
        }
    }
}
Json tree_files(git_repository* repository, git_commit* commit) {
    git_tree* raw = nullptr;
    check(git_commit_tree(&raw,commit),"Read bucket commit tree");
    const auto tree = own(raw,git_tree_free);
    Json files = Json::object();
    std::set<std::wstring,CaseInsensitiveLess> seen;
    collect_tree(repository,tree.get(),{},files,seen);
    return files;
}
void require_clean_worktree(git_repository* repository) {
    git_status_options options = GIT_STATUS_OPTIONS_INIT;
    options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED|GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS;
    git_status_list* raw = nullptr;
    check(git_status_list_new(&raw,repository,&options),"Check local bucket modifications");
    const auto status = own(raw,git_status_list_free);
    if (!git_status_list_entrycount(status.get())) return;
    // A bucket checked out under `core.autocrlf=true` has CRLF bytes in the working tree and LF bytes
    // in the index; Git reports that pair as current, but a byte comparison sees a modification and
    // refuses every refresh. The two are compared with the line endings normalised, and anything
    // else still stops the refresh.
    const auto normalised = [](std::string text) {
        text.erase(std::remove(text.begin(),text.end(),'\r'),text.end());
        return text;
    };
    const auto worktree_matches_index = [&](const std::string& path) {
        git_index* raw_index = nullptr;
        if (git_repository_index(&raw_index,repository) != 0) return false;
        const auto index = own(raw_index,git_index_free);
        const git_index_entry* indexed = git_index_get_bypath(raw_index,path.c_str(),0);
        if (!indexed) return false;
        git_blob* raw_blob = nullptr;
        if (git_blob_lookup(&raw_blob,repository,&indexed->id) != 0) return false;
        const auto blob = own(raw_blob,git_blob_free);
        const auto committed = std::string(static_cast<const char*>(git_blob_rawcontent(raw_blob)),
            static_cast<std::size_t>(git_blob_rawsize(raw_blob)));
        std::ifstream input(std::filesystem::path(wide(git_repository_workdir(repository)))/wide(path),std::ios::binary);
        if (!input) return false;
        const auto working = std::string(std::istreambuf_iterator<char>(input),std::istreambuf_iterator<char>());
        return normalised(committed) == normalised(working);
    };
    for (std::size_t index = 0; index < git_status_list_entrycount(status.get()); ++index) {
        const auto* entry = git_status_byindex(status.get(),index);
        std::string path;
        if (entry && entry->index_to_workdir)
            path = entry->index_to_workdir->new_file.path ? entry->index_to_workdir->new_file.path :
                   entry->index_to_workdir->old_file.path ? entry->index_to_workdir->old_file.path : "";
        if (path.empty() && entry && entry->head_to_index)
            path = entry->head_to_index->new_file.path ? entry->head_to_index->new_file.path :
                   entry->head_to_index->old_file.path ? entry->head_to_index->old_file.path : "";
        // Only a content difference that survives normalisation is a local modification.
        if (!path.empty() && entry && entry->index_to_workdir &&
            (entry->index_to_workdir->status & GIT_DELTA_MODIFIED) && worktree_matches_index(path))
            continue;
        throw std::runtime_error("Local bucket modifications must be preserved; refresh stopped"+
            (path.empty() ? std::string{} : ": "+path));
    }
}
void require_valid_branch(const std::string& branch) {
    const auto refname = "refs/heads/"+branch;
    int valid = 0;
    check(git_reference_name_is_valid(&valid,refname.c_str()),"Validate branch name");
    if (!valid) throw std::runtime_error("Invalid branch name");
}
git_oid resolve_commit(git_repository* repository, const std::string& target) {
    git_object* raw = nullptr;
    const int resolved = git_revparse_single(&raw,repository,target.c_str());
    if (resolved == GIT_ENOTFOUND) throw std::runtime_error("Requested bucket revision was not found: "+target);
    check(resolved,"Resolve requested bucket revision");
    const auto object = own(raw,git_object_free);
    git_object* raw_commit = nullptr;
    check(git_object_peel(&raw_commit,object.get(),GIT_OBJECT_COMMIT),"Read bucket commit");
    const auto commit = own(raw_commit,git_object_free);
    return *git_object_id(commit.get());
}
bool try_resolve_commit(git_repository* repository, const std::string& target, git_oid& oid) {
    try {
        oid = resolve_commit(repository,target);
        return true;
    } catch (const std::exception&) {
        git_error_clear();
        return false;
    }
}
void fetch_refspec(git_remote* remote, const std::string& refspec,
                   Transfer& transfer, const char* operation) {
    std::string spec = refspec;
    char* pointer = spec.data();
    git_strarray specifications{&pointer,1};
    auto options = fetch_options(transfer);
    transfer.base = transfer.bytes;
    check(git_remote_fetch(remote,&specifications,&options,operation),operation);
}
void fetch_branch(git_remote* remote, const BucketSource& source, Transfer& transfer) {
    require_valid_branch(source.branch);
    const auto refspec = "+refs/heads/"+source.branch+":refs/remotes/"+source.remote+"/"+source.branch;
    fetch_refspec(remote,refspec,transfer,"Fetch shared bucket revision");
}
void fetch_pinned(git_remote* remote, const std::string& revision, Transfer& transfer) {
    fetch_refspec(remote,"+"+revision+":refs/coop/pinned",transfer,"Fetch fixed source revision");
}
git_oid head_oid(git_repository* repository) {
    const auto head = own(head_reference(repository),git_reference_free);
    git_object* raw = nullptr;
    check(git_reference_peel(&raw,head.get(),GIT_OBJECT_COMMIT),"Read current bucket commit");
    const auto commit = own(raw,git_object_free);
    return *git_object_id(commit.get());
}
bool is_fast_forward(git_repository* repository, const git_oid& target, const git_oid& current) {
    if (git_oid_equal(&target,&current)) return true;
    const int descendant = git_graph_descendant_of(repository,&target,&current);
    check(descendant,"Compare bucket history");
    return descendant == 1;
}
std::size_t changed_file_count(git_repository* repository, git_commit* old_commit, git_commit* new_commit) {
    git_tree* raw_old = nullptr;
    check(git_commit_tree(&raw_old,old_commit),"Read previous bucket tree");
    const auto old_tree = own(raw_old,git_tree_free);
    git_tree* raw_new = nullptr;
    check(git_commit_tree(&raw_new,new_commit),"Read target bucket tree");
    const auto new_tree = own(raw_new,git_tree_free);
    git_diff* raw_diff = nullptr;
    check(git_diff_tree_to_tree(&raw_diff,repository,old_tree.get(),new_tree.get(),nullptr),"Compare bucket revisions");
    const auto diff = own(raw_diff,git_diff_free);
    return static_cast<std::size_t>(git_diff_num_deltas(diff.get()));
}
std::string timestamp() {
    SYSTEMTIME time{};
    GetSystemTime(&time);
    char text[32]{};
    sprintf_s(text,"%04u-%02u-%02uT%02u:%02u:%02uZ",time.wYear,time.wMonth,time.wDay,time.wHour,time.wMinute,time.wSecond);
    return text;
}
void invalidate_index(const Context& context, const std::string& name) {
    const auto index = state_cache_directory(context)/L"index"/(wide(name)+L".json");
    for (int attempt = 0; attempt < 40; ++attempt) {
        if (DeleteFileW(index.c_str())) return;
        const DWORD error = GetLastError();
        if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) return;
        if (error != ERROR_SHARING_VIOLATION && error != ERROR_LOCK_VIOLATION && error != ERROR_ACCESS_DENIED)
            throw std::runtime_error("Cannot invalidate the search index before refresh (Windows error "+std::to_string(error)+")");
        Sleep(50);
    }
    throw std::runtime_error("Cannot invalidate the search index before refresh; a reader is holding it");
}
void move_directory(const fs::path& source, const fs::path& destination,
                    const fs::path& source_parent, const fs::path& destination_parent) {
    const auto expected_source = fs::canonical(source_parent);
    const auto expected_destination = fs::canonical(destination_parent);
    if (fs::weakly_canonical(source.parent_path()) != expected_source ||
        fs::weakly_canonical(destination.parent_path()) != expected_destination || fs::exists(destination))
        throw std::runtime_error("Unsafe or conflicting shared bucket move");
    require_regular_directory(source);
    require_regular_directory(destination);
    try {
        // The clone staged under the state directory (usually C:) and the shared bucket lives under
        // the selected root, so a cross-volume copy is part of publishing. move_tree owns that fallback.
        move_tree(source,destination);
    } catch (const std::exception& error) {
        throw std::runtime_error(std::string("Cannot publish the shared bucket directory: ")+error.what());
    }
}
void cleanup_staging(const fs::path& staging, const std::string& name) {
    if (!fs::is_directory(staging)) return;
    const auto prefix = wide(name)+L"-clone-";
    for (const auto& entry : fs::directory_iterator(staging)) {
        const auto filename = entry.path().filename().wstring();
        if (!filename.starts_with(prefix)) continue;
        const DWORD attributes = GetFileAttributesW(entry.path().c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) continue;
        std::error_code ignored;
        fs::remove_all(entry.path(),ignored);
    }
}
Json make_record(const std::string& name, const BucketSource& source, const std::string& fixed_revision,
                 const git_oid& revision, const fs::path& path, std::size_t files_count, bool first, bool changed,
                 const std::string& previous_revision, std::size_t changed_files, std::size_t received_bytes) {
    const auto refresh_kind = first ? "first" : changed ? "changed" : "unchanged";
    return {{"name",name},{"kind","git"},{"layout","shared-worktree"},{"url",source.url},
        {"remote",source.remote},{"branch",source.branch},{"fixed_revision",fixed_revision},
        {"revision",oid_text(&revision)},{"path",path_text(path)},
        {"files_count",files_count},{"changed_files",changed_files},
        {"received_bytes",received_bytes},{"changed",changed},{"first_refresh",first},
        {"refresh_kind",refresh_kind},{"previous_revision",previous_revision.empty() ? Json(nullptr) : Json(previous_revision)},
        {"synced_at",timestamp()}};
}
void checkout_commit(git_repository* repository, const git_oid& target, const git_oid& previous) {
    auto commit = lookup_commit(repository,&target);
    git_checkout_options options = GIT_CHECKOUT_OPTIONS_INIT;
    options.checkout_strategy = GIT_CHECKOUT_SAFE|GIT_CHECKOUT_RECREATE_MISSING;
    try {
        check(git_reset(repository,reinterpret_cast<git_object*>(commit.get()),GIT_RESET_HARD,&options),
              "Update shared bucket working tree");
    } catch (...) {
        // The worktree was verified clean before this point, so restoring the previous commit is
        // the only safe repair for a partially written checkout. If repair itself fails the
        // original error is still reported.
        try {
            auto old = lookup_commit(repository,&previous);
            git_checkout_options force = GIT_CHECKOUT_OPTIONS_INIT;
            force.checkout_strategy = GIT_CHECKOUT_FORCE;
            if (git_reset(repository,reinterpret_cast<git_object*>(old.get()),GIT_RESET_HARD,&force) < 0)
                git_error_clear();
        } catch (const std::exception&) { git_error_clear(); }
        throw;
    }
}
Json clone_shared_bucket(const Context& context, const std::string& name, const std::string& url,
                         const std::string& branch, const std::string& revision) {
    require_supported_url(url);
    if (!revision.empty()) {
        const bool valid = revision.size() == 40 && std::all_of(revision.begin(),revision.end(),[](unsigned char c) {
            return std::isxdigit(c) != 0;
        });
        if (!valid) throw std::runtime_error("A fixed revision must be a full commit id");
    }
    const auto buckets = context.root/L"buckets";
    require_regular_directory(buckets);
    fs::create_directories(buckets);
    const auto destination = buckets/wide(name);
    require_regular_directory(destination);
    if (fs::exists(destination)) throw std::runtime_error("Shared bucket directory already exists; use bucket update to adopt it");
    const auto staging_root = state_cache_directory(context)/L"staging";
    require_regular_directory(staging_root);
    fs::create_directories(staging_root);
    cleanup_staging(staging_root,name);
    const auto staging = staging_root/(wide(name)+L"-clone-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));
    if (fs::exists(staging)) throw std::runtime_error("Git clone staging path already exists");
    Transfer transfer;
    git_clone_options options = GIT_CLONE_OPTIONS_INIT;
    options.fetch_opts = fetch_options(transfer);
    // No worktree is written until the target tree has been validated.
    options.checkout_opts.checkout_strategy = GIT_CHECKOUT_NONE;
    options.checkout_branch = branch.empty() ? nullptr : branch.c_str();
    git_repository* raw = nullptr;
    try {
        check(git_clone(&raw,url.c_str(),path_text(staging).c_str(),&options),"Clone shared bucket");
    } catch (...) {
        std::error_code ignored;
        fs::remove_all(staging,ignored);
        throw;
    }
    Json record;
    try {
        const auto repository = Repo(raw,git_repository_free);
        auto source = describe_source(repository.get(),"origin",branch);
        git_oid target = head_oid(repository.get());
        if (!revision.empty()) {
            if (!try_resolve_commit(repository.get(),revision,target)) {
                git_remote* raw_remote = nullptr;
                check(git_remote_lookup(&raw_remote,repository.get(),source.remote.c_str()),"Open bucket remote");
                const auto remote = own(raw_remote,git_remote_free);
                fetch_pinned(remote.get(),revision,transfer);
                target = resolve_commit(repository.get(),revision);
            }
        }
        auto commit = lookup_commit(repository.get(),&target);
        auto files = tree_files(repository.get(),commit.get());
        const auto files_count = files.size();
        if (!revision.empty()) {
            const auto previous = head_oid(repository.get());
            if (!git_oid_equal(&previous,&target)) checkout_commit(repository.get(),target,previous);
        }
        git_checkout_options checkout = GIT_CHECKOUT_OPTIONS_INIT;
        checkout.checkout_strategy = GIT_CHECKOUT_SAFE|GIT_CHECKOUT_RECREATE_MISSING;
        check(git_checkout_head(repository.get(),&checkout),"Materialize shared bucket working tree");
        require_clean_worktree(repository.get());
        source = describe_source(repository.get(),source.remote,source.branch);
        record = make_record(name,source,revision,target,destination,files_count,true,true,{},files_count,transfer.bytes);
        record["adopted"] = false;
    } catch (...) {
        std::error_code ignored;
        fs::remove_all(staging,ignored);
        throw;
    }
    move_directory(staging,destination,staging_root,buckets);
    return record;
}
Json refresh_shared_bucket(const Context& context, const std::string& name, const Json& previous) {
    const auto directory = context.root/L"buckets"/wide(name);
    auto repository = open_shared_bucket(directory);
    const std::string fallback_remote = previous.value("remote",std::string{});
    const std::string fallback_branch = previous.value("branch",std::string{});
    auto source = describe_source(repository.get(),fallback_remote,fallback_branch);
    const std::string fixed_revision = previous.value("fixed_revision",std::string{});
    const auto old_revision = head_oid(repository.get());
    require_clean_worktree(repository.get());
    Transfer transfer;
    git_remote* raw_remote = nullptr;
    check(git_remote_lookup(&raw_remote,repository.get(),source.remote.c_str()),"Open bucket remote");
    const auto remote = own(raw_remote,git_remote_free);
    git_oid target{};
    if (!fixed_revision.empty()) {
        if (!try_resolve_commit(repository.get(),fixed_revision,target)) {
            fetch_pinned(remote.get(),fixed_revision,transfer);
            target = resolve_commit(repository.get(),fixed_revision);
        }
    } else {
        fetch_branch(remote.get(),source,transfer);
        target = resolve_commit(repository.get(),"refs/remotes/"+source.remote+"/"+source.branch);
    }
    require_clean_worktree(repository.get());
    auto commit = lookup_commit(repository.get(),&target);
    auto files = tree_files(repository.get(),commit.get());
    const auto files_count = files.size();
    const std::string previous_revision = previous.value("revision",std::string{});
    const bool adopted = previous.value("adopted",false) || previous.value("kind",std::string{}) == "unmanaged";
    const bool already_current = git_oid_equal(&old_revision,&target);
    if (already_current) {
        const bool record_stale = previous_revision != oid_text(&target) ||
            previous.value("path",std::string{}) != path_text(directory);
        if (record_stale) invalidate_index(context,name);
        auto record = make_record(name,source,fixed_revision,target,directory,files_count,false,record_stale,
            record_stale ? previous_revision : std::string{},0,transfer.bytes);
        record["adopted"] = adopted;
        return record;
    }
    // A bucket may contain local commits. Fast-forwarding preserves them; anything else would
    // discard local history, so stop before touching the worktree or the published record.
    if (!is_fast_forward(repository.get(),target,old_revision))
        throw std::runtime_error("Local bucket history has commits or a divergent revision; refusing to discard local history ("+
            oid_text(&old_revision)+" is not an ancestor of "+oid_text(&target)+")");
    invalidate_index(context,name);
    checkout_commit(repository.get(),target,old_revision);
    auto refreshed = describe_source(repository.get(),source.remote,source.branch);
    const auto changed_files = changed_file_count(repository.get(),lookup_commit(repository.get(),&old_revision).get(),commit.get());
    auto record = make_record(name,refreshed,fixed_revision,target,directory,files_count,false,true,
        oid_text(&old_revision),changed_files,transfer.bytes);
    record["adopted"] = adopted;
    return record;
}
}
Json inspect_scoop_bucket(const Context& context, const std::string& name) {
    GitSession session(context.root);
    const auto directory = context.root/L"buckets"/wide(name);
    auto repository = open_shared_bucket(directory);
    auto source = describe_source(repository.get(),"origin",{});
    const auto revision = head_oid(repository.get());
    auto commit = lookup_commit(repository.get(),&revision);
    auto files = tree_files(repository.get(),commit.get());
    const auto files_count = files.size();
    return {{"name",name},{"kind","git"},{"layout","shared-worktree"},{"url",source.url},
        {"remote",source.remote},{"branch",source.branch},{"fixed_revision",""},
        {"revision",oid_text(&revision)},{"path",path_text(directory)},
        {"files_count",files_count},{"changed_files",0},{"received_bytes",0},
        {"changed",false},{"first_refresh",false},{"refresh_kind","inspected"},
        {"adopted",false},{"previous_revision",nullptr},{"synced_at",nullptr}};
}
Json prepare_git_bucket(const Context& context, const std::string& name, const std::string& url,
                        const std::string& branch, const std::string& revision, const Json* previous) {
    GitSession session(context.root);
    const auto shared = context.root/L"buckets"/wide(name);
    if (!previous) return clone_shared_bucket(context,name,url,branch,revision);
    const bool recorded_shared = previous->contains("path") && previous->at("path").is_string() &&
        fs::path(wide(previous->at("path").get<std::string>())) == shared;
    if (recorded_shared) return refresh_shared_bucket(context,name,*previous);
    // A pre-existing Scoop bucket is adopted in place; otherwise an older snapshot record is
    // migrated by creating the shared working tree from its recorded source.
    if (fs::exists(shared/L".git")) return refresh_shared_bucket(context,name,*previous);
    require_regular_directory(shared);
    if (fs::exists(shared)) throw std::runtime_error("Shared bucket path exists but is not a Git repository");
    const auto recorded_url = previous->value("url",url);
    if (recorded_url.empty()) throw std::runtime_error("Bucket source URL is missing; cannot create the shared bucket");
    return clone_shared_bucket(context,name,recorded_url,previous->value("branch",branch),
        previous->value("fixed_revision",revision));
}
}
