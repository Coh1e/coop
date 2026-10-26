#include "package.hpp"
#include "ir.hpp"
#include "data.hpp"
#include <stdexcept>

// Projection from the package IR to the record the current execution backend and its planning
// helpers consume. All Scoop JSON knowledge lives in ir_adapter.cpp; this file only re-expresses
// normalized IR fields, and stores the IR itself on the record so the planner can consume it
// directly. The legacy record is retired together with the adoption path.
namespace coop {
DiagnosticKind diagnostic_kind(ir::Layer layer) {
    switch (layer) {
    case ir::Layer::syntax: return DiagnosticKind::syntax;
    case ir::Layer::adapter: return DiagnosticKind::adapter;
    case ir::Layer::validation: return DiagnosticKind::validation;
    case ir::Layer::environment: return DiagnosticKind::environment;
    case ir::Layer::capability: return DiagnosticKind::capability;
    case ir::Layer::verification: return DiagnosticKind::verification;
    }
    return DiagnosticKind::validation;
}
namespace {
ArchiveKind legacy_archive(ir::ArchiveFormat format) {
    switch (format) {
    case ir::ArchiveFormat::file: return ArchiveKind::none;
    case ir::ArchiveFormat::zip: return ArchiveKind::zip;
    case ir::ArchiveFormat::seven_zip: return ArchiveKind::seven_zip;
    case ir::ArchiveFormat::tar: return ArchiveKind::tar;
    case ir::ArchiveFormat::msi: return ArchiveKind::msi;
    case ir::ArchiveFormat::inno_setup: return ArchiveKind::inno_setup;
    }
    return ArchiveKind::none;
}
ScriptPhase legacy_phase(ir::HookStage stage) {
    switch (stage) {
    case ir::HookStage::pre_install: return ScriptPhase::before_install;
    case ir::HookStage::installer: return ScriptPhase::installer;
    case ir::HookStage::post_install: return ScriptPhase::after_install;
    case ir::HookStage::pre_uninstall: return ScriptPhase::before_uninstall;
    case ir::HookStage::uninstaller: return ScriptPhase::uninstaller;
    case ir::HookStage::post_uninstall: return ScriptPhase::after_uninstall;
    }
    return ScriptPhase::before_install;
}
Package project(const ir::Package& definition) {
    Package package;
    package.name = definition.name;
    package.bucket = definition.bucket;
    package.version = definition.version;
    package.architecture = definition.architecture;
    package.manifest_path = fs::path(wide(definition.manifest_path));
    package.manifest_sha256 = definition.manifest_digest;
    for (const auto& item : definition.downloads) {
        Artifact artifact;
        artifact.url = item.url;
        artifact.filename = item.filename;
        artifact.digest = item.digest.value;
        artifact.algorithm = item.digest.algorithm;
        artifact.renamed = item.renamed;
        artifact.archive = legacy_archive(item.format);
        if (!item.extract_directory.empty()) artifact.extract_directory = fs::path(wide(item.extract_directory));
        if (!item.extract_destination.empty()) artifact.extract_destination = fs::path(wide(item.extract_destination));
        package.artifacts.push_back(std::move(artifact));
    }
    for (const auto& item : definition.dependencies) package.dependencies.push_back(item.source);
    for (const auto& item : definition.entries)
        package.commands.push_back({fs::path(wide(item.target)),item.alias,item.arguments});
    for (const auto& item : definition.shortcuts)
        package.shortcuts.push_back({fs::path(wide(item.target)),item.name,item.arguments,
            item.icon.empty() ? fs::path() : fs::path(wide(item.icon))});
    for (const auto& item : definition.persistence)
        package.persistence.push_back({fs::path(wide(item.source)),fs::path(wide(item.target))});
    for (const auto& item : definition.environment) {
        if (item.path_entry) package.path_entries.push_back(fs::path(wide(item.value)));
        else package.environment.push_back({item.variable,item.value});
    }
    for (const auto& item : definition.hooks) package.scripts.push_back({legacy_phase(item.stage),item.text,item.declared_by});
    const auto program = [](const ir::InstallerProgram& item) {
        return InstallerProcess{fs::path(wide(item.file)),item.arguments,item.keep};
    };
    if (definition.installer) package.installer = program(*definition.installer);
    if (definition.uninstaller) package.uninstaller = program(*definition.uninstaller);
    for (const auto& item : definition.diagnostics)
        package.diagnostics.push_back({diagnostic_kind(item.layer),item.code,item.message});
    package.definition = std::make_shared<const ir::Package>(definition);
    return package;
}
}
Package project_package(const ir::Package& definition) {
    return project(definition);
}
Package parse_package(const fs::path& path, const std::string& name, const std::string& bucket,
                      const std::string& architecture) {
    auto definition = ir::adapt_manifest(path,name,bucket,architecture);
    ir::validate(definition);
    try {
        return project(definition);
    } catch (const std::exception& error) {
        Package package;
        package.name = definition.name;
        package.bucket = definition.bucket;
        package.version = definition.version;
        package.architecture = definition.architecture;
        package.manifest_path = path;
        package.manifest_sha256 = definition.manifest_digest;
        package.diagnostics.push_back({DiagnosticKind::adapter,"manifest-shape",error.what()});
        package.definition = std::make_shared<const ir::Package>(definition);
        return package;
    }
}
}
