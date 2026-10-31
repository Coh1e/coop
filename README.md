# Coop

Coop 是 Windows 原生的软件包管理器，与现有用户级 Scoop 共用安装根、bucket、软件、入口、持久化数据和安装记录。它不要求迁移或接管：两个客户端可以先后管理同一批软件。Scoop 的 Manifest 与 bucket 生态可直接使用。

当前为 `v0.2.4`，支持 Windows x64。与 Scoop 的兼容边界、已验证范围和未运行项见[兼容性盘点](docs/coverage-report.md)与[能力边界](#能力边界)。

## 安装

发布产物 `coop-v<版本>-x64.zip` 解压后，`coop.exe` 与 `scoop-lib/` 必须同级；压缩包还包含 `LICENSE`、`THIRD_PARTY.md` 和 `licenses/`。也可以从 Scoop bucket 安装：

```powershell
scoop bucket add coh1e https://github.com/Coh1e/scoop-bucket
scoop install coh1e/coop
```

版本记录见 [Releases](https://github.com/Coh1e/coop/releases)。

## 构建与测试

需要：

- Windows 10/11 x64。
- Visual Studio 2022 Build Tools 或更高版本，MSVC 19.30+，以及 Windows SDK。
- CMake 3.25+、Ninja。
- Windows PowerShell 5.1。测试与脚本以它为基线；`pwsh 7` 可用，但不是验收门禁。
- `git.exe` 仅用于测试夹具；`fetch-deps.ps1` 使用 `curl.exe` 与 `tar.exe`。

在仓库根目录执行：

```powershell
./scripts/fetch-deps.ps1     # 下载并校验固定依赖、Scoop 夹具与真实测试归档
./scripts/build.ps1          # 配置、构建并运行完整 CTest
./scripts/build.ps1 -Action test-fast
./scripts/install-hooks.ps1  # 每个克隆一次：安装 pre-commit 检查
```

依赖、构建产物、测试数据和临时文件都在项目内的 `.local/`。测试通过 `scripts/build.ps1` 或 `ctest` 运行，不要直接调用 `tests/*.ps1`。

## 常用命令

```powershell
coop init
coop bucket add main https://github.com/ScoopInstaller/Main
coop install jq
coop list
coop search git
coop info jq
coop update
coop uninstall jq
coop recover
```

命令分组：

- 查询：`list`、`search`、`info`、`status`、`prefix`、`cat`、`which`、`home`、`depends`、`export`、`checkup`、`help`。
- 写入：`install`、`update`、`uninstall`、`reset`、`recover`、`cleanup`、`hold`、`unhold`。
- 来源：`bucket add|update|list|rm|known`、`import`。
- 配置：`config`、`alias`、`shim`。

写入命令支持 `--dry-run`、`--json`、`--arch 64bit|32bit|arm64`。退出码固定为 0（完成）、1（失败或批量部分失败）、2（用法错误）。`--json` 是机器契约；文本模式与 Scoop 同形，具体规则见[读命令的文本输出](docs/query-output.md)与[CLI 路径、退出码与批量边界](docs/cli-boundaries.md)。

## 能力边界

- 共用安装根与状态；不承诺两个客户端同时写入。
- 系统级根只读：`update`、`uninstall`、`reset` 以 `global-scope-readonly` 拒绝写入；`-g`/`--global` 不写入。
- 不自动同步 bucket、不自动发布；只有显式 `update`、`update *` 或 `bucket update` 刷新共用 bucket。
- 生命周期 Hook、`installer.script` 与安装器程序由真实 PowerShell 执行，需要 PowerShell 与随包的 `scoop-lib/`；脚本不经过文本白名单。
- MSI 产物按管理镜像提取，不运行 `msiexec`；Inno Setup 与 NSIS 载荷需要已安装在 root 内的 helper，Coop 不下载、不内嵌 helper，厂商安装器不运行。
- 普通卸载保留声明的持久化数据；`uninstall --purge` 才删除，`cleanup` 才清理旧版本。
- arm64 生命周期未验证；32bit 真实包已执行。完整未运行项见[兼容性盘点](docs/coverage-report.md)。

## 文档

- 开始使用：[已确认的产品范围](docs/design-scope.md)、[体系结构](docs/architecture.md)、[与 Scoop 共用状态的决定](docs/adr/0002-share-scoop-state.md)。
- 命令与输出：[CLI 路径、退出码与批量边界](docs/cli-boundaries.md)、[读命令的文本输出](docs/query-output.md)、[CLI 反馈与下载缓存](docs/cli-feedback.md)。
- 包机制：[包管理 IR 与查询/预览路径](docs/ir-pipeline.md)、[Manifest 形状兼容](docs/manifest-shape-support.md)、[归档生命周期](docs/archive-support.md)、[多产物与摘要算法](docs/multi-artifact-support.md)、[Installer 与特殊安装机制](docs/installer-support.md)。
- 状态与恢复：[跨机制中断恢复](docs/recovery-support.md)、[持久化数据](docs/persistence-support.md)、[旧版本与清理](docs/old-version-support.md)。
- 入口与环境：[命令入口与快捷方式](docs/exposure-support.md)、[PowerShell 模块暴露](docs/psmodule-support.md)、[生命周期 Hook](docs/script-support.md)、[依赖安装与保护](docs/dependency-support.md)。
- 共用 bucket：[共用 bucket 的直接刷新](docs/shared-bucket-support.md)、[没有 Scoop 时的独立初始化](docs/initialization-support.md)。
- 兼容性与验证：[Main/Extras 全量盘点](docs/coverage-report.md)、[首版真实样本报告](docs/history/compatibility-report.md)、[完整交付验收](docs/history/final-acceptance.md)、[逐项交替验收](docs/history/real-machine-acceptance.md)、[历史验收矩阵](docs/history/acceptance-matrix.md)。
- 性能与体积：[本地查询与 Git 刷新性能](docs/performance-support.md)、[包体决策](docs/adr/0005-binary-size-build-only.md)。
- 写作与决策：[写作标准](docs/writing-style.md)、[ADR 目录](docs/adr/)、[研究记录](docs/research/)。
- 任务与规格：[GitHub Issues](https://github.com/Coh1e/coop/issues)、[正式规格 #21](https://github.com/Coh1e/coop/issues/21)。

## 许可证

Coop 以 [MIT 许可证](LICENSE) 发布。随包分发的第三方组件仍按各自许可证分发，来源与全文见 [THIRD_PARTY.md](THIRD_PARTY.md)。
