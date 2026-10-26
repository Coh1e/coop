#include "user_environment.hpp"
#include <windows.h>
#include <algorithm>
#include <cctype>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

// The current user's environment is the actual interface used by a new terminal, Explorer and
// shortcuts. Coop therefore changes HKCU\Environment instead of only injecting variables into a
// launcher child, and it keeps the raw value/kind it replaced so a later update or uninstall can
// distinguish its own write from a value the user changed afterwards.
namespace coop {
namespace {
constexpr wchar_t environment_key_name[] = L"Environment";
constexpr wchar_t environment_broadcast[] = L"Environment";

struct RegistryKey {
    HKEY value = nullptr;
    explicit RegistryKey(REGSAM access) {
        const auto status = RegOpenKeyExW(HKEY_CURRENT_USER,environment_key_name,0,access,&value);
        if (status != ERROR_SUCCESS || value == nullptr) {
            value = nullptr;
            throw std::runtime_error("Cannot open HKCU\\Environment (Windows error "+std::to_string(status)+")");
        }
    }
    ~RegistryKey() { if (value) RegCloseKey(value); }
    RegistryKey(const RegistryKey&) = delete;
    RegistryKey& operator=(const RegistryKey&) = delete;
};

struct RawValue {
    bool present = false;
    DWORD type = REG_SZ;
    std::string value;
};

std::string lower(std::string text) {
    for (auto& character : text)
        character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    return text;
}
bool name_equal(const std::string& left, const std::string& right) {
    return CompareStringOrdinal(wide(left).c_str(),-1,wide(right).c_str(),-1,TRUE) == CSTR_EQUAL;
}
RawValue read_value(const std::string& name) {
    RegistryKey key(KEY_QUERY_VALUE);
    const auto wide_name = wide(name);
    DWORD type = 0;
    DWORD size = 0;
    auto status = RegQueryValueExW(key.value,wide_name.c_str(),nullptr,&type,nullptr,&size);
    if (status == ERROR_FILE_NOT_FOUND) return {};
    if (status != ERROR_SUCCESS)
        throw std::runtime_error("Cannot read the user environment value "+name+" (Windows error "+std::to_string(status)+")");
    if (type != REG_SZ && type != REG_EXPAND_SZ)
        throw std::runtime_error("The user environment value "+name+" is not a string or expandable string");
    if (size % sizeof(wchar_t) != 0)
        throw std::runtime_error("The user environment value "+name+" has an invalid size");
    std::vector<wchar_t> buffer(size/sizeof(wchar_t)+1,L'\0');
    status = RegQueryValueExW(key.value,wide_name.c_str(),nullptr,&type,
        reinterpret_cast<LPBYTE>(buffer.data()),&size);
    if (status != ERROR_SUCCESS)
        throw std::runtime_error("Cannot read the user environment value "+name+" (Windows error "+std::to_string(status)+")");
    std::wstring text(buffer.data(),size/sizeof(wchar_t));
    while (!text.empty() && text.back() == L'\0') text.pop_back();
    RawValue result;
    result.present = true;
    result.type = type;
    result.value = utf8(text);
    return result;
}
void write_value(const std::string& name, const RawValue& value) {
    RegistryKey key(KEY_SET_VALUE);
    const auto wide_name = wide(name);
    if (!value.present) {
        const auto status = RegDeleteValueW(key.value,wide_name.c_str());
        if (status == ERROR_FILE_NOT_FOUND) return;
        if (status != ERROR_SUCCESS)
            throw std::runtime_error("Cannot delete the user environment value "+name+" (Windows error "+std::to_string(status)+")");
        return;
    }
    const auto data = wide(value.value);
    const auto bytes = (data.size()+1)*sizeof(wchar_t);
    const auto status = RegSetValueExW(key.value,wide_name.c_str(),0,value.type,
        reinterpret_cast<const BYTE*>(data.c_str()),static_cast<DWORD>(bytes));
    if (status != ERROR_SUCCESS)
        throw std::runtime_error("Cannot write the user environment value "+name+" (Windows error "+std::to_string(status)+")");
}
const char* kind_name(DWORD type) { return type == REG_EXPAND_SZ ? "ExpandString" : "String"; }
DWORD kind_type(const std::string& kind, const std::string& name) {
    if (kind.empty() || kind == "String") return REG_SZ;
    if (kind == "ExpandString") return REG_EXPAND_SZ;
    throw std::runtime_error("The user environment record for "+name+" has an unsupported value kind: "+kind);
}
Json raw_json(const RawValue& value) {
    return {{"present",value.present},{"kind",kind_name(value.type)},{"value",value.value}};
}
RawValue raw_from_json(const Json& value, const std::string& name) {
    if (!value.is_object()) throw std::runtime_error("The user environment record for "+name+" is not an object");
    RawValue result;
    result.present = value.value("present",false);
    if (!result.present) return result;
    result.type = kind_type(value.value("kind",std::string("String")),name);
    result.value = value.value("value",std::string{});
    return result;
}
bool same_value(const RawValue& left, const RawValue& right, bool path_compare = false) {
    if (left.present != right.present) return false;
    if (!left.present) return true;
    if (!path_compare) return left.value == right.value;
    auto normalize = [](std::string text) {
        for (auto& character : text) if (character == '/') character = '\\';
        while (text.size() > 1 && text.back() == '\\') text.pop_back();
        return text;
    };
    const auto a = normalize(left.value);
    const auto b = normalize(right.value);
    return CompareStringOrdinal(wide(a).c_str(),-1,wide(b).c_str(),-1,TRUE) == CSTR_EQUAL;
}
DWORD value_type(const RawValue& current, const std::string& value) {
    // Scoop uses an expandable string whenever the new value contains %, otherwise it keeps the
    // existing registry kind. Matching that rule keeps %LOCALAPPDATA%-style values expandable.
    if (value.find('%') != std::string::npos) return REG_EXPAND_SZ;
    if (current.present && (current.type == REG_SZ || current.type == REG_EXPAND_SZ)) return current.type;
    return REG_SZ;
}
RawValue desired_value(const RawValue& current, const std::string& value) {
    RawValue result;
    result.present = !value.empty();
    result.type = value_type(current,value);
    result.value = value;
    return result;
}
std::vector<std::string> split_path(const std::string& value) {
    std::vector<std::string> result;
    std::size_t start = 0;
    while (start <= value.size()) {
        const auto separator = value.find(';',start);
        const auto end = separator == std::string::npos ? value.size() : separator;
        auto entry = value.substr(start,end-start);
        if (!entry.empty()) result.push_back(std::move(entry));
        if (separator == std::string::npos) break;
        start = separator+1;
    }
    return result;
}
std::string join_path(const std::vector<std::string>& entries) {
    std::string result;
    for (const auto& entry : entries) {
        if (!result.empty()) result += ';';
        result += entry;
    }
    return result;
}
bool path_equal(const std::string& left, const std::string& right) {
    auto normalize = [](std::string text) {
        for (auto& character : text) if (character == '/') character = '\\';
        while (text.size() > 1 && text.back() == '\\') text.pop_back();
        return text;
    };
    const auto a = normalize(left);
    const auto b = normalize(right);
    return CompareStringOrdinal(wide(a).c_str(),-1,wide(b).c_str(),-1,TRUE) == CSTR_EQUAL;
}
bool contains_path(const std::vector<std::string>& entries, const std::string& value) {
    return std::any_of(entries.begin(),entries.end(),[&](const std::string& entry) { return path_equal(entry,value); });
}
void erase_path(std::vector<std::string>& entries, const std::string& value) {
    entries.erase(std::remove_if(entries.begin(),entries.end(),[&](const std::string& entry) {
        return path_equal(entry,value);
    }),entries.end());
}
std::vector<std::string> unique_path(const std::vector<std::string>& entries) {
    std::vector<std::string> result;
    for (const auto& entry : entries)
        if (!contains_path(result,entry)) result.push_back(entry);
    return result;
}
void add_record(Json& array, Json value) {
    if (!array.is_array()) array = Json::array();
    array.push_back(std::move(value));
}
void add_write(Json& writes, const std::string& name, const RawValue& before, const RawValue& after,
               const std::string& reason) {
    add_record(writes,{{"name",name},{"before",raw_json(before)},{"after",raw_json(after)},{"reason",reason}});
}
void add_undo(Json& undo, const std::string& name, const RawValue& before, const RawValue& expected) {
    add_record(undo["values"],{{"name",name},{"before",raw_json(before)},{"after",raw_json(expected)}});
}
void add_preserved(Json& preserved, const std::string& name, const RawValue& expected,
                   const RawValue& observed, const std::string& reason) {
    add_record(preserved,{{"name",name},{"expected",raw_json(expected)},
        {"observed",raw_json(observed)},{"reason",reason}});
}
void maybe_write(const std::string& name, const RawValue& before, const RawValue& after,
                 Json& writes, Json& undo, bool& changed, const std::string& reason) {
    if (same_value(before,after)) return;
    write_value(name,after);
    add_write(writes,name,before,after,reason);
    add_undo(undo,name,before,after);
    changed = true;
}
Json broadcast(bool changed) {
    Json result = {{"message","WM_SETTINGCHANGE"},{"parameter","Environment"},{"attempted",changed}};
    if (!changed) {
        result["sent"] = false;
        result["reason"] = "No user environment value changed";
        return result;
    }
    DWORD_PTR response = 0;
    SetLastError(ERROR_SUCCESS);
    const auto sent = SendMessageTimeoutW(HWND_BROADCAST,WM_SETTINGCHANGE,0,
        reinterpret_cast<LPARAM>(environment_broadcast),SMTO_ABORTIFHUNG|SMTO_BLOCK,5000,&response);
    result["sent"] = sent != 0;
    result["response"] = static_cast<unsigned long long>(response);
    if (!sent) result["last_error"] = static_cast<unsigned long>(GetLastError());
    return result;
}
Json result_object(Json ownership, Json undo, Json writes, Json preserved, bool changed) {
    return {{"scope","HKCU\\Environment"},
        {"mechanism","current-user registry values with an Environment setting-change broadcast"},
        {"ownership",std::move(ownership)},{"undo",std::move(undo)},{"writes",std::move(writes)},
        {"preserved",std::move(preserved)},{"broadcast",broadcast(changed)}};
}
// Revert one owned PATH value. If the user changed PATH since Coop wrote it, only the entries Coop
// actually added are removed; every other entry and its order is left alone.
void revert_path(const Json& prior, Json& writes, Json& undo, Json& preserved, bool& changed) {
    if (!prior.is_object() || !prior.contains("applied")) return;
    const auto applied = raw_from_json(prior.at("applied"),"Path");
    if (!applied.present) return;
    const auto current = read_value("Path");
    const auto previous = prior.contains("previous") ? raw_from_json(prior.at("previous"),"Path") : RawValue{};
    if (same_value(current,applied)) {
        maybe_write("Path",current,previous,writes,undo,changed,"restore the user PATH value recorded before Coop");
        return;
    }
    auto entries = split_path(current.value);
    const auto added = prior.contains("added") && prior.at("added").is_array() ? prior.at("added") : Json::array();
    for (const auto& entry : added)
        if (entry.is_string()) erase_path(entries,entry.get<std::string>());
    const auto remaining = join_path(entries);
    RawValue updated = current;
    updated.value = remaining;
    maybe_write("Path",current,updated,writes,undo,changed,"remove only the PATH entries Coop added; user changes are preserved");
    add_preserved(preserved,"Path",applied,current,
        "PATH differs from the value Coop wrote; user entries and their order are preserved");
}
void revert_variables(const Json& prior, Json& writes, Json& undo, Json& preserved, bool& changed) {
    if (!prior.is_object() || !prior.contains("variables") || !prior.at("variables").is_array()) return;
    for (const auto& variable : prior.at("variables")) {
        if (!variable.is_object() || !variable.contains("name") || !variable.at("name").is_string()) continue;
        const auto name = variable.at("name").get<std::string>();
        if (!variable.contains("applied")) continue;
        const auto applied = raw_from_json(variable.at("applied"),name);
        const auto previous = variable.contains("previous") ? raw_from_json(variable.at("previous"),name) : RawValue{};
        const auto current = read_value(name);
        if (same_value(current,applied)) {
            maybe_write(name,current,previous,writes,undo,changed,
                "restore the user environment value recorded before Coop wrote it");
        } else {
            add_preserved(preserved,name,applied,current,
                "the user changed this value after Coop wrote it; the newer value is kept");
        }
    }
}
std::vector<std::string> desired_paths(const Json& path_entries) {
    std::vector<std::string> result;
    if (!path_entries.is_array()) return result;
    for (const auto& entry : path_entries)
        if (entry.is_string() && !entry.get<std::string>().empty()) result.push_back(entry.get<std::string>());
    return unique_path(result);
}
}
Json ownership_from_declarations(const Json& environment, const Json& path_entries) {
    if (!environment.is_array()) throw std::runtime_error("Expanded installed environment declarations are not an array");
    Json ownership = {{"scope","HKCU\\Environment"},{"source","installed-declaration"},
        {"variables",Json::array()},{"path",Json(nullptr)}};
    for (const auto& setting : environment) {
        if (!setting.is_object() || !setting.contains("name") || !setting.at("name").is_string() ||
            !setting.contains("value") || !setting.at("value").is_string())
            throw std::runtime_error("Expanded installed environment declaration is invalid");
        const auto name = setting.at("name").get<std::string>();
        const auto current = read_value(name);
        const auto declared = desired_value(current,setting.at("value").get<std::string>());
        // The pre-install value is unknown without a Coop record, so there is nothing to restore;
        // a later removal deletes the value only while it still equals this declaration.
        ownership["variables"].push_back({{"name",name},{"previous",raw_json(RawValue{})},
            {"applied",raw_json(declared)}});
    }
    const auto desired = desired_paths(path_entries);
    if (!desired.empty()) {
        const auto current = read_value("Path");
        auto previous = current;
        auto entries = split_path(current.value);
        for (const auto& entry : desired) erase_path(entries,entry);
        previous.value = join_path(entries);
        ownership["path"] = {{"previous",raw_json(previous)},{"applied",raw_json(current)},{"added",desired}};
    }
    return ownership;
}
Json apply_user_environment(const Json& environment, const Json& path_entries, const Json& previous_ownership) {
    if (!environment.is_array()) throw std::runtime_error("Expanded user environment declarations are not an array");
    if (!previous_ownership.is_null() && !previous_ownership.is_object())
        throw std::runtime_error("The stored user environment ownership record is invalid");
    Json undo = {{"values",Json::array()}};
    try {
    Json writes = Json::array();
    Json preserved = Json::array();
    Json ownership = {{"scope","HKCU\\Environment"},{"variables",Json::array()},{"path",Json(nullptr)}};
    bool changed = false;
    const auto prior_variables = previous_ownership.is_object() && previous_ownership.contains("variables") &&
        previous_ownership.at("variables").is_array() ? previous_ownership.at("variables") : Json::array();
    std::set<std::string> declared_names;
    for (const auto& setting : environment) {
        if (!setting.is_object() || !setting.contains("name") || !setting.at("name").is_string() ||
            !setting.contains("value") || !setting.at("value").is_string())
            throw std::runtime_error("Expanded user environment declaration is invalid");
        const auto name = setting.at("name").get<std::string>();
        if (name.empty() || name.find('=') != std::string::npos)
            throw std::runtime_error("Invalid user environment variable name");
        if (!declared_names.insert(lower(name)).second)
            throw std::runtime_error("Duplicate user environment variable declaration: "+name);
        const auto desired_text = setting.at("value").get<std::string>();
        const auto current = read_value(name);
        const auto prior = std::find_if(prior_variables.begin(),prior_variables.end(),[&](const Json& item) {
            return item.is_object() && item.contains("name") && item.at("name").is_string() &&
                name_equal(item.at("name").get<std::string>(),name);
        });
        if (prior != prior_variables.end()) {
            const auto prior_applied = prior->contains("applied") ? raw_from_json(prior->at("applied"),name) : RawValue{};
            if (!same_value(current,prior_applied)) {
                ownership["variables"].push_back(*prior);
                add_preserved(preserved,name,prior_applied,current,
                    "the user changed this value after Coop wrote it; the newer value is kept");
                continue;
            }
            const auto desired = desired_value(current,desired_text);
            maybe_write(name,current,desired,writes,undo,changed,
                "replace the value this package previously wrote; the pre-Coop value is retained");
            Json entry = {{"name",name},
                {"previous",prior->contains("previous") ? prior->at("previous") : raw_json(current)},
                {"applied",raw_json(desired)}};
            ownership["variables"].push_back(std::move(entry));
            continue;
        }
        const auto desired = desired_value(current,desired_text);
        maybe_write(name,current,desired,writes,undo,changed,
            "write the declared user environment value and retain the previous value");
        ownership["variables"].push_back({{"name",name},{"previous",raw_json(current)},{"applied",raw_json(desired)}});
    }
    // Declarations the installed package owned but the new manifest no longer declares are
    // reverted in this same reconcile, so an update cannot leave stale package values behind.
    for (const auto& variable : prior_variables) {
        if (!variable.is_object() || !variable.contains("name") || !variable.at("name").is_string()) continue;
        const auto name = variable.at("name").get<std::string>();
        if (declared_names.contains(lower(name))) continue;
        if (!variable.contains("applied")) continue;
        const auto applied = raw_from_json(variable.at("applied"),name);
        const auto previous = variable.contains("previous") ? raw_from_json(variable.at("previous"),name) : RawValue{};
        const auto current = read_value(name);
        if (same_value(current,applied)) {
            maybe_write(name,current,previous,writes,undo,changed,
                "revert a declaration the updated package no longer owns");
        } else {
            add_preserved(preserved,name,applied,current,
                "the user changed this value after Coop wrote it; the newer value is kept");
        }
    }
    const auto desired = desired_paths(path_entries);
    const auto prior_path = previous_ownership.is_object() && previous_ownership.contains("path") &&
        previous_ownership.at("path").is_object() ? previous_ownership.at("path") : Json(nullptr);
    const auto current_path = read_value("Path");
    if (desired.empty()) {
        if (!prior_path.is_null()) revert_path(prior_path,writes,undo,preserved,changed);
    } else {
        std::vector<std::string> base_entries;
        std::vector<std::string> prepend_entries = desired;
        std::vector<std::string> added;
        RawValue previous_raw = current_path;
        if (prior_path.is_null()) {
            // Fresh install: match Scoop by removing duplicates of the declared entries and
            // prepending them, while retaining the complete pre-Coop value for restoration.
            base_entries = split_path(current_path.value);
            for (const auto& entry : desired)
                if (!contains_path(base_entries,entry)) added.push_back(entry);
            for (const auto& entry : desired) erase_path(base_entries,entry);
        } else {
            const auto applied = prior_path.contains("applied") ? raw_from_json(prior_path.at("applied"),"Path") : RawValue{};
            if (same_value(current_path,applied)) {
                previous_raw = prior_path.contains("previous") ? raw_from_json(prior_path.at("previous"),"Path") : current_path;
                base_entries = split_path(previous_raw.value);
                for (const auto& entry : desired)
                    if (!contains_path(base_entries,entry)) added.push_back(entry);
                for (const auto& entry : desired) erase_path(base_entries,entry);
            } else {
                // The user changed PATH after Coop wrote it. Remove only entries Coop itself
                // added from the value a later uninstall restores, keep every user entry and its
                // order, then prepend declared entries that are missing.
                base_entries = split_path(current_path.value);
                const auto prior_added = prior_path.contains("added") && prior_path.at("added").is_array() ?
                    prior_path.at("added") : Json::array();
                for (const auto& entry : prior_added)
                    if (entry.is_string()) erase_path(base_entries,entry.get<std::string>());
                previous_raw = current_path;
                previous_raw.value = join_path(base_entries);
                prepend_entries.clear();
                for (const auto& entry : desired) {
                    if (contains_path(base_entries,entry)) continue;
                    prepend_entries.push_back(entry);
                    added.push_back(entry);
                }
                add_preserved(preserved,"Path",applied,current_path,
                    "PATH differs from the value Coop wrote; user entries and their order are preserved");
            }
        }
        std::vector<std::string> updated_entries = prepend_entries;
        updated_entries.insert(updated_entries.end(),base_entries.begin(),base_entries.end());
        RawValue updated = current_path;
        updated.present = true;
        updated.type = value_type(current_path,join_path(updated_entries));
        updated.value = join_path(updated_entries);
        maybe_write("Path",current_path,updated,writes,undo,changed,
            "prepend the declared PATH entries and retain the existing user PATH");
        ownership["path"] = {{"previous",raw_json(previous_raw)},{"applied",raw_json(updated)},
            {"added",added}};
    }
    return result_object(std::move(ownership),std::move(undo),std::move(writes),std::move(preserved),changed);
    } catch (...) {
        try { restore_user_environment(undo); } catch (...) { /* The original failure remains authoritative. */ }
        throw;
    }
}
Json revert_user_environment(const Json& previous_ownership) {
    if (previous_ownership.is_null()) {
        Json undo = {{"values",Json::array()}};
        return result_object(Json(nullptr),std::move(undo),Json::array(),Json::array(),false);
    }
    if (!previous_ownership.is_object())
        throw std::runtime_error("The stored user environment ownership record is invalid");
    Json undo = {{"values",Json::array()}};
    try {
    Json writes = Json::array();
    Json preserved = Json::array();
    bool changed = false;
    revert_variables(previous_ownership,writes,undo,preserved,changed);
    if (previous_ownership.contains("path") && previous_ownership.at("path").is_object())
        revert_path(previous_ownership.at("path"),writes,undo,preserved,changed);
    return result_object(Json(nullptr),std::move(undo),std::move(writes),std::move(preserved),changed);
    } catch (...) {
        try { restore_user_environment(undo); } catch (...) { /* The original failure remains authoritative. */ }
        throw;
    }
}
namespace {
Json apply_undo(const Json& undo, bool write) {
    Json result = {{"status","nothing-to-restore"},{"writes",Json::array()},{"preserved",Json::array()}};
    if (!undo.is_object() || !undo.contains("values") || !undo.at("values").is_array()) return result;
    bool changed = false;
    for (const auto& item : undo.at("values")) {
        if (!item.is_object() || !item.contains("name") || !item.at("name").is_string() ||
            !item.contains("before") || !item.contains("after")) continue;
        const auto name = item.at("name").get<std::string>();
        const auto before = raw_from_json(item.at("before"),name);
        const auto expected = raw_from_json(item.at("after"),name);
        const auto current = read_value(name);
        if (!same_value(current,expected)) {
            add_preserved(result["preserved"],name,expected,current,
                "the value changed during the transaction; rollback kept the newer value");
            continue;
        }
        if (same_value(current,before)) continue;
        if (!write) {
            result["status"] = "would-restore";
            add_write(result["writes"],name,current,before,"transaction rollback");
            continue;
        }
        write_value(name,before);
        add_write(result["writes"],name,current,before,"transaction rollback");
        changed = true;
    }
    if (changed) result["status"] = "restored";
    result["broadcast"] = write ? broadcast(changed) : Json{{"message","WM_SETTINGCHANGE"},
        {"parameter","Environment"},{"attempted",false},{"sent",false},
        {"reason","Preview only; no registry value was written"}};
    return result;
}
}
Json restore_user_environment(const Json& undo) {
    return apply_undo(undo,true);
}
// Recovery previews the same undo evidence without touching HKCU. It reports exactly which
// values would be restored and which newer user values would be preserved.
Json preview_user_environment_undo(const Json& undo) {
    return apply_undo(undo,false);
}
}
