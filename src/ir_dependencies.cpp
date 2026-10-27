#include "ir.hpp"
#include <algorithm>
#include <cctype>
#include <map>
#include <set>
#include <stdexcept>
#include <string>

// Dependency planning is part of the IR planner: it consumes normalized dependency identity and
// installed facts, and returns separate package plans in topological order. It does not read Scoop
// JSON, interpret source text again or execute anything.
namespace coop::ir {
namespace {
std::string lower(std::string value) {
    for (auto& character : value)
        character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    return value;
}
bool equal(const std::string& a, const std::string& b) {
    return lower(a) == lower(b);
}
std::string join(const std::vector<std::string>& values, const std::string& separator) {
    std::string result;
    for (const auto& value : values) {
        if (!result.empty()) result += separator;
        result += value;
    }
    return result;
}
class Resolver {
public:
    Resolver(const Package& package, const std::vector<InstalledFact>& installed, bool require_installed,
             const DependencySource& source, const DependencyBlocker& blocker)
        : root_(package), require_installed_(require_installed), source_(source), blocker_(blocker) {
        for (const auto& fact : installed) {
            if (!fact.present || fact.name.empty()) continue;
            installed_.emplace(lower(fact.name),fact);
        }
    }
    DependencyResolution resolve() {
        for (const auto& dependency : root_.dependencies) resolve_one(dependency,root_.name);
        // A Manifest may repeat the same dependency declaration. Scoop resolves the declaration
        // list once per package name, so the identical diagnostic is reported once instead of
        // multiplying download attempts or failure text. Diagnostics that differ in layer, code or
        // message (source identity, required-by package, cycle chain) stay separate.
        std::vector<Diagnostic> unique;
        for (auto& diagnostic : diagnostics_) {
            const bool duplicate = std::any_of(unique.begin(),unique.end(),[&](const Diagnostic& seen) {
                return seen.layer == diagnostic.layer && seen.code == diagnostic.code && seen.message == diagnostic.message;
            });
            if (!duplicate) unique.push_back(std::move(diagnostic));
        }
        return {std::move(order_),std::move(unique)};
    }
private:
    void diagnostic(Layer layer, const std::string& code, const std::string& message) {
        diagnostics_.push_back({layer,code,message});
    }
    bool claim_name(const Dependency& spec, const std::string& key) {
        const auto name_key = lower(spec.name);
        const auto found = names_.find(name_key);
        if (found != names_.end() && found->second != key) {
            diagnostic(Layer::validation,"dependency-conflict",
                "Dependency '"+spec.source+"' resolves to multiple sources: "+found->second+" and "+key);
            return false;
        }
        names_[name_key] = key;
        return true;
    }
    bool resolve_one(const Dependency& spec, const std::string& required_by) {
        if (spec.name.empty()) {
            diagnostic(Layer::validation,"dependency-invalid","Dependency name is empty: "+spec.source);
            return false;
        }
        if (!spec.version.empty()) {
            diagnostic(Layer::adapter,"dependency-version",
                "Version-constrained dependency is not supported: "+spec.source);
            return false;
        }
        if (const auto found = installed_.find(lower(spec.name)); found != installed_.end()) {
            const auto& fact = found->second;
            if (!spec.bucket.empty() && !fact.bucket.empty() && !equal(spec.bucket,fact.bucket)) {
                diagnostic(Layer::environment,"dependency-bucket-conflict",
                    "Dependency '"+spec.source+"' is installed from bucket '"+fact.bucket+"' instead of '"+spec.bucket+"'");
                return false;
            }
            const auto bucket = fact.bucket.empty() ? spec.bucket : fact.bucket;
            const auto key = lower(bucket+"/"+fact.name);
            if (!claim_name(spec,key)) return false;
            if (done_.contains(key)) return true;
            done_.insert(key);
            DependencyPlan item;
            item.request = bucket.empty() ? fact.name : bucket+"/"+fact.name;
            item.name = fact.name;
            item.bucket = bucket;
            item.version = fact.version;
            item.installed = true;
            item.installed_version = fact.version;
            item.installed_bucket = fact.bucket;
            order_.push_back(std::move(item));
            return true;
        }
        if (require_installed_) {
            diagnostic(Layer::environment,"dependency-missing",
                "Declared dependency '"+spec.source+"' is not installed");
            return false;
        }
        std::vector<std::string> available;
        try { available = source_.buckets(spec.name); }
        catch (const std::exception& error) {
            diagnostic(Layer::validation,"dependency-invalid",
                "Dependency '"+spec.source+"' cannot be read: "+error.what());
            return false;
        }
        if (available.empty()) {
            diagnostic(Layer::validation,"dependency-missing",
                "Dependency '"+spec.source+"' required by '"+(required_by.empty() ? std::string("the requested package") : required_by)+
                "' is not available in local buckets");
            return false;
        }
        std::vector<std::string> matches;
        for (const auto& bucket : available)
            if (spec.bucket.empty() || equal(spec.bucket,bucket)) matches.push_back(bucket);
        if (matches.empty()) {
            diagnostic(Layer::validation,"dependency-missing",
                "Dependency '"+spec.source+"' required by '"+(required_by.empty() ? std::string("the requested package") : required_by)+
                "' is not available in the selected bucket");
            return false;
        }
        if (matches.size() > 1) {
            diagnostic(Layer::validation,"dependency-ambiguous",
                "Dependency '"+spec.source+"' matches multiple buckets ("+join(matches,", ")+"); qualify it as bucket/name");
            return false;
        }
        const auto bucket = matches.front();
        const auto key = lower(bucket+"/"+spec.name);
        if (done_.contains(key)) return true;
        if (std::find(stack_.begin(),stack_.end(),key) != stack_.end()) {
            std::vector<std::string> chain = stack_;
            chain.push_back(key);
            diagnostic(Layer::validation,"dependency-cycle","Circular dependency detected: "+join(chain," -> "));
            return false;
        }
        if (!claim_name(spec,key)) return false;
        Package candidate;
        try { candidate = source_.load(bucket,spec.name); }
        catch (const std::exception& error) {
            diagnostic(Layer::validation,"dependency-invalid",
                "Dependency '"+spec.source+"' cannot be read: "+error.what());
            return false;
        }
        if (blocker_) {
            const auto blocker = blocker_(candidate);
            if (!blocker.empty()) {
                diagnostic(Layer::capability,"dependency-unsupported",
                    "Dependency '"+spec.source+"' cannot be installed: "+blocker);
                return false;
            }
        }
        stack_.push_back(key);
        bool ok = true;
        for (const auto& child : candidate.dependencies)
            if (!resolve_one(child,candidate.name)) ok = false;
        stack_.pop_back();
        if (!ok) return false;
        done_.insert(key);
        DependencyPlan item;
        item.request = bucket+"/"+spec.name;
        item.name = candidate.name.empty() ? spec.name : candidate.name;
        item.bucket = bucket;
        item.version = candidate.version;
        item.package = candidate;
        item.steps = plan(Action::install,candidate,nullptr,true).steps;
        item.diagnostics = candidate.diagnostics;
        order_.push_back(std::move(item));
        return true;
    }
    const Package& root_;
    bool require_installed_ = false;
    const DependencySource& source_;
    const DependencyBlocker& blocker_;
    std::map<std::string,InstalledFact> installed_;
    std::map<std::string,std::string> names_;
    std::set<std::string> done_;
    std::vector<std::string> stack_;
    std::vector<DependencyPlan> order_;
    std::vector<Diagnostic> diagnostics_;
};
}
DependencyResolution resolve_dependencies(const Package& package, const std::vector<InstalledFact>& installed,
                                          bool require_installed, const DependencySource& source,
                                          const DependencyBlocker& blocker) {
    return Resolver(package,installed,require_installed,source,blocker).resolve();
}
}
