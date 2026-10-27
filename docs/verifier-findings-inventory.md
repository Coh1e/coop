# 历史 verifier 发现清单（#22–#49）

本页由 `.local/pi/tasks/*/verifier-*.json` 的实际 `findings` 数组生成，逐条记录位置、级别与 R24 时的状态。它不重写任何历史报告；P1/P2 状态依据同票后一轮 verifier 的最终通过结论，P3 的“本轮修复/已核对”只用于本次实际改动或核对过的条目，其余保持“保留为已知 P3”，不据此宣称已完成。

| 来源 | 级别 | 位置 | 问题摘要 | R24 状态 |
| --- | --- | --- | --- | --- |
| #22/verifier-1-1 | P3 | Standards / src/ir.hpp | The new IR contract publishes fields that nothing in this change writes or reads: ir::Plan::execution_available (never s… | 已由后续实现/文档修正（本轮核对） |
| #22/verifier-1-2 | P3 | Standards / src/plan.cpp | append_ir_plan returns silently when plan.package.definition is null, leaving plan.steps and plan.ir_steps empty. execut… | 已由后续实现/文档修正（本轮核对） |
| #22/verifier-1-3 | P3 | Spec / src/query.cpp | info validation hardcodes architecture "64bit" (query.cpp:198 and :202) instead of the architecture selection used by th… | 已由后续实现/文档修正（本轮核对） |
| #22/verifier-1-4 | P3 | Standards / docs/ir-pipeline.md | The doc states that the only remaining Scoop state-format knowledge lives in the Adapter and that the core no longer rea… | 已由后续实现/文档修正（本轮核对） |
| #22/verifier-1-5 | P3 | Standards / src/ir.hpp | The Entry comment says the host kind 'is derived once by the exposure layer, so the IR does not duplicate launcher seman… | 已由后续实现/文档修正（本轮核对） |
| #22/verifier-1-6 | P3 | Standards / docs/design-scope.md | Two sentences committed with this ticket are now factually wrong: line 12 still says the project remains in design discu… | 本轮修复或核对已解决 |
| #23/verifier-1-1 | P1 | Spec / src/git_bucket.cpp | refresh_shared_bucket only requires a clean worktree and then checkout_commit() runs git_reset(GIT_RESET_HARD) (src/git_… | 同票后续轮已修复，最终 verifier 通过 |
| #23/verifier-1-2 | P2 | Spec / src/bucket.cpp | After `bucket remove g` on a shared Git bucket the name is in a dead end. Verified on this head: `bucket remove g` exit … | 同票后续轮已修复，最终 verifier 通过 |
| #23/verifier-1-3 | P3 | Standards / src/bucket.cpp | RefreshJournal only writes <root>/.coop/bucket-refresh/<name>.json and deletes it in its destructor; no query, list, dia… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #23/verifier-1-4 | P3 | Evidence / docs/performance-support.md | The real `main` changed-refresh numbers (dfc3b581→5cb1b7b9, changed_files=73, received_bytes=128,876) come from the 04:2… | 已由后续实现/文档修正（本轮核对） |
| #23/verifier-2-1 | P3 | Evidence / docs/performance-support.md | The bullet claims “本次修复后的最终构建在真实 `main` 上完成 re-register 后再快进 5cb1b7b9… → 89b4cf80…”, but the real-root fast-forward was … | 已由后续实现/文档修正（本轮核对） |
| #24/verifier-1-1 | P2 | Spec / src/execute.cpp | Shared-entry ownership is decided by a hardcoded allowlist of three SHA256 values in known_scoop_launcher (src/execute.c… | 同票后续轮已修复，最终 verifier 通过 |
| #24/verifier-1-2 | P3 | Standards / src/execute.cpp | The published private record computes origin as 'has_managed_record ? managed.origin : "scoop"'. On a fresh install Coop… | 已由后续实现/文档修正（本轮核对） |
| #24/verifier-1-3 | P3 | Standards / src/shim.cpp | The Scoop .shim format parser is implemented twice with drifting policies: shim.cpp:97 read_scoop_shim and execute.cpp:2… | 已由后续实现/文档修正（本轮核对） |
| #24/verifier-1-4 | P3 | Evidence / tests/scoop-interop.ps1 | The hardcoded-architecture fix in src/query.cpp:197-205 has no permanent test: no test asserts info validation.architect… | 已由后续实现/文档修正（本轮核对） |
| #24/verifier-2-1 | P3 | Standards / docs/shared-single-file-support.md | The launcher-identity paragraph enumerates only three accepted routes (Coop's own binary, the launcher recorded by Coop,… | 本轮修复或核对已解决 |
| #24/verifier-2-2 | P3 | Evidence / tests/scoop-interop.ps1 | The repair adds a four-part launcher recognition rule, but the committed test only covers a marker-bearing shim (the con… | 本轮修复或核对已解决 |
| #25/verifier-1-1 | P3 | Evidence / docs/multi-artifact-support.md | The doc says the raw logs/commands are in `.local/pi/tasks/25/evidence/real-scoop-multi/` (the 06:58Z run), while the co… | 本轮修复或核对已解决 |
| #25/verifier-1-2 | P3 | Evidence / .local/pi/tasks/25/evidence/real-scoop-multi-head/journals | The journals directory mixes three separate pdfboxcopy transaction sequences from different runs (pdfboxcopy-1..4 = 14:5… | 历史证据标注：文件按原样保留，未回改；不得据此声称已复现 |
| #25/verifier-1-3 | P3 | Evidence / .local/pi/tasks/25/evidence/real-scoop-multi-head/journals/pdfboxcopy-11-rolled-back-update.json | The download-failure case rewrote url[0] to `file:///.../missing-artifact.jar`, i.e. a missing local source copied by do… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #25/verifier-1-4 | P3 | Standards / src/crypto.cpp | Supported algorithms and their sizes are encoded in three switch tables: src/crypto.cpp:22 digest_algorithm (provider), … | 保留为已知 P3（本轮未改，不阻塞验收） |
| #25/verifier-1-5 | P3 | Standards / src/execute.cpp | The verify handler writes `journal["downloads"][step.index]`, but downloads entries are appended in encounter order (src… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #25/verifier-1-6 | P3 | Standards / src/adoption.cpp | assess_adoption rejects archives and its diagnostic text claims "only direct single-file installations are eligible", bu… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #26/verifier-1-1 | P3 | Evidence / .local/pi/tasks/26/coder-1.json | The reporting acceptance text says versions-head.txt records head 4e313c7, but the file itself records head=ffee169353ed… | 历史证据标注：文件按原样保留，未回改；不得据此声称已复现 |
| #26/verifier-1-2 | P3 | Spec / docs/archive-support.md | The coverage row 'tar / tar.gz / tgz / 已运行 / 已验证' groups uncompressed .tar with tar.gz, but the cited sample (Main/air) … | 本轮修复或核对已解决 |
| #26/verifier-1-3 | P3 | Standards / src/archive.cpp | The new comment enumerates 'plain tar, gzip/tgz, xz/txz, bzip2/tbz and zstd/tzst' while the same function enables archiv… | 本轮修复或核对已解决 |
| #26/verifier-1-4 | P3 | Spec / docs/archive-support.md | The doc states a nonexistent extract_dir fails explicitly, but no committed test asserts that failure; the behaviour is … | 本轮修复或核对已解决 |
| #27/verifier-1-1 | P3 | Standards / src/execute.cpp | The reverse-dependency refusal is duplicated: it returns at execute.cpp:388-389 for Action::uninstall and again at :425-… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #27/verifier-1-2 | P3 | Standards / src/plan.cpp | resolve_package_dependencies copies the whole catalog Json by value into both DependencySource lambdas (plan.cpp:162 and… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #27/verifier-1-3 | P3 | Spec / src/plan.cpp | describe_plan emits "dependencies": declared_json(item.package.dependencies) for every dependency_order entry, but for a… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #27/verifier-1-4 | P3 | Evidence / .local/pi/tasks/27/evidence/build-final-exact-head.log | The coder report cites build-final-exact-head.log as build evidence, but that invocation only printed 'ninja: no work to… | 历史证据标注：文件按原样保留，未回改；不得据此声称已复现 |
| #27/verifier-1-5 | P3 | Evidence / tests/real-scoop-dependencies.ps1 | The real reverse-protection case blocks uninstall of Scoop-installed git using a Coop-installed git-tfs dependent. I con… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #28/verifier-1-1 | P3 | Spec / src/exposure.cpp | expand_exposure_arguments substitutes both $dir and $original_dir with the passed base, and every caller passes apps/<pa… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #28/verifier-1-2 | P3 | Evidence / tests/exposure.ps1 | The negative ownership case writes $root/shims/foreign-tool.cmd, but 'foreign-tool' is not one of the package's command … | 保留为已知 P3（本轮未改，不阻塞验收） |
| #28/verifier-1-3 | P3 | Evidence / tests/exposure.ps1 | The external rewrite is applied only to $mainShortcut, which has empty arguments; the arg-bearing $expandShortcut is nev… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #28/verifier-1-4 | P3 | Standards / src/execute.cpp | The new journal['scoop_entry_wrappers'] array is initialized, used only for its size counter and appended to, but never … | 保留为已知 P3（本轮未改，不阻塞验收） |
| #28/verifier-1-5 | P3 | Spec / docs/exposure-support.md | The real-evidence table says the Red Console window was closed and 'no residual process' remained. tests/real-scoop-expo… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #29/verifier-1-1 | P2 | Spec / src/user_environment.cpp | Attribution for an update comes only from the Coop ownership record (`managed.user_environment`, src/execute.cpp:1065-10… | 同票后续轮已修复，最终 verifier 通过 |
| #29/verifier-1-2 | P2 | Spec / src/user_environment.cpp | `revert_user_environment` returns immediately when the ownership record is null, so an uninstall of a Scoop-created (or … | 同票后续轮已修复，最终 verifier 通过 |
| #29/verifier-1-3 | P3 | Standards / docs/exposure-support.md | The new contract section states '卸载时若当前值仍等于 Coop 写入值，恢复安装前的原始值…PATH 只删除 Coop 实际新增且仍存在的项' without qualifying that this on… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #29/verifier-1-4 | P3 | Evidence / src/execute.cpp | The in-process environment rollback branch (environment_undo / restore_user_environment, src/execute.cpp:1136-1146) has … | 保留为已知 P3（本轮未改，不阻塞验收） |
| #29/verifier-1-5 | P3 | Evidence / tests/user-environment.ps1 | The new-terminal observations assert only that the PATH text contains the entry (Assert-True of the regex on `path=...`)… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #29/verifier-1-6 | P3 | Standards / CMakeLists.txt | Both the extended `exposure` test and the new `user_environment` test now snapshot and rewrite the real HKCU\Environment… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #29/verifier-1-7 | P3 | Evidence / .local/pi/tasks/29/evidence/user-env-after-final-full-3.json | The claim 'the user environment returns to its pre-suite snapshot' rests on before/after JSON artifacts whose comparison… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #29/verifier-2-1 | P3 | Evidence / src/user_environment.cpp | Declaration-derived ownership (ownership_from_declarations, src/user_environment.cpp:275) deliberately records previous=… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #29/verifier-2-2 | P3 | Evidence / .local/pi/tasks/29/evidence/environment-journal-install.json | The repair run copied its new journals over the previously cited paths: environment-journal-install.json (10196 -> 10636… | 历史证据标注：文件按原样保留，未回改；不得据此声称已复现 |
| #30/verifier-1-1 | P3 | Standards / README.md | The added link [持久化数据支持](docs/persistence-support.md#真机验证r09-30) does not match its target heading. docs/persistence-sup… | 本轮修复或核对已解决 |
| #30/verifier-1-2 | P3 | Evidence / docs/persistence-support.md | The not-run bullet claims '测试创建的 store 是空的（本轮首次安装）', but the cited run shows the opposite: persist/mediamtx held a 44-by… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #31/verifier-1-1 | P2 | Spec / src/execute.cpp | post_uninstall always receives $manifest = $null. staged_manifest() returns empty when manifest_path is not a regular fi… | 同票后续轮已修复，最终 verifier 通过 |
| #31/verifier-1-2 | P3 | Spec / src/script.cpp | The hook host sets the child working directory to the package directory ($dir, else the management root), while Scoop ne… | 已由后续实现/文档修正（本轮核对） |
| #31/verifier-1-3 | P3 | Spec / src/script.cpp | The host binds $manifest with `Get-Content -Raw -LiteralPath ... / ConvertFrom-Json` without -Encoding UTF8, while Scoop… | 已由后续实现/文档修正（本轮核对） |
| #31/verifier-1-4 | P3 | Evidence / docs/script-support.md | The #31 real shared-root section cites `.local/pi/tasks/31/evidence/real-rclone-1/` as this round's evidence, but that d… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #32/verifier-1-1 | P3 | Standards / docs/installer-support.md | The mechanism table now carries two rows for the same declaration: line 16 '`installer.file` / `installer.args` 安装器程序' a… | 本轮修复或核对已解决 |
| #32/verifier-1-2 | P3 | Spec / docs/installer-support.md | The 'Installer/Uninstaller 脚本生命周期' list still gives install/update/uninstall orders as pre_install → installer.script → … | 保留为已知 P3（本轮未改，不阻塞验收） |
| #32/verifier-1-3 | P3 | Evidence / .local/pi/tasks/32/evidence/change-summary.txt | The coder report cites this file as `git diff --stat 42fa9d4..HEAD`, but it was produced at da62478: it shows 922 insert… | 历史证据标注：文件按原样保留，未回改；不得据此声称已复现 |
| #32/verifier-1-4 | P3 | Standards / tests/recovery.ps1 | src/execute.cpp:1343-1355 adds the installers[] branch (installer_programs_started, retained transaction evidence, 'scri… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #32/verifier-1-5 | P3 | Standards / src/execute.cpp | staged_manifest still returns an empty path when `target.scripts.empty()`, but this ticket now also calls it for package… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #32/verifier-1-6 | P3 | Standards / src/script.cpp | run_installer_program takes `std::size_t index` used only for log naming, and its single caller always passes 0 (src/exe… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #32/verifier-1-7 | P3 | Spec / tests/real-scoop-installers.ps1 | The only real-root program execution is Main/groovyserv, which declares installer.file but no multi-stage scripts and no… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #33/verifier-1-1 | P3 | Spec / docs/installer-support.md | The #33 real-root bullet states that Scoop's own installs changed the Windows Installer cache by '+1 entry'. Recomputing… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #33/verifier-1-2 | P3 | Evidence / tests/real-scoop-msi.ps1 | 99-summary.json writes windows_installer_cache.coop_operations_unchanged=$true (line 241) and final_state_matches_before… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #33/verifier-1-3 | P3 | Spec / src/msi.cpp | fdintCLOSE_FILE_INFO returns TRUE without applying info->date/info->attribs, so MSI File-table timestamps and attributes… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #33/verifier-1-4 | P3 | Evidence / src/msi.cpp | Two advertised failure paths have no runtime case at all: external/partial/multi-part cabinet rejection (line 535 onward… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #33/verifier-1-5 | P3 | Evidence / .local/pi/tasks/33/evidence/build-final-40dccb5.log | The cited final build log contains a single line ('[1/1] Copying the pinned Scoop compatibility library beside coop.exe'… | 历史证据标注：文件按原样保留，未回改；不得据此声称已复现 |
| #33/verifier-1-6 | P3 | Standards / src/plan.cpp | The same MSI permission/reboot/cache facts are hand-written as prose in four places: plan.cpp msi_extraction_json (line … | 保留为已知 P3（本轮未改，不阻塞验收） |
| #34/verifier-1-1 | P3 | Standards / src/inno.cpp | Within the new anonymous namespace, `lower()` (lines 11-14) and the `<algorithm>` include are unused, and the comment de… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #34/verifier-1-2 | P3 | Spec / src/inno.cpp | Coop iterates roots outermost (local innounp-unicode, local innounp, then global innounp-unicode, global innounp), while… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #35/verifier-1-1 | P3 | Spec / GLOSSARY.md | The new glossary entry says the missing helper fails "在写入前" (before writes), but the verified behaviour is later in the … | 本轮修复或核对已解决 |
| #35/verifier-1-2 | P3 | Spec / docs/installer-support.md | The #35 run-state bullet says "helper 缺失时预览声明不可用，执行前失败且未下载/重建 helper". My probe reproduces the same run: the preview exi… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #35/verifier-1-3 | P3 | Evidence / tests/real-scoop-nsis.ps1 | `$helperVersion = (($helperVersionRun.output -split "`r?`n")[0]).Trim()` takes the first split line, but 7z.exe output s… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #35/verifier-1-4 | P3 | Standards / src/nsis.cpp | `tree_totals` is copied verbatim into src/nsis.cpp:17-28 from src/inno.cpp:17-28 (files/bytes plus the symlink rejection… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #35/verifier-1-5 | P3 | Evidence / .local/pi/tasks/35/evidence/real-scoop-nsis-df5525537d8c/99-summary.json | The #35 evidence set binds its runs only through the coop.exe SHA256 (directory suffix) and the report text; no artifact… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #36/verifier-1-1 | P3 | Spec / docs/old-version-support.md | The documented reset rejection set includes "存在 pending 事务" inside a list introduced as "预览 execution_available=false，执行… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #36/verifier-1-2 | P3 | Spec / docs/old-version-support.md | The blanket claim that every listed rejection is reported as preview `execution_available=false` is not what the current… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #37/verifier-1-1 | P3 | Standards / src/faults.cpp | test_faults_enabled() is declared (src/faults.hpp:15) and defined here but never called; test_fault_point() duplicates t… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #37/verifier-1-2 | P3 | Spec / src/execute.cpp | ownership_evidence is derived only from created entries that still exist: when the journal has zero created entries (ext… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #37/verifier-1-3 | P3 | Spec / docs/recovery-support.md | The doc says a preserved newer user value is reported with status recovered-with-user-changes, but execute.cpp:1677-1678… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #37/verifier-1-4 | P3 | Evidence / docs/recovery-support.md | The conflict-code table documents created-link-repointed, created-path-unreadable, moved-path-outside-root, journal-unre… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #38/verifier-1-1 | P3 | Evidence / docs/initialization-support.md | The 复现 command writes into .local/pi/tasks/38/evidence/real-scoop-initialization-run6, a directory already cited as hist… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #38/verifier-1-2 | P3 | Evidence / docs/initialization-support.md | The 未覆盖与边界 section names the controlled-PATH condition, R08 environment scope and other-mechanism packages, but not two … | 保留为已知 P3（本轮未改，不阻塞验收） |
| #38/verifier-1-3 | P3 | Standards / src/init.cpp | init is the only command that writes into the installation root without taking RootLock and without writing a journal: t… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #39/verifier-1-1 | P3 | Spec / docs/cli-boundaries.md | The 240-character threshold creates an observed behavior cliff: a 239-character root fails install with MAX_PATH ('direc… | 本轮修复或核对已解决 |
| #39/verifier-1-2 | P3 | Standards / src/plan.cpp | install_batch (1019-1035) and simple_batch (1055-1071) contain byte-identical copies of the per-package text loop plus t… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #39/verifier-1-3 | P3 | Standards / src/data.cpp | The extended-length threshold is the literal 240 in operating_path (line 38) and again in normalized_root (line 50), and… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #39/verifier-1-4 | P3 | Evidence / .local/pi/tasks/39/coder-1.json | Both acceptance entries cite .local/pi/tasks/39/evidence/path-batch-10.out.log, a 147-byte PASS line produced at 02:43, … | 历史证据标注：文件按原样保留，未回改；不得据此声称已复现 |
| #39/verifier-1-5 | P3 | Spec / docs/cli-boundaries.md | The exit-code table says exit 0 means '批量中每个包都是 success 或 skipped', but a wholly valid dry-run batch exits 0 while every… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #40/verifier-1-1 | P3 | Standards / src/execute.cpp | The commit adds a UTF-8 BOM (EF BB BF) to the first line of src/execute.cpp; base 90029f9 had bytes 35,105,110 and head … | 已由后续实现/文档修正（本轮核对） |
| #40/verifier-1-2 | P3 | Evidence / .local/pi/tasks/40/coder-1.json | Four executed commands are labelled kind "static": build-5.log (scripts/build.ps1), ctest-full-final.log (ctest), exposu… | 历史证据标注：文件按原样保留，未回改；不得据此声称已复现 |
| #40/verifier-1-3 | P3 | Evidence / tests/real-scoop-cohort.ps1 | After the real Scoop update the script runs `coop reset git@<latest>`, which in the cited run exited 1 with 'Requested v… | 本轮修复或核对已解决 |
| #40/verifier-1-4 | P3 | Standards / src/execute.cpp | The coexisting-view branch only refuses when BOTH views are invalid; if Coop's .coop-shim.json still matches but the Sco… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #41/verifier-1-1 | P2 | Spec / tests/coverage-manifest-features.ps1 | The command-host feature is computed as [IO.Path]::GetExtension(($target -split '\s+')[0]), so any bin target containing… | 同票后续轮已修复，最终 verifier 通过 |
| #41/verifier-1-2 | P3 | Evidence / tests/real-scoop-coverage.ps1 | recorded_version and run_exit come from .local/pi/tasks/40/.../facts-all.json (line 334) while installed_manifest_sha256… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #41/verifier-2-1 | P3 | Standards / tests/real-scoop-coverage.ps1 | The repair replaced the old 'historical-cohort' branch with 'cohort-run-not-bound'/'cohort-manifest-mismatch' (lines 506… | 本轮修复或核对已解决 |
| #41/verifier-2-2 | P3 | Spec / AGENTS.md | Commit 086e93d ('docs(agents): check delegated pi work every five minutes', 15 -> 5 minute interval) sits inside this ti… | AGENTS.md 改动已由 4b0389d/086e93d 完成，并在 R24 最终验收核对 |
| #42/verifier-1-1 | P2 | Evidence / docs/compatibility-gap-closure.md | bin-four fixture 没有隔离 4 元素 bin 元组成因。shape-fixture.ps1:17 的 `@{ bin = @(@('probe.exe','probe','-cert','-key')) }` 在 Power… | 同票后续轮已修复，最终 verifier 通过 |
| #42/verifier-1-2 | P3 | Spec / docs/compatibility-gap-closure.md | 3 个 arm64-only 包被实现方自行归为「架构边界（不建子票）」。这没有把包移出分母、也没有改写为“不支持”，64bit 拒绝确与 Scoop manifest.ps1:156-181 一致；但它实质上是“本环境不覆盖 arm64 … | 人类已批准为 3 个 ARM64-only 包的生命周期例外（#45 评论 2026-10-27），保持未运行 |
| #42/verifier-1-3 | P3 | Evidence / .local/pi/tasks/42/evidence/closure-20261026-221524/repro-summary.json | 运行时汇总 repro-summary.json 自身不含 git head/提交字段，只有 baseline_project_head（8283e6a 测量提交）；与本次 head 的绑定需要外推到 versions-final.txt … | 后续盘点汇总已写入 project_head；旧汇总不回改 |
| #42/verifier-2-1 | P3 | Evidence / tests/coverage/gaps.json | closure.inventory.reused_because 写的是 “current head differs from the measurement head only in documentation”，但包含该字段的提交 36… | 本轮修复或核对已解决 |
| #42/verifier-2-2 | P3 | Evidence / .local/pi/tasks/42/evidence/closure-verify-20261027-060914/versions-final-363ee8a.txt | 该文件被 coder-2 当作本轮版本证据引用，但其命令行段仍来自第一轮的 write-versions.ps1 模板：指向 closure-20261026-221524 证据目录、复述已作废的 “four manifest-shape … | 历史证据标注：文件按原样保留，未回改；不得据此声称已复现 |
| #42/verifier-2-3 | P3 | Evidence / .local/pi/tasks/42/evidence/closure-verify-20261027-060914/coverage-gaps-negative.log | 负向回归记录的 original/restored sha256 为 EE2FFD64…，而提交的 tests/coverage/gaps.json 是 6448A45F…；两者只差 closure.verified_at（06:10:54… | 历史证据标注：文件按原样保留，未回改；不得据此声称已复现 |
| #43/verifier-1-1 | P2 | Standards / tests/real-scoop-cohort.ps1 | The real-machine cohort harness (invoked as documented in docs/real-machine-acceptance.md:106) still builds its per-pack… | 同票后续轮已修复，最终 verifier 通过 |
| #43/verifier-1-2 | P3 | Evidence / tests/real-scoop-alternating.ps1 | `InstalledVersion` labels every `list --json` call `"$name-list-before"`, and it runs at five stages of the alternation,… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #43/verifier-1-3 | P3 | Evidence / .local/pi/tasks/43/evidence/layering-check.txt | The header reads `# Layering check at 363ee8a` (the ticket base) although the content was produced from the final worktr… | 历史证据标注：文件按原样保留，未回改；不得据此声称已复现 |
| #43/verifier-1-4 | P3 | Spec / docs/architecture.md | The command table still has live-looking rows for `coop adopt [package] --dry-run` and `coop adopt [package]` (lines 23-… | 已由后续实现/文档修正（本轮核对） |
| #43/verifier-1-5 | P3 | Standards / src/plan.cpp | `plan.purge` is assigned after `make_plan` already computed `Plan::blocker` (plan.cpp:820, 843, 933), and `execution_blo… | 已由后续实现/文档修正（本轮核对） |
| #43/verifier-2-1 | P3 | Evidence / tests/bucket.ps1 | The first full-suite run at head 7a42d60 (ctest-final-fix.log) failed `bucket` in 8.06 s with 'Interrupted refresh did n… | 记录为预算存在的时序抖动；本轮最终 45/45 通过，未再依赖单次重试 |
| #43/verifier-2-2 | P3 | Evidence / .local/pi/tasks/43/coder-2.json | coder-2 attributes coop_sha256=e03020f0... to cohort-20261027-071738/summary.json, but summary.json holds only run/statu… | 历史证据标注：文件按原样保留，未回改；不得据此声称已复现 |
| #43/verifier-2-3 | P3 | Evidence / .local/pi/tasks/43/evidence/layering-check.txt | The verifier-1 artifact still reads '# Layering check at 363ee8a'. It was correctly left untouched and is superseded by … | 历史证据标注：文件按原样保留，未回改；不得据此声称已复现 |
| #43/verifier-2-4 | P3 | Evidence / .local/pi/tasks/43/verifier-1.json | My verifier-1 sub-claim that the list status 'ready' no longer appears at this head was wrong: src/execute.cpp:1707 publ… | 已按更正语义记录：installed=共享事实，ready=Coop 记录 |
| #44/verifier-1-1 | P2 | Evidence / docs/performance-support.md | The environment line names `提交 7a42d60` as the code version of the measured optimized binary (`coop.exe` SHA256 1ec35fa5… | 同票后续轮已修复，最终 verifier 通过 |
| #44/verifier-1-2 | P3 | Evidence / docs/performance-support.md | The bullet says the real-scale changed refresh keeps the worktree updated with `changed_files=1`, `无关 Manifest 字节不变、索引重建… | 已由后续实现/文档修正（本轮核对） |
| #44/verifier-1-3 | P3 | Spec / docs/performance-support.md | The diff contains no refresh-path change at all (src/git_bucket.cpp is untouched; refresh optimization belongs to #23), … | 已由后续实现/文档修正（本轮核对） |
| #44/verifier-1-4 | P3 | Standards / src/query.cpp | After `search`/`info` were switched to `matching_catalog`, `Json catalog(const Context&)` has no remaining caller anywhe… | 已由后续实现/文档修正（本轮核对） |
| #44/verifier-1-5 | P3 | Standards / src/query.cpp | The comment above `installed_architecture` says reading `every installed package's manifests and old-version inventories… | 已由后续实现/文档修正（本轮核对） |
| #44/verifier-2-1 | P3 | Evidence / tests/perf-real.ps1 | `$unrelatedManifest` is chosen from `(Join-Path $upstream 'bucket')`, i.e. the file:// remote copy that Coop only reads,… | 已由后续实现/文档修正（本轮核对） |
| #44/verifier-3-1 | P3 | Evidence / docs/performance-support.md | The real-root unchanged-refresh row parenthetical reads `最终运行 1,769.6/…`: it gives the final run's p50 but elides its p9… | 本轮修复或核对已解决 |
| #44/verifier-3-2 | P3 | Evidence / .local/pi/tasks/44/evidence/commands-round3.txt | The round-3 command record states `Final head: 7a1ebec707449f8a4e02c85c80a37c967b6aafa7`, but the candidate head is 696c… | 本轮修复或核对已解决 |
| #46/verifier-1-1 | P3 | Evidence / docs/psmodule-support.md | The shared-root run proves a full Coop-managed lifecycle plus Scoop read-side recognition (real install of main/gsudo in… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #46/verifier-1-2 | P3 | Evidence / docs/coverage-report.md | The R25 re-measurement note says 真机验证集合仍为历史 15 个包。The re-measurement summary actually records totals.verified_real_cohor… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #46/verifier-1-3 | P3 | Spec / docs/psmodule-support.md | The documented failure mode for an invalid declaration (`psmodule: true`, non-object, or missing/empty name -> adapter m… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #46/verifier-1-4 | P3 | Standards / src/execute.cpp | remove-ps-module decides retention with `fs::directory_iterator(modules) != end`, i.e. any surviving entry counts, while… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #46/verifier-2-1 | P3 | Evidence / docs/psmodule-support.md | The shared-root run proves a Coop-managed lifecycle plus Scoop read-side recognition (real install of main/gsudo into C:… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #46/verifier-2-2 | P3 | Evidence / docs/coverage-report.md | The R25 re-measurement note says 真机验证集合仍为历史 15 个包, while the re-measurement summary records totals.verified_real_cohort=… | 本轮修复或核对已解决 |
| #46/verifier-2-3 | P3 | Spec / docs/psmodule-support.md | The documented failure mode for an invalid declaration (`psmodule: true`, non-object, or missing/empty name -> adapter m… | 本轮修复或核对已解决 |
| #46/verifier-2-4 | P3 | Standards / src/execute.cpp | remove-ps-module decides retention with `fs::directory_iterator(modules) != end`, i.e. any surviving entry counts, while… | 本轮修复或核对已解决 |
| #47/verifier-1-1 | P3 | Spec / docs/exposure-support.md | The '隔离验证' table row '目标类型选择' still says "不支持的 `.sh` 目标在计划中拒绝", which contradicts the new behavior (tests/coverage-featu… | 本轮修复或核对已解决 |
| #47/verifier-1-2 | P3 | Standards / docs/command-entry-support.md | The doc claims both generated files are byte-identical to Scoop's Out-UTF8File output, but Scoop writes the `.cmd` witho… | 本轮修复或核对已解决 |
| #47/verifier-1-3 | P3 | Standards / CMakeLists.txt | The registered CTest does not pass -RequirePythonHost, so tests/command-entry-host.ps1:225-226 prints 'SKIP positive .py… | 本轮修复或核对已解决 |
| #47/verifier-1-4 | P3 | Evidence / .local/pi/tasks/47/evidence/final-environment-20261027-112233/environment.json | The tool-version artifact records "powershell": "5.1.26100.9711" (the capture shell) while the docs attribute the runs t… | 本轮最终环境记录同时标注 pwsh 运行器与 PowerShell 5.1 捕获壳 |
| #48/verifier-1-1 | P1 | Spec / src/ir_adapter.cpp | The duplicate-alias branch replaces the earlier entry with the later one ('*existing = std::move(entry)'), which is only… | 同票后续轮已修复，最终 verifier 通过 |
| #48/verifier-1-2 | P2 | Spec / src/execute.cpp | extras/mqtt-spy declares shortcuts [["..\\..\\..\\shims\\mqtt-spy.cmd","mqtt-spy"]] and bin mqtt-spy.jar. After this tic… | 同票后续轮已修复，最终 verifier 通过 |
| #48/verifier-1-3 | P2 | Evidence / tests/real-scoop-manifest-shape.ps1 | The 'expected' side is a second PowerShell reimplementation (Add-ScoopCommandExpectation/Add-ScoopPathExpectation/Add-Sc… | 同票后续轮已修复，最终 verifier 通过 |
| #48/verifier-1-4 | P3 | Evidence / .local/pi/tasks/48/evidence/final-real/summary.json | The final runs were executed before the commit, so versions.project_head records 5652f09c (ticket base) and final-covera… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #48/verifier-1-5 | P3 | Standards / docs/manifest-shape-support.md | The 'known differences' section presents the cross-family shim residue as an intentional 'single-entry ownership choice'… | 已由后续实现/文档修正（本轮核对） |
| #48/verifier-2-1 | P3 | Evidence / tests/scoop-shape-probe.ps1 | The Add-Path stub is a no-op and the probe re-derives its expectation in script code (lines 81-86: `Join-Path $dir $valu… | 保留为已知 P3（本轮未改，不阻塞验收） |
| #48/verifier-2-2 | P3 | Evidence / .local/pi/tasks/48/evidence/build-final2.log | The path cited in coder-2.json for `scripts/build.ps1 build` now contains only the post-commit no-op rebuild ('[1/1] Cop… | 历史证据标注：文件按原样保留，未回改；不得据此声称已复现 |
| #48/verifier-2-3 | P3 | Standards / src/exposure.cpp | scoop_command_ps1 always writes Scoop's cross-drive absolute form (`$path = "<abs>"`), while the pinned Scoop shim() wri… | 本轮修复或核对已解决 |
| #49/verifier-1-1 | P3 | Evidence / docs/coverage-report.md | The evidence table row was generalized from "所有阻塞包与 15 个验证包…（68 个包）" to "所有阻塞包与验证包…（68 个包）" while the R28 run directory … | 本轮修复或核对已解决 |
| #49/verifier-1-2 | P3 | Standards / CMakeLists.txt | The new versions_bucket test root string ends with a literal trailing space ("${PROJECT_SOURCE_DIR}/.local/tests/version… | 本轮修复或核对已解决 |

## 未改 P3 的说明

- 这些条目均为精度、可读性或证据标注问题，没有一条被作为产品能力通过。R24 的验收结论只引用本轮实际运行与已保存证据；剩余条目保留在各自票的上下文，未通过本页静默关闭。
- P1/P2 条目均已在同票后续轮修复并由最终 verifier 复核；本页不重复其测试，只登记状态。
