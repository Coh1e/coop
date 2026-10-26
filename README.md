# Coop

Coop 是 C++20 Windows 原生软件包管理器，优先接管现有用户级 Scoop 安装，复用其 bucket 与 Manifest 生态。

首版已具备原生 CLI、本地查询与 bucket 管理，以及项目内验证过的接管、安装、更新、卸载、入口/快捷方式/真实用户环境与 PATH、持久化、依赖保护与中断恢复路径；显式 `bucket update` 已可在本机真实 Scoop 根内原地刷新共用 bucket。其余写入路径仍以项目内测试为主，尚不能用于完整真实用户 Scoop 迁移或正式发布。开发工具与生成数据遵循项目内存放约定，仓库中的 devkit 仅作场景参考，其用户级安装脚本不是本项目的环境准备入口。

当前产品方向已由 [正式规格 #21](https://github.com/Coh1e/coop/issues/21) 更新为与 Scoop 共用安装与状态：查询和只读预览已改由独立的包管理 IR、校验与计划路径驱动，直接读取本机真实 Scoop 安装事实，无需先执行接管；实际写入仍沿用原型执行路径，待后续任务迁移。模块边界与证据见 [包管理 IR 与查询/预览路径](docs/ir-pipeline.md)，本轮真实安装与只读核对见 [真实 Scoop 安装基线](docs/real-scoop-baseline.md)。

- [已确认的产品范围](docs/design-scope.md)
- [当前正式规格（#21）](https://github.com/Coh1e/coop/issues/21)
- [与 Scoop 共用状态的决定](docs/adr/0002-share-scoop-state.md)
- [包管理 IR 与查询/预览路径](docs/ir-pipeline.md)
- [真实 Scoop 安装基线](docs/real-scoop-baseline.md)
- [共用 bucket 的直接刷新](docs/shared-bucket-support.md)
- [原型正式规格（历史，#2）](https://github.com/Coh1e/coop/issues/2)
- [设计背景、验收路径与下一步](docs/architecture.md)
- [Git 库选择方向](docs/adr/0001-use-embedded-git-library.md)
- [Scoop Git 调用审计](docs/research/scoop-git-command-audit.md)
- [goop 实现对照](docs/research/git-free-buckets.md)
- [归档生命周期覆盖](docs/archive-support.md)
- [多产物、架构与摘要算法支持](docs/multi-artifact-support.md)
- [持久化数据支持](docs/persistence-support.md)
- [依赖安装与反向依赖保护](docs/dependency-support.md)
- [复杂命令入口、快捷方式与环境暴露](docs/exposure-support.md)
- [生命周期 Hook 与真实 PowerShell](docs/script-support.md)
- [Installer/Uninstaller 与特殊安装机制](docs/installer-support.md)
- [跨命令恢复与并发一致性](docs/recovery-support.md)
- [本地查询与 Git 刷新性能](docs/performance-support.md)
- [首版真实样本兼容与整体验收报告](docs/compatibility-report.md)
- [GitHub 任务与规格](https://github.com/Coh1e/coop/issues)

## 项目内准备、构建与运行

需要已有 MSVC x64 Build Tools、Windows SDK、CMake 3.25+、Ninja 和 PowerShell。默认 CTest 的 `bucket`/`performance` 测试还用 `git.exe` 编写项目内测试仓库；它只是夹具工具，Coop 产品运行不依赖 git.exe。所有命令在仓库根目录执行，依赖、构建、测试数据和临时文件都留在项目内：

```powershell
./scripts/fetch-deps.ps1                 # 下载并校验固定依赖、Scoop 夹具和真实测试归档
./scripts/build.ps1                      # 配置、构建并运行默认测试
ctest --test-dir .local/build --output-on-failure
ctest --test-dir .local/build --output-on-failure -R '^(acceptance|cli|query|bucket|plan|adopt|archive_lifecycle|hooks|installers|persistence|dependencies|recovery)$'
```

`fetch-deps.ps1` 获取 nlohmann/json 3.12.0、libgit2 1.9.7、libarchive 3.7.7 / zlib 1.3.1 / xz 5.6.4 / zstd 1.5.7 / bzip2 1.0.8 源码，以及真实 jq 1.7.1/1.8.2、ripgrep、air、nodejs 7z、luajit tar.zst、tidy ZIP、curl tar.xz、unzip 7z SFX 和 7-Zip MSI 测试归档；全部只写入被忽略的 `.local`。构建产物在 `.local/build`，临时文件在 `.local/tmp`。脚本只在编译子进程中加载 MSVC 环境并设置临时目录，不修改用户或系统环境。构建会把仓库内固定的 Scoop 兼容库 `assets/scoop-lib` 复制为 `coop.exe` 旁的 `scoop-lib/`；生命周期脚本需要真实 PowerShell（默认 `pwsh.exe`，可用 `COOP_POWERSHELL` 指定），显式 `COOP_SCOOP_LIB` 可换用另一份同布局兼容库。`tests/acceptance.ps1` 用固定 20 份真实 Manifest 和真实程序完成首版整体验收，结果写入项目内测试根。

可运行 `.local/build/coop.exe --version` 或 `--help`；无效命令退出码为 2，运行失败为 1，正常命令为 0。通过 `--root <目录> list|search <查询>|info <bucket/包名>` 查询本地安装及 bucket，添加 `--json` 获取结构化输出；`--global-root` 可明确指定另一个只读系统级安装根。未指定根时查询当前用户的默认 Scoop 位置。

`bucket add <名称> <公开HTTPS Git URL或本地目录>` 注册来源；Git来源可指定 `--branch` 或 `--revision`。Git来源直接克隆到 Scoop 共用的 `<根>/buckets/<名称>` 工作树并保留完整历史；`bucket update [名称]` 在该工作树内 fetch 后原地前进，已存在的 Scoop bucket 会被就地识别和刷新。`bucket list` 查看（刷新中断时显示 `refresh_pending` 与日志路径），`bucket remove <名称>` 只撤销注册并保留源文件，之后可用同名 `bucket add` 重新注册现有工作树。Git使用内嵌库，无需git.exe；私有/SSH来源不联网更新。标准代理仅在当前进程环境中通过HTTPS_PROXY/NO_PROXY读取，不修改系统代理。

刷新前验证目标树、检查工作树是否干净，并要求目标 revision 是当前 HEAD 的快进；未提交修改、本地提交或分叉历史都会拒绝更新，保留 `.git`、实际分支、本地内容和已发布记录，不自动 `clean`。首次、有变化、无变化刷新分别记录 `refresh_kind`、revision、`changed_files`、`received_bytes`、`files_count` 和 `synced_at`。分支、本地修改、失败保留和边界见[共用 bucket 的直接刷新](docs/shared-bucket-support.md)。第三方源码版本与许可见 [THIRD_PARTY.md](THIRD_PARTY.md)。

`install|update|uninstall|adopt <包名>... --dry-run` 从本地清单和安装记录生成只读计划，可指定 `--arch 64bit|32bit|arm64`，添加 `--json` 获取结构化输出。计划列出文件摘要、产物、入口、环境、持久化、脚本、依赖顺序及预计操作；接管检查同时查看本地更新清单。已知不支持/无效项与尚未验证的生命周期分别报告。

`install` 读取 Manifest 显式 `depends`，由 IR Planner 解析依赖图并写入计划：已安装依赖从共享 `apps/<包>/current` 复用，未安装依赖各自带有预览可核对的 IR 操作序列；执行按同一计划顺序逐包进行，每个包有独立事务。缺失、循环、跨 bucket 歧义和来源冲突在写入前明确失败，带版本的依赖写法仍拒绝。`install|update|uninstall|adopt` 可一次接收多个包，逐包报告 `success`、`skipped` 或 `failed`；部分失败总体非零且不回滚已完成项，不声称全局事务。依赖安装、更新前检查和批量结果见 [依赖安装与反向依赖保护](docs/dependency-support.md)。

卸载前检查所有已安装包保存 Manifest 的已知依赖，包括未接管的安装；被依赖时列出依赖方并拒绝卸载，证据不可读时也不会假定没有依赖。Coop 不自动连带卸载，不自动清理疑似无用依赖，也不删除 Manifest 声明的外部工具需求。

不带包名的 `adopt --dry-run` 逐包列出当前用户根内安装的接管资格：`eligible`、`already-managed`、`unsupported`、`untested`、`inconsistent`，并逐项给出原因；系统级根只列出并标为 `unsupported`，不会写入。`adopt <包名>` 只接管资格为 `eligible` 的安装：不重新下载、不重新安装、不执行脚本，原程序路径、原始 Scoop 安装记录和命令入口保持不变；备份、原始入口摘要和 Coop 管理记录写入 `.coop`。接管同时核对已有 Scoop 命令入口与快捷方式的目标、参数和摘要；缺失或不一致标为 `untested`，不建立删除归属。重复接管同一安装返回 `already-managed`；中断留下的事务由下一次接管先恢复，预览不会改写恢复状态。

`list` 分开显示管理权（`managed`/`unadopted`）、安装状态和上次操作状态，更新失败不会被报告为未安装或已成功。Windows 文件名不区分大小写，包名与安装目录的身份比较同样不区分大小写。

目前 `adopt` 只执行无脚本、无归档的单 EXE 包，可接管已安装且声明依赖均已存在、Manifest 声明了 `persist` 且现有 junction/hardlink 归属可验证的安装；带 Hook 的安装保持 `untested`，不提升接管资格；接管不搬动原数据，更新要求持久化映射不变，普通卸载只解除链接并保留声明的持久化数据。`install|update|uninstall <包名>` 执行单文件、多产物、`#/` 重命名产物、架构专属 Manifest、ZIP、7z（含真实 `#/dl.7z` 自解压下载）、tar、tar.gz/tgz、tar.xz/txz、tar.bz2/tbz、tar.zst/tzst、tar.lzma 包，包括嵌套 `extract_dir`、`extract_to`、已安装依赖、目录/文件持久化映射，以及 `bin`、`shortcuts`、`env_add_path`、`env_set` 声明：EXE/COM、BAT/CMD、PS1、JAR 入口分别用对应宿主启动并转发参数与退出码，GUI 目标使用 GUI 子系统启动器；`bin`/`shortcuts` 参数按 Scoop 展开 `$dir`、`$original_dir`、`$persist_dir`；快捷方式写入开始菜单并在管理记录中保存路径与摘要，外部删除的视为已撤销并记录、不阻塞后续更新/卸载，内容被修改的仍拒绝，另一客户端重建但目标、参数、图标一致时按同一归属处理；Scoop `reset` 重建的原生脚本包装只在内容指向本包时随卸载清理；Scoop 安装的 BAT/PS1/JAR 包只有 `.cmd`/`.ps1`/sh 包装时也能从这些证据更新与卸载（隔离实际执行，真实 `clink` 预览）。声明环境写入当前用户 `HKCU\Environment`，广播给新进程，同时应用到 Coop 命令进程；记录原值并保护用户后续修改，卸载恢复或只撤销仍归属 Coop 的值。系统级环境变量仍不修改。真实 `lessmsi`/`red-view`/`spotbugs`/`touch`/`cfr` 入口与 Scoop 交替证据见[复杂命令入口、快捷方式与环境暴露](docs/exposure-support.md#真机验证r07-28)。生命周期 Hook 按 Scoop 顺序在真实 PowerShell 子进程中执行全部六个阶段（`pre_install`、`installer.script`、`post_install`、`pre_uninstall`、`uninstaller.script`、`post_uninstall`），提供固定的 Scoop 兼容库（`scoop-lib`，见 [THIRD_PARTY.md](THIRD_PARTY.md)）与本机固定 v0.6.0 语义的上下文和辅助函数；脚本原文不再经过文本白名单，合法修改仍执行，失败脚本的 stdout/stderr 与退出码可见、不自动重试，外部副作用不声称回滚（依据见[生命周期 Hook 与真实 PowerShell](docs/script-support.md)）。全部使用原生下载、按 Manifest 声明的 SHA256/SHA512/SHA1/MD5 校验、内置 libarchive 解压及原生 junction/hardlink，普通 ZIP、7z 与 tar 压缩流不需要安装 7-Zip；多产物、架构与摘要算法的真机证据见[多产物、架构与摘要算法支持](docs/multi-artifact-support.md)，归档格式、嵌套布局与共享归档交替证据见[归档生命周期覆盖](docs/archive-support.md)；MSI 产物按 Scoop `Expand-MsiArchive` 的管理镜像语义提取：以只读方式打开 Windows Installer 数据库（`msi.dll`）并在 Windows cabinet 解压 API（`cabinet.dll`）中展开内嵌 cabinet，不启动 `msiexec`、不提权、不重启、不写 `%WINDIR%\Installer` 机器缓存；真实共用根上 Coop 与 Scoop 的版本目录逐文件一致，证据见[Installer/Uninstaller 与特殊安装机制](docs/installer-support.md)。Inno Setup 的 `innosetup` 产物由 root 内已安装的 innounp helper 解包：参数与 `-c` 选择按 Scoop `Expand-InnoArchive`，不执行厂商安装器、不提权、不重启，也不下载或内嵌 helper；helper 缺失时预览阻塞且不静默安装，真实 Main/units 更新、rizin 子目录布局、截断失败与双向交替证据见[Installer/Uninstaller 与特殊安装机制](docs/installer-support.md)。NSIS 等其余厂商安装器机制仍在执行前明确拒绝；`installer.file/args` 安装器/卸载器程序声明由真实 PowerShell 与固定 Scoop 兼容库调用上游 `Invoke-Installer` 执行（程序在版本目录运行、`current`/入口发布之前，`$dir`/`$global`/`$version` 参数替换、`.ps1` 直接调用和 `keep` 删除语义按 Scoop），程序自身的外部副作用不承诺回滚且失败不自动重试；生命周期脚本文本本身不再作为拒绝理由，脚本中的 `reg import` 会作为受信包内容执行，Coop 不承诺回滚其注册表副作用。`uninstall <包名> --purge` 是独立的彻底删除请求：预览列出声明的持久化 store 准确范围，执行前重查管理记录、链接归属和 store 文件身份，只删除声明的 store 目标，不跟随 reparse point，也不删除 `persist/<包名>` 下未声明内容；链接被重定向、记录变化或 store 变成链接时在任何删除前失败。`cleanup [包名...]` 只删除管理记录中已记录、摘要未变、非当前且没有 pending 事务的旧版本目录；未记录、缺失 Manifest、被修改或在使用的版本保留并报告原因，不猜测历史下载地址。归档格式与持久化语义、脚本语义、真实样本、安全边界和未验证项见 [归档生命周期覆盖](docs/archive-support.md)、[持久化数据支持](docs/persistence-support.md)、[复杂命令入口、快捷方式与环境暴露](docs/exposure-support.md)、[生命周期 Hook 与真实 PowerShell](docs/script-support.md) 与 [Installer/Uninstaller 与特殊安装机制](docs/installer-support.md)。Coop 创建的安装使用自身管理记录；共用 Scoop 安装从 `apps/<包>/current`、标准安装记录、真实入口和实际产物/版本树重新核对事实，不要求先接管，私有记录缺失不作为拒绝依据。入口和持久化链接冲突会拒绝覆盖。更新默认沿用已安装来源与架构，保留旧版本，准备与切换失败时尝试恢复原入口和链接；保留旧程序不代表持久化数据已回滚。旧版本清理与数据彻底删除分别由 `cleanup` 和 `uninstall --purge` 显式触发，普通卸载仍保留声明数据。写操作受根目录写锁保护并保留先行事务日志；异常退出留下 pending 日志时会阻止后续写入但允许查询。`coop list` 会从 pending 日志显示未完成操作及恢复方式；`coop recover [包名...] [--dry-run]` 先报告自动恢复或需要人工处理的分类与逐项动作，再回滚可安全还原的 Coop 自有路径；包名限定执行范围，未指定事务保持 pending 并标记 skipped，仍有 pending 或指定包不存在时退出非零。恢复不重跑任何脚本，脚本外部副作用仍标为未知；移入/移出端点同时存在、所有权不明或路径不安全时保持 pending 并返回非零，等待人工核对后重试。真实共用根上的既有持久化链接识别、文件/目录映射在 Coop 更新与 Scoop reset/重装间的原地复用、普通卸载保留和准备失败保护见[持久化数据支持](docs/persistence-support.md#真机验证r09-30)。

## 已知限制与恢复范围

- 实测平台为 Windows x64；32bit 真实 air 包已执行，arm64 只有计划与静态检查，未执行。
- `adopt` 旧路径只接受无脚本、无归档的直接单文件安装；带 Hook 的安装和系统级根保持 `untested`/`unsupported`，不会为了接管搬动原程序或持久化数据。共享归档的实际 `update`/`uninstall` 不依赖该旧路径，已用 Scoop 安装的 air 包完成更新、reset 与失败保护验证。
- MSI 产物可实际安装、更新和卸载：从只读 Windows Installer 数据库与内嵌 cabinet 生成管理镜像，不启动 `msiexec`、不提权、不重启、不写 `%WINDIR%\Installer`；外部或多段 cabinet、NSIS 等其余厂商 EXE 安装器结构仍明确拒绝。Inno Setup 的 `innosetup` 产物由 root 内声明的 innounp helper 提取（参数与 `-c` 选择按 Scoop，不执行厂商安装器、不下载 helper），真实 Main/units 更新与 rizin 子目录布局已验收。系统级服务/注册表/环境写入仍不在自动路径内。`installer.file/args` 安装器/卸载器程序由真实 PowerShell 调用上游 `Invoke-Installer` 执行：程序在版本目录运行、`keep` 与参数替换按 Scoop，非零程序退出使包操作失败并回滚已创建的包状态，程序的项目外副作用保留为未知且不自动重试。生命周期脚本同样由真实 PowerShell 与固定 Scoop 兼容库执行，文本不再按子集拒绝；缺少 PowerShell 或兼容库时在执行前诊断，脚本中的外部工具缺失以非零退出码失败。
- 脚本宿主入口仍由 Coop 以 `.coop-shim.json` 加自带启动器发布；Scoop 安装的纯 `.cmd`/`.ps1`/sh 包装已可更新/卸载（隔离实际、真实 `clink` 预览），真实 Scoop `reset` 产生的包装只在 Coop 卸载时按内容归属清理；Coop 自身尚未直接生成这些 Scoop 原生包装。
- 普通卸载保留声明的持久化数据；`uninstall --purge` 才删除声明的 store，`cleanup` 才删除已记录且摘要未变的旧版本。外部删除或修改入口、链接和 store 会被重新核对，不自动覆盖或猜测修复。
- 异常退出留下 pending 事务时阻止新的写入但仍允许查询；`coop list` 显示恢复方式，`coop recover [包名...] [--dry-run]` 只回滚可安全还原的 Coop 自有路径，不重跑脚本，外部副作用标为未知。
- 不自动同步 bucket、不自动发布；只有显式 `bucket update` 会刷新共用 bucket（真实 Scoop 根内已按 #23 验证），安装/更新/卸载等其余写入仍不在真实用户根内自动执行。Git 私有/SSH 来源与跨工具同时写入不在首版范围。逐样本结论、未运行项和证据见[首版真实样本兼容与整体验收报告](docs/compatibility-report.md)。

## 测试范围

默认测试不依赖外网，包含真实CLI、进程树观测、只读预览、固定 20 份真实 Manifest 的读取/计划分类与本轮生命周期、真实 jq 原地接管到卸载的首条路径、真实 nodejs 7z 与持久化保留、真实ZIP/tar.gz/7z归档生命周期、真实 7-Zip MSI 的安装/更新/卸载与损坏失败（`tests/msi-lifecycle.ps1`）、归档安全拒绝、本地Git增量、故障、中断和并发验证，复杂命令入口、快捷方式和真实用户环境/PATH（快捷方式写入 `COOP_PROGRAMS_DIR` 指定的隔离目录；环境测试使用唯一变量名和 `finally` 快照恢复），生命周期 Hook 与 installer/uninstaller 脚本（固定样本脚本原文、真实 PowerShell 与固定 Scoop 兼容库、上下文与 helper、顺序、合法修改、失败与宿主能力诊断），包管理 IR 的安装事实、分层诊断、操作序列与无副作用查询/预览（`tests/ir-pipeline.ps1`）、多产物/改名/架构/摘要算法及失败保护（`tests/multi-artifact.ps1`），以及完整进程的性能测量（`version`/`list`/`info`/`search`、索引命中与刷新、共用 bucket 首次/有变化/无变化刷新）。性能目标、实测值与机器环境见[本地查询与 Git 刷新性能](docs/performance-support.md)。可另运行 `tests/git-live.ps1`，显式指定已构建Coop、process_guard和项目内测试根，验证GitHub/GitLab HTTPS、无git.exe、代理失败和无效证书；`tests/real-scoop-readonly.ps1` 对人工选定的本机真实 Scoop 根执行只读盘点、查询与预览，并核对根内文件未被改动；`tests/real-scoop-bucket.ps1` 在明确授权下只刷新一个真实共用 bucket，并核对分支、修订、本地修改、无变化刷新和无辅助进程；`tests/real-scoop-multi.ps1` 在明确授权下安装、运行并卸载尚未安装的真实多产物/架构/摘要算法样本，并验证真实下载与校验失败不替换当前版本；`tests/real-scoop-archives.ps1` 在同一真实根上顺序验证 ZIP、7z、tar.gz/tar.xz/tar.zst、嵌套布局、7z SFX、共享归档更新和损坏归档失败保护；`tests/real-scoop-dependencies.ps1` 验证真实 git-tfs 复用已安装 git、反向依赖阻止卸载、不自动连带清理和真实缺失依赖诊断；`tests/real-scoop-exposure.ps1` 在明确授权下安装、运行并由真实 Scoop reset 本轮五种入口类型的 Main 包，核对 GUI 窗口、工作目录、快捷方式目标/参数/图标/子目录与 Coop 卸载后的入口清理；`tests/real-scoop-persistence.ps1` 在同一真实根只读核对既有 7zip junction，并用 mediamtx（文件映射）与 pocketbase（目录映射）核对 Coop 更新、Scoop reset/重装、普通卸载保留和准备失败下 store 不搬动，结束后清理本轮安装与测试 store；`tests/real-scoop-hooks.ps1` 在明确授权下只读预览已安装 git/7zip 的真实 Hook 计划，并用 rclone 在真实根上执行一次 `pre_install`/`uninstaller.script` 安装与卸载，核对 Scoop 可见性、程序版本、持久化保留和清理。默认测试还包含 `tests/installer-programs.ps1`（安装器/卸载器程序与多阶段脚本组合的安装、更新、卸载、`keep`、参数替换、失败与回滚）。`tests/real-scoop-installers.ps1` 只读预览真实 Main/vcpkg 的安装器程序与多阶段脚本组合，并在同一真实根上执行 Main/groovyserv 的真实 `bin\setup.bat` 安装程序生命周期（安装、程序产物、Scoop 可见性与卸载）。`tests/real-scoop-msi.ps1` 在明确授权下对真实 Main/kalker 与 Main/pkgconf 执行 Coop→Scoop→Coop 双向交替，对比两客户端生成的版本目录逐文件 SHA256，并核对 Coop 操作不改变 Windows Installer 机器缓存。
