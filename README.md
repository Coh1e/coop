# Coop

Coop 是设计中的 C++20 Windows 原生软件包管理器，优先接管现有用户级 Scoop 安装，复用其 bucket 与 Manifest 生态。

当前已具备原生 CLI、本地查询与 bucket 管理，软件接管和生命周期仍在实现，尚不能用于真实迁移。开发工具与生成数据遵循项目内存放约定，仓库中的 devkit 用作场景参考，其用户级安装脚本不是本项目的环境准备入口。

- [已确认的产品范围](docs/design-scope.md)
- [首版正式规格](https://github.com/Coh1e/coop/issues/2)
- [设计背景、验收路径与下一步](docs/architecture.md)
- [Git 库选择方向](docs/adr/0001-use-embedded-git-library.md)
- [Scoop Git 调用审计](docs/research/scoop-git-command-audit.md)
- [goop 实现对照](docs/research/git-free-buckets.md)
- [归档生命周期覆盖](docs/archive-support.md)
- [持久化数据支持](docs/persistence-support.md)
- [依赖安装与反向依赖保护](docs/dependency-support.md)
- [复杂命令入口、快捷方式与环境暴露](docs/exposure-support.md)
- [生命周期 Hook 与真实脚本兼容](docs/script-support.md)
- [GitHub 任务与规格](https://github.com/Coh1e/coop/issues)

开发需要已有 MSVC x64 Build Tools、Windows SDK、CMake 3.25+、Ninja 和 PowerShell。首次运行 `./scripts/fetch-deps.ps1` 获取并校验固定 nlohmann/json 3.12.0 头文件、libgit2 1.9.7 源码、libarchive 3.7.7 / zlib 1.3.1 / xz 5.6.4 归档源码、Scoop 原生测试夹具及真实 ZIP/tar.gz 测试归档（全部仅项目内）；然后运行 `./scripts/build.ps1` 配置、构建并测试。产物在被忽略的 `.local/build`，临时文件在 `.local/tmp`。脚本只在编译子进程中加载 MSVC 环境并设置临时目录，不修改用户或系统环境。

可运行 `.local/build/coop.exe --version` 或 `--help`；无效命令退出码为 2，运行失败为 1，正常命令为 0。通过 `--root <目录> list|search <查询>|info <bucket/包名>` 查询本地安装及 bucket，添加 `--json` 获取结构化输出；`--global-root` 可明确指定另一个只读系统级安装根。未指定根时查询当前用户的默认 Scoop 位置。

`bucket add <名称> <公开HTTPS Git URL或本地目录>` 注册来源；Git来源可指定 `--branch` 或 `--revision`。`bucket update [名称]` 显式同步，`bucket list` 查看，`bucket remove <名称>` 只撤销注册并保留源文件。Git使用内嵌库，无需git.exe；私有/SSH来源不联网更新。标准代理仅在当前进程环境中通过HTTPS_PROXY/NO_PROXY读取，不修改系统代理。

Git更新先导出并校验不可变快照，再提交来源记录；原有Scoop bucket和旧快照不会被强制重置或清除。发现本地文件修改会拒绝更新。第三方源码版本与许可见 [THIRD_PARTY.md](THIRD_PARTY.md)。

`install|update|uninstall|adopt <包名>... --dry-run` 从本地清单和安装记录生成只读计划，可指定 `--arch 64bit|32bit|arm64`，添加 `--json` 获取结构化输出。计划列出文件摘要、产物、入口、环境、持久化、脚本、依赖顺序及预计操作；接管检查同时查看本地更新清单。已知不支持/无效项与尚未验证的生命周期分别报告。

`install` 读取 Manifest 显式 `depends`，先安装依赖再安装请求包；已安装依赖标为跳过。缺失、循环、跨 bucket 歧义和来源冲突在写入前明确失败，带版本的依赖写法仍拒绝。`install|update|uninstall|adopt` 可一次接收多个包，逐包报告 `success`、`skipped` 或 `failed`；每个包有独立事务，部分失败总体非零且不回滚已完成项，不声称全局事务。依赖安装、更新前检查和批量结果见 [依赖安装与反向依赖保护](docs/dependency-support.md)。

卸载前检查所有已安装包保存 Manifest 的已知依赖，包括未接管的安装；被依赖时列出依赖方并拒绝卸载，证据不可读时也不会假定没有依赖。Coop 不自动连带卸载，不自动清理疑似无用依赖，也不删除 Manifest 声明的外部工具需求。

不带包名的 `adopt --dry-run` 逐包列出当前用户根内安装的接管资格：`eligible`、`already-managed`、`unsupported`、`untested`、`inconsistent`，并逐项给出原因；系统级根只列出并标为 `unsupported`，不会写入。`adopt <包名>` 只接管资格为 `eligible` 的安装：不重新下载、不重新安装、不执行脚本，原程序路径、原始 Scoop 安装记录和命令入口保持不变；备份、原始入口摘要和 Coop 管理记录写入 `.coop`。接管同时核对已有 Scoop 命令入口与快捷方式的目标、参数和摘要；缺失或不一致标为 `untested`，不建立删除归属。重复接管同一安装返回 `already-managed`；中断留下的事务由下一次接管先恢复，预览不会改写恢复状态。

`list` 分开显示管理权（`managed`/`unadopted`）、安装状态和上次操作状态，更新失败不会被报告为未安装或已成功。Windows 文件名不区分大小写，包名与安装目录的身份比较同样不区分大小写。

目前 `adopt` 只执行无脚本、无归档的单 EXE 包，可接管已安装且声明依赖均已存在、Manifest 声明了 `persist` 且现有 junction/hardlink 归属可验证的安装；带 Hook 的安装保持 `untested`，不提升接管资格；接管不搬动原数据，更新要求持久化映射不变，普通卸载只解除链接并保留声明的持久化数据。`install|update|uninstall <包名>` 执行无安装器进程的单文件、ZIP 与 tar.gz 包，包括 `extract_dir`、`extract_to`、多产物、已安装依赖、目录/文件持久化映射，以及 `bin`、`shortcuts`、`env_add_path`、`env_set` 声明：EXE/COM、BAT/CMD、PS1、JAR 入口分别用对应宿主启动并转发参数与退出码，GUI 目标使用 GUI 子系统启动器；快捷方式写入开始菜单并在管理记录中保存路径与摘要，外部删除的视为已撤销并记录、不阻塞后续更新/卸载，内容被修改的仍拒绝；声明环境应用到命令进程及其子进程，不改用户或系统环境变量。生命周期 Hook 仅在固定样本证明的子集内、按 Scoop 顺序在真实版本目录/current 中执行 `pre_install`、`post_install`、`pre_uninstall`，其他脚本、外部命令、注册表/环境写入和 `post_uninstall` 在执行前诊断拒绝；失败脚本的 stdout/stderr 与退出码可见、不自动重试，外部副作用不声称回滚。全部使用原生下载、SHA256 校验、内置 libarchive 解压及原生 junction/hardlink，不需要安装 7-Zip。7z、MSI、InnoSetup/NSIS 等特殊安装器与未证明兼容的脚本组合在执行前明确拒绝，不静默下载外部工具；`--purge` 尚未实现。归档格式与持久化语义、脚本子集、真实样本、安全边界和未验证项见 [归档生命周期覆盖](docs/archive-support.md)、[持久化数据支持](docs/persistence-support.md)、[复杂命令入口、快捷方式与环境暴露](docs/exposure-support.md) 与 [生命周期 Hook 与真实脚本兼容](docs/script-support.md)。仅管理 Coop 自己记录且证据未变化的安装；入口和持久化链接冲突会拒绝覆盖。更新默认沿用已安装来源与架构，保留旧版本，准备与切换失败时尝试恢复原入口和链接；保留旧程序不代表持久化数据已回滚。写操作受根目录写锁保护并保留先行事务日志；异常退出留下 pending 日志时会阻止后续写入，恢复命令仍在实现。当前阶段仅用于项目隔离测试，尚不能用于真实迁移。

默认测试不依赖外网，包含真实CLI、进程树观测、只读预览、真实ZIP/tar.gz归档生命周期、归档安全拒绝、本地Git增量、故障、中断和并发验证，复杂命令入口、快捷方式和环境暴露（`COOP_PROGRAMS_DIR` 隔离目录内生成真实快捷方式），以及生命周期 Hook（固定样本脚本原文、真实 PowerShell、顺序、失败与能力诊断）。可另运行 `tests/git-live.ps1`，显式指定已构建Coop、process_guard和项目内测试根，验证GitHub/GitLab HTTPS、无git.exe、代理失败和无效证书。
