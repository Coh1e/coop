#include "persist.hpp"
#include "native.hpp"
#include <windows.h>
#include <algorithm>
#include <array>
#include <cstddef>
#include <iterator>
#include <set>
#include <stdexcept>

namespace coop {
namespace {
struct ResolvedEntry {
    Persistence mapping;
    fs::path link;
    fs::path store;
    bool directory = false;
};

void validate_path(const fs::path& path, const char* field) {
    if (path.empty() || path == L"." || path.is_absolute() || path.has_root_name() || path.has_root_directory())
        throw std::runtime_error(std::string("Persist ")+field+" must be a package-relative path");
    for (const auto& component : path) {
        if (component == L".") continue;
        validate_component(path_text(component));
    }
}

void validate_mapping(const Persistence& mapping) {
    validate_path(mapping.source,"source");
    validate_path(mapping.target,"target");
}

void require_unique(const Package& package) {
    for (std::size_t i = 0; i < package.persistence.size(); ++i) for (std::size_t j = i+1; j < package.persistence.size(); ++j) {
        if (equal_name(path_text(package.persistence[i].source),path_text(package.persistence[j].source)))
            throw std::runtime_error("Duplicate persist source: "+path_text(package.persistence[i].source));
        if (equal_name(path_text(package.persistence[i].target),path_text(package.persistence[j].target)))
            throw std::runtime_error("Duplicate persist target: "+path_text(package.persistence[i].target));
    }
}

void require_ordinary(const fs::path& base, const fs::path& path, bool final_reparse_allowed) {
    const auto relative = path.lexically_relative(base);
    if (relative.empty() || relative.is_absolute()) throw std::runtime_error("Persisted path escapes its managed root");
    auto current = base;
    for (auto entry = relative.begin(); entry != relative.end(); ++entry) {
        const auto component = *entry;
        validate_component(path_text(component));
        current /= component;
        if (std::next(entry) == relative.end() && final_reparse_allowed) break;
        const auto attributes = GetFileAttributesW(current.c_str());
        if (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_REPARSE_POINT))
            throw std::runtime_error("Persisted path contains an unmanaged reparse point: "+path_text(current));
    }
}

fs::path store_path(const Context& context, const Package& package, const fs::path& target) {
    validate_component(package.name);
    return context.root/L"persist"/wide(package.name)/target;
}

struct FileIdentity {
    DWORD volume = 0;
    DWORD high = 0;
    DWORD low = 0;
    bool operator==(const FileIdentity&) const = default;
};

FileIdentity file_identity(const fs::path& path, const char* field, bool directory = false) {
    DWORD flags = FILE_FLAG_OPEN_REPARSE_POINT;
    if (directory) flags |= FILE_FLAG_BACKUP_SEMANTICS;
    HANDLE handle = CreateFileW(path.c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,
        nullptr,OPEN_EXISTING,flags,nullptr);
    if (handle == INVALID_HANDLE_VALUE)
        throw std::runtime_error(std::string(field)+" cannot be opened (Windows error "+std::to_string(GetLastError())+")");
    BY_HANDLE_FILE_INFORMATION information{};
    const bool success = GetFileInformationByHandle(handle,&information) != 0;
    const DWORD error = success ? ERROR_SUCCESS : GetLastError();
    CloseHandle(handle);
    if (!success) throw std::runtime_error(std::string(field)+" identity cannot be read (Windows error "+std::to_string(error)+")");
    if (information.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)
        throw std::runtime_error(std::string(field)+" is an unsupported reparse point");
    return {information.dwVolumeSerialNumber,information.nFileIndexHigh,information.nFileIndexLow};
}

std::string identity_text(const FileIdentity& identity) {
    return std::to_string(identity.volume)+":"+std::to_string(identity.high)+":"+std::to_string(identity.low);
}

std::string normalized_path_text(const fs::path& path) {
    auto text = path_text(path.lexically_normal());
    while (text.size() > 3 && (text.back() == '\\' || text.back() == '/')) text.pop_back();
    return text;
}

ResolvedEntry resolve_entry(const Context& context, const Package& package, const Persistence& mapping,
                            const fs::path& version_directory) {
    validate_mapping(mapping);
    ResolvedEntry result{mapping,version_directory/mapping.source,store_path(context,package,mapping.target),false};
    require_ordinary(context.root,result.store,false);
    require_ordinary(version_directory,result.link,true);
    const auto store_attributes = GetFileAttributesW(result.store.c_str());
    if (store_attributes == INVALID_FILE_ATTRIBUTES)
        throw std::runtime_error("Persisted store target is missing: "+path_text(result.store));
    if (store_attributes & FILE_ATTRIBUTE_REPARSE_POINT)
        throw std::runtime_error("Persisted store target is a reparse point: "+path_text(result.store));
    result.directory = (store_attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
    if (!result.directory && (store_attributes & (FILE_ATTRIBUTE_DEVICE|FILE_ATTRIBUTE_REPARSE_POINT)))
        throw std::runtime_error("Persisted store target is not a regular file or directory");
    const auto link_attributes = GetFileAttributesW(result.link.c_str());
    if (link_attributes == INVALID_FILE_ATTRIBUTES)
        throw std::runtime_error("Managed persistence link is missing: "+path_text(result.link));
    if (link_attributes & FILE_ATTRIBUTE_REPARSE_POINT) {
        if (!(link_attributes & FILE_ATTRIBUTE_DIRECTORY))
            throw std::runtime_error("Managed persistence link uses an unsupported reparse type: "+path_text(result.link));
        if (!result.directory)
            throw std::runtime_error("Managed directory link points to a file store target");
        if (!equal_name(normalized_path_text(junction_target(result.link)),normalized_path_text(result.store)))
            throw std::runtime_error("Managed persistence link points to a different directory: "+path_text(result.link));
    } else if (link_attributes & FILE_ATTRIBUTE_DIRECTORY) {
        throw std::runtime_error("Persisted source is a real directory, not a managed junction");
    } else {
        if (result.directory) throw std::runtime_error("Managed file link points to a directory store target");
        if (!(file_identity(result.link,"Managed persistence file link") == file_identity(result.store,"Persisted store file")))
            throw std::runtime_error("Managed persistence file link points to a different file: "+path_text(result.link));
    }
    return result;
}

void create_directories(const fs::path& path, const char* action) {
    try { fs::create_directories(path); }
    catch (const fs::filesystem_error& error) {
        throw std::runtime_error(std::string(action)+": "+path_text(path)+
            " (filesystem error "+std::to_string(error.code().value())+")");
    }
}

void move_path(const fs::path& source, const fs::path& destination, const char* action) {
    if (GetFileAttributesW(destination.c_str()) != INVALID_FILE_ATTRIBUTES)
        throw std::runtime_error(std::string(action)+" target already exists: "+path_text(destination));
    if (!MoveFileExW(source.c_str(),destination.c_str(),MOVEFILE_WRITE_THROUGH))
        throw std::runtime_error(std::string(action)+" failed (Windows error "+std::to_string(GetLastError())+")");
}

void create_link(const fs::path& link, const fs::path& store, bool directory) {
    if (GetFileAttributesW(link.c_str()) != INVALID_FILE_ATTRIBUTES)
        throw std::runtime_error("Persisted source path already exists: "+path_text(link));
    create_directories(link.parent_path(),"Cannot create persisted source directory");
    if (directory) make_junction(link,store);
    else if (!CreateHardLinkW(link.c_str(),store.c_str(),nullptr))
        throw std::runtime_error("Cannot create persisted file link (Windows error "+std::to_string(GetLastError())+")");
}
}
Json persistence_plan_json(const Context& context, const Package& package, const fs::path& version_directory) {
    require_unique(package);
    Json result = Json::array();
    for (const auto& mapping : package.persistence) {
        validate_mapping(mapping);
        const auto store = store_path(context,package,mapping.target);
        const auto attributes = GetFileAttributesW(store.c_str());
        std::string link_type = "unresolved";
        if (attributes != INVALID_FILE_ATTRIBUTES) {
            if (attributes & FILE_ATTRIBUTE_REPARSE_POINT) link_type = "unsupported-reparse-point";
            else if (attributes & FILE_ATTRIBUTE_DIRECTORY) link_type = "junction";
            else link_type = "hardlink";
        }
        Json entry = {{"source",path_text(mapping.source)},{"target",path_text(mapping.target)},{"store",path_text(store)},
            {"store_exists",attributes != INVALID_FILE_ATTRIBUTES},{"link_type",link_type},{"data_retained",true}};
        entry["link"] = version_directory.empty() ? Json(nullptr) : Json(path_text(version_directory/mapping.source));
        result.push_back(std::move(entry));
    }
    return result;
}
Json prepare_persistence(const Context& context, const Package& package, const fs::path& stage_directory) {
    require_unique(package);
    for (const auto& mapping : package.persistence) {
        validate_mapping(mapping);
        const auto link = stage_directory/mapping.source;
        const auto store = store_path(context,package,mapping.target);
        require_ordinary(context.root,store,false);
        require_ordinary(stage_directory,link,true);
        const auto link_attributes = GetFileAttributesW(link.c_str());
        if (link_attributes != INVALID_FILE_ATTRIBUTES && (link_attributes & FILE_ATTRIBUTE_REPARSE_POINT))
            throw std::runtime_error("Persisted source is already a reparse point: "+path_text(link));
        auto store_attributes = GetFileAttributesW(store.c_str());
        if (store_attributes != INVALID_FILE_ATTRIBUTES && (store_attributes & FILE_ATTRIBUTE_REPARSE_POINT))
            throw std::runtime_error("Persisted store target is a reparse point: "+path_text(store));
        bool directory = false;
        if (store_attributes != INVALID_FILE_ATTRIBUTES) {
            directory = (store_attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
            if (!directory && (store_attributes & FILE_ATTRIBUTE_DEVICE))
                throw std::runtime_error("Persisted store target is not a regular file or directory");
            if (link_attributes != INVALID_FILE_ATTRIBUTES) {
                const auto backup = fs::path(link.wstring()+L".original");
                move_path(link,backup,"Persist source backup");
            }
        } else {
            create_directories(store.parent_path(),"Cannot create persisted store directory");
            if (link_attributes != INVALID_FILE_ATTRIBUTES) {
                move_path(link,store,"Persist source migration");
                store_attributes = GetFileAttributesW(store.c_str());
                if (store_attributes == INVALID_FILE_ATTRIBUTES)
                    throw std::runtime_error("Persisted data migration did not create the store target");
                directory = (store_attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
            } else {
                create_directories(store,"Cannot create persisted store directory");
                directory = true;
            }
        }
        create_link(link,store,directory);
    }
    return verify_persistence(context,package,stage_directory);
}
Json verify_persistence(const Context& context, const Package& package, const fs::path& version_directory) {
    require_unique(package);
    Json result = Json::array();
    for (const auto& mapping : package.persistence) {
        const auto resolved = resolve_entry(context,package,mapping,version_directory);
        result.push_back({{"source",path_text(resolved.mapping.source)},{"target",path_text(resolved.mapping.target)},
            {"link",path_text(resolved.link)},{"store",path_text(resolved.store)},
            {"type",resolved.directory ? "junction" : "hardlink"},{"ownership","verified"},{"data_retained",true}});
    }
    return result;
}
bool same_persistence(const Package& a, const Package& b) {
    if (a.persistence.size() != b.persistence.size()) return false;
    std::vector<bool> matched(b.persistence.size(),false);
    for (const auto& left : a.persistence) {
        bool found = false;
        for (std::size_t i = 0; i < b.persistence.size(); ++i) {
            if (matched[i]) continue;
            if (!equal_name(path_text(left.source),path_text(b.persistence[i].source))) continue;
            if (!equal_name(path_text(left.target),path_text(b.persistence[i].target))) continue;
            matched[i] = true;
            found = true;
            break;
        }
        if (!found) return false;
    }
    return true;
}
Json purge_scope(const Context& context, const Package& package, const fs::path& version_directory,
                 const Json& recorded_persistence) {
    require_unique(package);
    if (!recorded_persistence.is_array())
        throw std::runtime_error("Managed persistence ownership record is missing");
    Json result = Json::array();
    for (const auto& mapping : package.persistence) {
        const auto resolved = resolve_entry(context,package,mapping,version_directory);
        const auto recorded = std::find_if(recorded_persistence.begin(),recorded_persistence.end(),[&](const Json& item) {
            return item.is_object() && equal_name(item.value("store",std::string{}),path_text(resolved.store)) &&
                equal_name(item.value("target",std::string{}),path_text(resolved.mapping.target));
        });
        if (recorded == recorded_persistence.end())
            throw std::runtime_error("Managed persistence ownership record is missing for: "+path_text(resolved.store));
        if (recorded->value("ownership",std::string{}) != "verified")
            throw std::runtime_error("Managed persistence ownership was not verified for: "+path_text(resolved.store));
        const auto identity = file_identity(resolved.store,"Persisted store target",resolved.directory);
        result.push_back({{"source",path_text(resolved.mapping.source)},{"target",path_text(resolved.mapping.target)},
            {"store",path_text(resolved.store)},{"link",path_text(resolved.link)},
            {"type",resolved.directory ? "junction" : "hardlink"},{"identity",identity_text(identity)}});
    }
    return result;
}
bool verify_purge_target(const Context& context, const std::string& package_name, const Json& entry) {
    validate_component(package_name);
    const fs::path store(wide(entry.at("store").get<std::string>()));
    const auto base = context.root/L"persist"/wide(package_name);
    const auto relative = store.lexically_relative(base);
    if (relative.empty() || relative.is_absolute() || *relative.begin() == L"..")
        throw std::runtime_error("Purge target is outside the package store: "+path_text(store));
    require_ordinary(context.root,store,false);
    const auto attributes = GetFileAttributesW(store.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES) return false;
    if (attributes & FILE_ATTRIBUTE_REPARSE_POINT)
        throw std::runtime_error("Persisted store became a reparse point; refusing to follow or delete it: "+path_text(store));
    const bool directory = (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
    const auto identity = file_identity(store,"Persisted store target",directory);
    if (identity_text(identity) != entry.value("identity",std::string{}))
        throw std::runtime_error("Persisted store changed after the purge scope was verified: "+path_text(store));
    return true;
}
std::vector<std::string> retained_versions(const Context& context, const std::string& package_name,
                                           const std::string& current_version) {
    std::vector<std::string> result;
    const auto app = context.root/L"apps"/wide(package_name);
    if (!fs::is_directory(app)) return result;
    for (const auto& entry : fs::directory_iterator(app)) {
        if (!entry.is_directory() || entry.path().filename() == L"current") continue;
        const auto version = path_text(entry.path().filename());
        if (equal_name(version,current_version)) continue;
        result.push_back(version);
    }
    std::sort(result.begin(),result.end());
    return result;
}
}
