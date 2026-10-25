# Coop

Coop 是设计中的 C++20 Windows 原生软件包管理器，优先接管现有用户级 Scoop 安装，复用其 bucket 与 Manifest 生态。

当前已具备原生 CLI、本地查询与 bucket 管理，软件接管和生命周期仍在实现，尚不能用于真实迁移。开发工具与生成数据遵循项目内存放约定，仓库中的 devkit 用作场景参考，其用户级安装脚本不是本项目的环境准备入口。

- [已确认的产品范围](docs/design-scope.md)
- [首版正式规格](https://github.com/Coh1e/coop/issues/2)
- [设计背景、验收路径与下一步](docs/architecture.md)
- [Git 库选择方向](docs/adr/0001-use-embedded-git-library.md)
- [Scoop Git 调用审计](docs/research/scoop-git-command-audit.md)
- [goop 实现对照](docs/research/git-free-buckets.md)
- [GitHub 任务与规格](https://github.com/Coh1e/coop/issues)

开发需要已有 MSVC x64 Build Tools、Windows SDK、CMake 3.25+、Ninja 和 PowerShell。首次运行 `./scripts/fetch-deps.ps1` 获取并校验固定 nlohmann/json 3.12.0 头文件与 MIT 许可（仅项目内）；然后运行 `./scripts/build.ps1` 配置、构建并测试。产物在被忽略的 `.local/build`，临时文件在 `.local/tmp`。脚本只在编译子进程中加载 MSVC 环境并设置临时目录，不修改用户或系统环境。

可运行 `.local/build/coop.exe --version` 或 `--help`；无效命令退出码为 2，运行失败为 1，正常命令为 0。通过 `--root <目录> list|search <查询>|info <bucket/包名>` 查询本地安装及 bucket，添加 `--json` 获取结构化输出；`--global-root` 可明确指定另一个只读系统级安装根。未指定根时查询当前用户的默认 Scoop 位置。

`bucket add <名称> <公开HTTPS Git URL或本地目录>` 注册来源；Git来源可指定 `--branch` 或 `--revision`。`bucket update [名称]` 显式同步，`bucket list` 查看，`bucket remove <名称>` 只撤销注册并保留源文件。Git使用内嵌库，无需git.exe；私有/SSH来源不联网更新。标准代理仅在当前进程环境中通过HTTPS_PROXY/NO_PROXY读取，不修改系统代理。

Git更新先导出并校验不可变快照，再提交来源记录；原有Scoop bucket和旧快照不会被强制重置或清除。发现本地文件修改会拒绝更新。第三方源码版本与许可见 [THIRD_PARTY.md](THIRD_PARTY.md)。

`install|update|uninstall|adopt <包名> --dry-run` 从本地清单和安装记录生成只读计划，可指定 `--arch 64bit|32bit|arm64`，添加 `--json` 获取结构化输出。计划列出文件摘要、产物、入口、环境、持久化、脚本及预计操作；接管检查同时查看本地更新清单。已知不支持/无效项与尚未验证的生命周期分别报告。

目前 `install|update|uninstall <包名>` 可执行无脚本、无依赖、无归档的单 EXE 包，使用原生下载、SHA256 校验及命令启动器。仅管理 Coop 自己记录且证据未变化的安装；入口冲突会拒绝覆盖。更新默认沿用已安装来源与架构，保留旧版本，准备与切换失败时尝试恢复原入口；保留程序不代表用户数据已回滚。写操作受根目录写锁保护并保留先行事务日志；异常退出留下 pending 日志时会阻止后续写入，恢复命令仍在实现。当前阶段仅用于项目隔离测试，尚不能用于真实迁移。

默认测试不依赖外网，包含真实CLI、进程树观测、只读预览、本地Git增量、故障、中断和并发验证。可另运行 `tests/git-live.ps1`，显式指定已构建Coop、process_guard和项目内测试根，验证GitHub/GitLab HTTPS、无git.exe、代理失败和无效证书。
