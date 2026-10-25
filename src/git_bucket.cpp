#include "git_bucket.hpp"
#include <git2.h>
#include <git2/sys/errors.h>
#include <windows.h>
#include <fstream>
#include <memory>
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
class GitSession {
public:
    explicit GitSession(const fs::path& root) {
        check(git_libgit2_init(),"Initialize Git library");
        try {
            const auto isolated = path_text(root/L".coop"/L"disabled-user-config");
            for (const auto level : {GIT_CONFIG_LEVEL_SYSTEM,GIT_CONFIG_LEVEL_GLOBAL,GIT_CONFIG_LEVEL_XDG,GIT_CONFIG_LEVEL_PROGRAMDATA})
                check(git_libgit2_opts(GIT_OPT_SET_SEARCH_PATH,level,isolated.c_str()),"Isolate Git configuration");
        } catch (...) { git_libgit2_shutdown(); throw; }
    }
    ~GitSession() { git_libgit2_shutdown(); }
};
struct GitBuffer {
    git_buf value = GIT_BUF_INIT;
    ~GitBuffer() { git_buf_dispose(&value); }
};
std::string oid_text(const git_oid* oid) {
    char text[GIT_OID_HEXSZ+1]{};
    git_oid_tostr(text,sizeof(text),oid);
    return text;
}
void require_public_url(const std::string& url) {
    if (!url.starts_with("file://") && !url.starts_with("https://"))
        throw std::runtime_error("Only public HTTPS Git and local file sources are supported");
    if (url.starts_with("https://")) {
        const auto slash = url.find('/',8);
        if (url.substr(8,slash == std::string::npos ? slash : slash-8).find('@') != std::string::npos)
            throw std::runtime_error("Embedded credentials are not supported");
    }
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
    options.depth = 1;
    options.callbacks.transfer_progress = transferred;
    options.callbacks.credentials = no_credentials;
    options.callbacks.payload = &transfer;
    options.proxy_opts.type = GIT_PROXY_AUTO;
    options.proxy_opts.credentials = no_credentials;
    return options;
}
void require_regular_directory(const fs::path& directory) {
    const DWORD attributes = GetFileAttributesW(directory.c_str());
    if (attributes != INVALID_FILE_ATTRIBUTES && (!(attributes & FILE_ATTRIBUTE_DIRECTORY) || (attributes & FILE_ATTRIBUTE_REPARSE_POINT)))
        throw std::runtime_error("Git storage directory is not an ordinary directory");
}
void move_cache_directory(const fs::path& source, const fs::path& destination, const fs::path& parent) {
    const auto expected_parent = fs::canonical(parent);
    if (fs::weakly_canonical(source.parent_path()) != expected_parent ||
        fs::weakly_canonical(destination.parent_path()) != expected_parent || fs::exists(destination))
        throw std::runtime_error("Unsafe or conflicting Git cache move");
    require_regular_directory(source);
    fs::rename(source,destination);
}
bool cache_is_initialized(git_repository* repository) {
    git_reference* head = nullptr;
    if (git_repository_head(&head,repository) < 0) return false;
    const auto reference = own(head,git_reference_free);
    git_commit* commit = nullptr;
    if (git_commit_lookup(&commit,repository,git_reference_target(reference.get())) < 0) return false;
    git_commit_free(commit);
    return true;
}
Json disk_files(const fs::path& directory, bool skip_git = false) {
    require_regular_directory(directory);
    Json files = Json::object();
    if (!fs::exists(directory)) return files;
    for (fs::recursive_directory_iterator item(directory),end; item != end; ++item) {
        const auto relative = item->path().lexically_relative(directory);
        if (skip_git && *relative.begin() == L".git") { item.disable_recursion_pending(); continue; }
        const DWORD attributes = GetFileAttributesW(item->path().c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_REPARSE_POINT))
            throw std::runtime_error("Bucket contains an unsupported link or inaccessible file");
        if (item->is_directory()) continue;
        if (!item->is_regular_file()) throw std::runtime_error("Bucket contains a non-regular file");
        git_oid oid{};
        check(git_odb_hashfile(&oid,path_text(item->path()).c_str(),GIT_OBJECT_BLOB),"Hash bucket file");
        files[utf8(relative.generic_wstring())] = oid_text(&oid);
    }
    return files;
}
void export_tree(git_repository* repository, git_tree* tree, const fs::path& root,
                 const fs::path& relative, Json& files) {
    for (std::size_t i = 0; i < git_tree_entrycount(tree); ++i) {
        const auto* entry = git_tree_entry_byindex(tree,i);
        const std::string name = git_tree_entry_name(entry);
        validate_component(name);
        if (_stricmp(name.c_str(),".git") == 0) throw std::runtime_error("Git metadata entry is not allowed in a snapshot");
        const auto path = relative/wide(name);
        if (git_tree_entry_type(entry) == GIT_OBJECT_TREE) {
            git_tree* raw = nullptr;
            check(git_tree_lookup(&raw,repository,git_tree_entry_id(entry)),"Read directory tree");
            const auto child = own(raw,git_tree_free);
            fs::create_directories(root/path);
            export_tree(repository,child.get(),root,path,files);
        } else if (git_tree_entry_filemode(entry) == GIT_FILEMODE_BLOB || git_tree_entry_filemode(entry) == GIT_FILEMODE_BLOB_EXECUTABLE) {
            git_blob* raw = nullptr;
            check(git_blob_lookup(&raw,repository,git_tree_entry_id(entry)),"Read repository file");
            const auto blob = own(raw,git_blob_free);
            fs::create_directories((root/path).parent_path());
            std::ofstream output(root/path,std::ios::binary|std::ios::trunc);
            output.write(static_cast<const char*>(git_blob_rawcontent(blob.get())),static_cast<std::streamsize>(git_blob_rawsize(blob.get())));
            output.close();
            if (!output) throw std::runtime_error("Cannot write Git snapshot file");
            files[utf8(path.generic_wstring())] = oid_text(git_tree_entry_id(entry));
        } else throw std::runtime_error("Git symlinks and submodules are not supported in bucket snapshots");
    }
}
std::string timestamp() {
    SYSTEMTIME time{};
    GetSystemTime(&time);
    char text[32]{};
    sprintf_s(text,"%04u-%02u-%02uT%02u:%02u:%02uZ",time.wYear,time.wMonth,time.wDay,time.wHour,time.wMinute,time.wSecond);
    return text;
}
}
Json inspect_scoop_bucket(const Context& context, const std::string& name) {
    GitSession session(context.root);
    const auto directory = context.root/L"buckets"/wide(name);
    git_repository* raw = nullptr;
    check(git_repository_open(&raw,path_text(directory).c_str()),"Open existing bucket repository");
    const auto repository = own(raw,git_repository_free);
    git_status_options options = GIT_STATUS_OPTIONS_INIT;
    options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED|GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS;
    git_status_list* raw_status = nullptr;
    check(git_status_list_new(&raw_status,repository.get(),&options),"Check local bucket modifications");
    const auto status = own(raw_status,git_status_list_free);
    if (git_status_list_entrycount(status.get())) throw std::runtime_error("Local bucket modifications must be preserved; update stopped");
    git_reference* raw_head = nullptr;
    check(git_repository_head(&raw_head,repository.get()),"Read current bucket revision");
    const auto head = own(raw_head,git_reference_free);
    if (!git_reference_is_branch(head.get())) throw std::runtime_error("Detached bucket requires an explicit fixed revision");
    git_reference* raw_upstream = nullptr;
    check(git_branch_upstream(&raw_upstream,head.get()),"Read upstream branch");
    const auto upstream = own(raw_upstream,git_reference_free);
    if (!git_oid_equal(git_reference_target(head.get()),git_reference_target(upstream.get())))
        throw std::runtime_error("Local and upstream revisions differ; refusing to discard local history");
    GitBuffer remote_name,merge_reference;
    check(git_branch_upstream_remote(&remote_name.value,repository.get(),git_reference_name(head.get())),"Read tracking remote");
    check(git_branch_upstream_merge(&merge_reference.value,repository.get(),git_reference_name(head.get())),"Read tracking branch");
    const std::string merge = merge_reference.value.ptr ? merge_reference.value.ptr : "";
    if (!merge.starts_with("refs/heads/") || !remote_name.value.ptr || std::string(remote_name.value.ptr) == ".")
        throw std::runtime_error("Unsupported upstream tracking layout; update stopped");
    git_remote* raw_remote = nullptr;
    check(git_remote_lookup(&raw_remote,repository.get(),remote_name.value.ptr),"Read bucket tracking source");
    const auto remote = own(raw_remote,git_remote_free);
    const char* url = git_remote_url(remote.get());
    if (!url) throw std::runtime_error("Bucket origin URL is missing");
    require_public_url(url);
    return {{"name",name},{"url",url},{"branch",merge.substr(std::string("refs/heads/").size())},
        {"revision",oid_text(git_reference_target(head.get()))},{"path",path_text(directory)},
        {"files",disk_files(directory,true)},{"kind","git"},{"synced_at",nullptr}};
}
Json prepare_git_bucket(const Context& context, const std::string& name, const std::string& url,
                        const std::string& branch, const std::string& revision, const Json* previous) {
    require_public_url(url);
    GitSession session(context.root);
    if (previous) {
        const fs::path old_directory(wide(previous->at("path").get<std::string>()));
        const bool original = old_directory == context.root/L"buckets"/wide(name);
        if (disk_files(old_directory,original) != previous->at("files"))
            throw std::runtime_error("Local bucket modifications detected; update stopped");
    }
    const auto repositories = context.root/L".coop"/L"repositories";
    require_regular_directory(repositories);
    fs::create_directories(repositories);
    git_oid source_id{};
    check(git_odb_hash(&source_id,url.data(),url.size(),GIT_OBJECT_BLOB),"Identify repository source");
    const auto repository_path = repositories/(wide(name)+L"-"+wide(oid_text(&source_id))+L".git");
    require_regular_directory(repository_path);
    Transfer transfer;
    git_repository* raw = nullptr;
    std::string selected_branch = branch;
    if (fs::exists(repository_path)) {
        const int opened = git_repository_open_bare(&raw,path_text(repository_path).c_str());
        if (opened < 0 || !cache_is_initialized(raw)) {
            if (raw) { git_repository_free(raw); raw = nullptr; }
            const auto quarantine = fs::path(repository_path.wstring()+L".incomplete-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));
            move_cache_directory(repository_path,quarantine,repositories);
        }
    }
    if (!raw) {
        const auto initialization = fs::path(repository_path.wstring()+L".init-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));
        if (fs::exists(initialization)) throw std::runtime_error("Git initialization path already exists");
        git_clone_options options = GIT_CLONE_OPTIONS_INIT;
        options.bare = 1;
        options.fetch_opts = fetch_options(transfer);
        if (url.starts_with("file://")) options.fetch_opts.depth = 0;
        options.checkout_branch = branch.empty() ? nullptr : branch.c_str();
        git_repository* initializing = nullptr;
        check(git_clone(&initializing,url.c_str(),path_text(initialization).c_str(),&options),"Clone bucket");
        {
            const auto complete = own(initializing,git_repository_free);
            if (!cache_is_initialized(complete.get())) throw std::runtime_error("Cloned repository has no complete initial commit");
        }
        move_cache_directory(initialization,repository_path,repositories);
        check(git_repository_open_bare(&raw,path_text(repository_path).c_str()),"Open initialized object store");
    }
    const auto repository = own(raw,git_repository_free);
    git_remote* raw_remote = nullptr;
    check(git_remote_lookup(&raw_remote,repository.get(),"origin"),"Open bucket remote");
    const auto remote = own(raw_remote,git_remote_free);
    if (!git_remote_url(remote.get()) || url != git_remote_url(remote.get())) throw std::runtime_error("Cached repository origin differs from requested source");
    if (selected_branch.empty()) {
        git_reference* raw_head = nullptr;
        check(git_repository_head(&raw_head,repository.get()),"Resolve default branch");
        const auto head = own(raw_head,git_reference_free);
        selected_branch = git_reference_shorthand(head.get());
    }
    const auto refname = "refs/heads/"+selected_branch;
    int valid = 0;
    check(git_reference_name_is_valid(&valid,refname.c_str()),"Validate branch name");
    if (!valid) throw std::runtime_error("Invalid branch name");
    transfer.base = transfer.bytes;
    auto fetch = fetch_options(transfer);
    if (url.starts_with("file://")) fetch.depth = 0;
    std::string spec = "+"+refname+":refs/remotes/origin/"+selected_branch;
    char* spec_pointer = spec.data();
    git_strarray specifications{&spec_pointer,1};
    check(git_remote_fetch(remote.get(),&specifications,&fetch,nullptr),"Fetch bucket revision");
    const std::string target = revision.empty() ? "refs/remotes/origin/"+selected_branch : revision;
    git_object* raw_object = nullptr;
    int resolved = git_revparse_single(&raw_object,repository.get(),target.c_str());
    if (resolved == GIT_ENOTFOUND && !revision.empty()) {
        std::string pinned_spec = "+"+revision+":refs/coop/pinned";
        char* pinned_pointer = pinned_spec.data();
        git_strarray pinned_specifications{&pinned_pointer,1};
        transfer.base = transfer.bytes;
        check(git_remote_fetch(remote.get(),&pinned_specifications,&fetch,nullptr),"Fetch fixed source revision");
        resolved = git_revparse_single(&raw_object,repository.get(),target.c_str());
    }
    check(resolved,"Resolve requested revision");
    const auto object = own(raw_object,git_object_free);
    git_object* raw_commit = nullptr;
    check(git_object_peel(&raw_commit,object.get(),GIT_OBJECT_COMMIT),"Read commit");
    const auto commit = own(raw_commit,git_object_free);
    const auto oid = oid_text(git_object_id(commit.get()));
    if (previous && previous->at("revision") == oid) {
        Json result = *previous;
        result["received_bytes"] = transfer.bytes;
        result["changed"] = false;
        return result;
    }
    const auto generations = context.root/L".coop"/L"snapshots";
    require_regular_directory(generations);
    fs::create_directories(generations);
    const auto generation = generations/(wide(name)+L"-"+wide(oid)+L"-"+std::to_wstring(GetTickCount64()));
    if (!fs::create_directory(generation)) throw std::runtime_error("Snapshot generation already exists");
    const auto snapshot = generation/wide(name);
    fs::create_directory(snapshot);
    git_tree* raw_tree = nullptr;
    check(git_commit_tree(&raw_tree,reinterpret_cast<git_commit*>(commit.get())),"Read commit tree");
    const auto tree = own(raw_tree,git_tree_free);
    Json files = Json::object();
    export_tree(repository.get(),tree.get(),snapshot,{},files);
    if (disk_files(snapshot) != files) throw std::runtime_error("Snapshot verification failed");
    return {{"name",name},{"kind","git"},{"url",url},{"branch",selected_branch},{"fixed_revision",revision},
        {"revision",oid},{"path",path_text(snapshot)},{"files",files},{"synced_at",timestamp()},
        {"received_bytes",transfer.bytes},{"changed",true}};
}
}
