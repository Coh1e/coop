# 完整交付验收与人工验收说明（R24 / #45）

> **状态（2026-10-30）**：本页是历史验收快照，命令面、版本与测试数量已继续推进；当前状态与证据入口见 [README](../../README.md)。

> 本页是从**最终构建**重新执行的整体验收记录，以及照做即可重复的人工验收步骤。它按实际证据区分“本轮运行”“历史结果”和“未运行”，不把关闭票数、计划成功或模型自述当作完成。逐条历史 verifier 发现的处置见[历史 verifier 发现清单](../verifier-findings-inventory.md)。

## 1. 结论

- 最终产品源码为提交 `a4d7ced`（`coop.exe` SHA256 `c6fe0fb2938ca528473f3f8b271ce56e425d867c381d4c797d45f5c89c70fcf1`）。本页提交只增加文档与验收说明，不再改产品源码；二进制与源码的绑定见 §2。
- 从该构建重新执行的整体验收全部通过：默认 CTest 45/45；本机实际安装的 15 个软件逐项共用生命周期 698 项检查 0 失败；共用状态双向单文件流程 25 条命令全部退出 0 且执行序列等于预览计划；无 Scoop/Git/7-Zip 的独立初始化与后续 Scoop 识别通过；真实共用根上的进程崩溃、冲突诊断与恢复通过；性能在本机构建上重新测量。
- 本轮真实验收发现并修复了一个共享状态缺陷：Scoop 卸载后遗留 Coop 入口元数据，下一次 Coop 安装以 Windows error 183 失败。修复后真实重装、回归用例和完整 15 包重跑均通过（§6）。
- 完整 Main/Extras 分母仍是 4149 份 Manifest（Main 1701 + Extras 2448）；人类批准的 ARM64 生命周期例外只有 3 个 ARM64-only 包。其余未运行范围按 §5 原样保留，不声称完成。
- 本轮**未获发布授权**：本页证明的是交付门槛的实际证据，不是正式发布或市场可用性声明。

## 2. 最终构建、工具与绑定

| 项 | 值 |
| --- | --- |
| 产品源码提交 | `a4d7cedaeb2e56dda6fb7cb35de010cb730288e2` |
| 二进制 | `.local/build/coop.exe`，`coop 0.1.0`，SHA256 `c6fe0fb2938ca528473f3f8b271ce56e425d867c381d4c797d45f5c89c70fcf1` |
| 构建 | CMake 4.4.4 / Ninja 1.13.2 / MSVC x64 Build Tools 14.51（Release，`/W4 /WX`） |
| 脚本运行器 | PowerShell 7.6.5（pwsh）；版本采集壳为 Windows PowerShell 5.1.26100.9711 |
| 平台 | Windows `10.0.26300.0` x64 |
| Scoop | v0.6.0（2026-09-30），共用根 `C:\Users\Neo\scoop`，主 bucket 实测 `da998465…`（运行中由 Scoop 自身更新） |
| 源码/二进制绑定 | `build-fix2-9e4560e.log` 编译了 `entries` 修复；`binary-a4d7ced.sha256.txt` 记录该二进制摘要；此后只有文档提交。工作树除未跟踪的 `.idea/`、`devkit/` 外干净 |

证据：`.local/pi/tasks/45/evidence/ctest-full-a4d7ced.log`、`binary-a4d7ced.sha256.txt`、`final-env/environment-a4d7ced.txt`。

## 3. 本轮重新执行的整体验收

### 3.1 默认测试套件

```
ctest --test-dir .local/build --output-on-failure
```

45/45 通过，耗时 234.13 s，退出码 0。覆盖 CLI、查询、路径/批量、初始化、bucket 刷新、性能夹具、IR/Plan、归档、生命周期、中断、并发、清理、旧版本、依赖、跨 bucket 版本来源、共享入口、恢复矩阵、入口/环境、psmodule、命令宿主、Manifest 形状、Hook、安装器程序、MSI/Inno/NSIS 与 IR 复用。

证据：`.local/pi/tasks/45/evidence/ctest-full-a4d7ced.log`、`ctest-full-a4d7ced.exit.txt`。

### 3.2 共用状态双向流程（最终构建）

`tests/real-scoop-alternating.ps1` 在同一真实 Scoop 根上顺序执行：Scoop 安装 `jq@1.7.1` → Coop 识别且无私有记录前置 → Coop 预览并更新到 1.8.2（`jq` 是单文件产物，实际操作序列为 `download,verify,unlink-current,remove-entries,publish-current,entries,commit-state`，没有解压步骤）→ 旧版本保留 → Scoop `list`/`update` 继续识别 → Coop 卸载 → Coop 安装 → Scoop `reset`/运行 → Coop 卸载。

- 25 条命令全部退出 0；预览的 `ir_operations` 与执行的 `observed_steps` 逐项相同：`download,verify,unlink-current,remove-entries,publish-current,entries,commit-state`。
- Scoop 安装开始时 `management=unadopted` 且 `private_record_before=False`；Coop 更新后标准 `scoop-manifest.json` 版本为 1.8.2，旧版本 1.7.1 保留，反向流程结束后无残留。

证据：`.local/pi/tasks/45/evidence/alternating-a4d7ced-20261027-225311/real-scoop-alternating-evidence.json`（`coop_sha256=c6fe0fb2…`）及同目录逐命令日志。

### 3.3 本机实际安装集的逐项验收（15 个包）

`tests/real-scoop-cohort.ps1 -Lifecycle` 在最终构建上重新执行：15 个包逐项核对程序运行、版本、入口、路径、环境、持久化数据、安装记录与双方列表；14 个包由真实 Scoop `reset` 重发入口后由 Coop 重新识别；10 个有本地旧版本的包由 Coop 往返切换并由 Scoop 重新识别；`fastfetch` 由 Coop 卸载并重装；`clink` 由真实 Scoop 卸载后由 Coop 重装。

- 结果：**698 项检查，0 失败，15/15 包 `status=met`**（`pi-coding-agent` 只读，因为执行器正在使用它，`scoop-reset=not-run`）。
- 本轮由此发现并修复了 §6 的共享元数据缺陷；第一次运行的唯一失败（clink 重装 exit 1）已定位、修复并在本次完整重跑中转为通过。

证据：`.local/pi/tasks/45/evidence/cohort-a4d7ced/cohort-20261027-093907/summary.json`、`.local/pi/tasks/45/evidence/cohort-a4d7ced/run.stdout.log` 与运行目录内的 `items/`、`lifecycle/` 逐命令日志。

### 3.4 无 Scoop 的独立初始化

`tests/real-scoop-initialization.ps1` 在项目内全新 root 上以不含 `git`/`7z`/`scoop` 的 PATH 初始化、克隆真实 bucket、安装并运行真实 Main/jq；随后复制本机真实 Scoop 程序树到同一 root，顺序执行 Scoop 识别、`reset`、卸载，Coop 重装与卸载，并恢复、核对用户 PATH。

- 全部命令退出 0（未初始化 root 上的 Scoop 探测按预期退出 1）；`freshness`、`restricted_path`、`init_directories`、标准记录与用户 PATH 快照均写入证据 JSON。
- 未运行边界与之前一致：真实的“之后再安装 Scoop”是用运维者现有程序树复制，不是运行 Scoop 安装器；Scoop 发起的**版本更新**仍未在该 root 执行。

证据：`.local/pi/tasks/45/evidence/initialization-a4d7ced-20261027-230628/initialization-evidence.json`（`coop_sha256=c6fe0fb2…`）。

### 3.5 失败、中断与恢复

- CTest `recovery`、`recovery_matrix`、`lifecycle_interrupt`、`lifecycle_race` 在最终构建上全部通过。
- `tests/real-scoop-recovery.ps1` 在同一真实根上创建临时 bucket/包，执行 Coop 安装 → Scoop `reset` → 真实进程崩溃（`0xC0000409`）→ 查询/恢复 → 与 Scoop 交替 → 冲突注入。`created-path-replaced` 冲突退出 1 且不删除外部对象，恢复后双方继续识别；运行前后 15 个既有安装清单一致，测试对象全部清理。

证据：`.local/pi/tasks/45/evidence/recovery-a4d7ced-20261027-231015/summary.json`（`status=pass`，`coop_sha256=c6fe0fb2…`）。

### 3.6 性能（最终构建）

`tests/perf-real.ps1` 在最终二进制（`coop_sha256=c6fe0fb2…`、`git_head=a4d7ced`）上重新测量完整进程；机器为 AMD Ryzen 7 8845HS / 16 逻辑处理器 / 64 GB / KIOXIA NVMe / Windows 11。真实根输入：Main 1702 份 Manifest、15 个已安装包；本地副本 1705 份。

| 场景 | 样本 | p50 / p95 ms | 结果与载荷 |
| --- | ---: | --- | --- |
| `list`（真实根） | 3 | **496.7 / 507.5** | **未达 50ms**；15 个已安装包与 636 份历史日志仍要扫描 |
| `info main/git`（真实根） | 3 | **47.9 / 65.0** | p50 达成、p95 未达 50ms |
| `search git`（真实根） | 3 | **46.4 / 57.8** | 达成 100ms |
| `info nerd-fonts/0xProto-NF-Mono` | 3 | **54.2 / 63.0** | **未达 50ms**（跨 bucket 索引） |
| 真实根刷新（已是最新） | 2 | **1,816.7 / 1,826.9** | `unchanged`、`received_bytes=0`；耗时主要是真实 HTTPS 取 ref 的往返 |
| 真实根刷新（修订记录落后于工作树） | 1 | 1,928.3 | `changed`，`changed_files=0`、`bytes=0`；工作树已由 Scoop 前进到 `da998465…` |
| 首次刷新（本地真实规模副本，`file://`） | 1 | **85,950.9** | 64,744,932 bytes、1784 文件；单样本 |
| 有变化刷新（本地副本） | 3 | **187.2 / 208.7** | 1 文件、46,952–47,002 bytes；每轮无关 Manifest SHA256 不变、索引重建、新 Manifest 可查询 |
| 无变化刷新（本地副本） | 3 | **67.0 / 68.6** | `received_bytes=0` |

- 未达项按实测如实报告，不作“平均达标”推导：`list` 仍明显高于 50ms 目标，`info` 的两个真实样本一个 p95 超目标、一个 p50 也超目标。这与 #44 记录的真实根规模结论一致；本轮产品源码相对 #44 只改了 `entries` 的共享元数据清理与 `psmodule` 保留判断，没有改变查询/刷新热路径。
- 本轮没有重跑真实 HTTPS 首次刷新（需再下载约 54MB）：其最近一次实测（`89b4cf80…` 固定修订、54,381,675 字节、29,297.8ms 单样本）在 [性能报告](../performance-support.md) 中作为**历史结果**保留，不能当成最终二进制的新运行。
- 有变化/无变化刷新与查询的完整 p50/p95、机器和缓存条件在 `.local/pi/tasks/45/evidence/perf-real-a4d7ced/perf-real-report.json`；更早的 200/1500/3000 规模与优化前后对比见 [性能报告](../performance-support.md)。

## 4. 完整分母、逐机制证据与人类批准的例外

### 4.1 Main/Extras 分母

| 项 | 结果 |
| --- | --- |
| 分母 | Main `eebcee22…` 1701 + Extras `0f8f4b5f…` 2448 = **4149** 份 Manifest（R28 重测；完整基线与逐包记录见[覆盖报告](../coverage-report.md)） |
| 读取 | 4149/4149 |
| 计划可执行 | 4141 |
| 计划被阻塞 | 6：`architecture-artifact` 3（arm64-only）、`external-host:python` 3（`main/retdec`、`main/vapoursynth`、`extras/pdd`；默认用户 PATH 无真实 Python 3） |
| 真机验证（分母口径） | R28 为 13（`gh`、`uv` 的安装副本与当轮分母不一致，标为 `cohort-manifest-mismatch`，按未运行计）；#41 基线为 15；本轮 15 个本机实际安装包全部通过 §3.3。闭合计数为 13 verified + 0 historical + 4136 not run = 4149 |
| 未运行 | 4136 个包（含上述 2 个 `cohort-manifest-mismatch`）保持只读盘点，不因“计划可执行”算作生命周期验证 |

### 4.2 逐机制证据

机制支持来自各机制票的真机/夹具证据，本页不重复已经证实的具体测试，只列出入口：

| 机制 | 证据 |
| --- | --- |
| 共用状态、双向交替、独立初始化 | 本页 §3.2–§3.4；[真实基线](../real-scoop-baseline.md)、[逐项交替](real-machine-acceptance.md) |
| 共用 bucket 刷新、分支/修订/本地修改 | [共用 bucket 的直接刷新](../shared-bucket-support.md)、[性能](../performance-support.md) |
| 查询、预览与执行同源 | [包管理 IR 与查询/预览路径](../ir-pipeline.md)、CTest `ir_pipeline`/`plan`/`acceptance` |
| 归档、多产物、架构、摘要算法 | [归档生命周期覆盖](../archive-support.md)、[多产物](../multi-artifact-support.md) |
| 脚本、Hook、installer/uninstaller 程序 | [生命周期 Hook](../script-support.md)、[Installer/Uninstaller](../installer-support.md) |
| 命令入口、快捷方式、用户环境 | [复杂命令入口与环境暴露](../exposure-support.md)、[命令入口宿主](../command-entry-support.md)、[Manifest 形状](../manifest-shape-support.md)、[PSModulePath](../psmodule-support.md) |
| 持久化数据、旧版本、清理与彻底删除 | [持久化](../persistence-support.md)、[旧版本](../old-version-support.md) |
| 依赖、反向保护、跨 bucket 来源 | [依赖](../dependency-support.md)、[覆盖报告](../coverage-report.md) |
| 中断、恢复与冲突诊断 | [恢复](../recovery-support.md)、本页 §3.5 |
| CLI 路径、退出码与批量 | [CLI 边界](../cli-boundaries.md)、CTest `path_batch` |

### 4.3 人类批准的例外

2026-10-27 人类明确批准：接受本轮 **3 个 ARM64-only 包**（`main/gel-arm64`、`main/llvm-arm64`、`extras/cpu-z-arm64`）的生命周期实跑例外。

- 它们仍保留在完整分母中，逐包标记为 ARM64 生命周期**未运行/未验证**。
- x64 下的不适用（`architecture-artifact`）与 `--arch arm64` 的规划结果是分开的证据，**不能**算作 ARM64 安装、更新或运行已验证。
- 该批准不扩展到其他兼容缺口或未运行软件。

## 5. 未运行与剩余限制

- **各机制的真机脚本没有在最终构建上逐个重跑**：归档/多产物、MSI/Inno/NSIS、Hook/installer 程序、持久化、入口/环境/快捷方式和依赖的真实样本运行仍是各自票的历史证据（本页 §4.2 链接）；它们在最终构建的默认套件中有对应夹具，且本轮 15 包真实生命周期覆盖了入口/环境/持久化/版本的通用路径。不把这两类证据混为一谈，也不声称每个机制的每个真实样本都在本轮重新运行。
- 4136 个 Main/Extras 包（闭合计数：4149 − 13 已验证；含 2 个安装副本与分母不一致的包）只有只读读取与规划，没有逐包生命周期；Extras 软件没有在本机真实根实际运行（本机 Scoop 根未注册 Extras）。
- 2 个 32bit/arm64 以外的架构边界：32bit 只执行了真实 `air` 包；arm64 只有批准例外中的规划与静态证据，没有生命周期。
- `psmodule`：Scoop 自己卸载 Coop 安装的模块包（`uninstall_psmodule` 会递归删除 junction 目标）仍未运行；系统级模块与机器级 `PSModulePath` 未实现；这些在[psmodule 支持](../psmodule-support.md)中保持未运行。
- MSI 的外部/多段 cabinet、WiX/Dark 等厂商安装器结构仍明确拒绝；没有真实样本。Inno/NSIS 依赖 root 内已安装的 helper，helper 缺失时在执行阶段具名失败。
- `pi-coding-agent` 是本轮执行器自身，只做只读事实记录，不重写入口或切换版本。
- 最终构建上没有可用的真实 Scoop 发起**版本更新**样本：`scoop update jq` 报告 1.7.1 已是其当前最新（未发生版本变化），因此“Scoop 真实更新 → Coop 识别”在本轮只有 Scoop `reset` 与之前构建上的 `uv 0.13.5→0.13.6` 证据；后者是历史结果，不冒充最终构建运行。
- 历史 verifier 的 P3 精度/证据标注条目未逐项重跑或改写；状态与原因逐条见[清单](../verifier-findings-inventory.md)。它们不构成产品能力通过，也不阻塞本次验收。
- 真实共用根上的操作只限本轮声明的包与范围：没有强杀用户程序、没有卸载用户的 Git/7-Zip/Scoop、没有改无关用户配置或系统环境；新的真实副作用仅为正常的软件更新（紧邻的上一构建上的 `gh 2.103.2→2.103.3`、`uv 0.13.5→0.13.6`）与最终构建上已验证的版本往返切换。

## 6. 本轮发现并修复的共享状态缺陷

**现象（红）**：第一次 15 包重跑中，`scoop uninstall clink` 只删除了 Scoop 自己的 `.shim/.exe/.cmd`，留下了 Coop 的 `shims/clink.coop-shim.json` 与旧版 `clink.coop-shim`；随后 `coop install clink` 退出 1：

```
coop: Destination cannot be published (Windows error 183); close the program and retry
```

证据：`.local/pi/tasks/45/evidence/cohort-9b7e65e/cohort-20261027-092136/lifecycle/scoop-remove/coop-install.log`、`summary.json`（唯一失败项 `coop-reinstall-after-scoop-removal exit=1`）。

**修复**：在发布入口前，把仍然命名本包、且目标位于本包 `apps/<包>/current` 下的残留 Coop 元数据移入当前事务（可由恢复还原），再发布完整入口；同一别名在一次 entries 步骤中只准备一次，跨 `.exe`/脚本家族的第二个声明不会移走刚发布的元数据。外来包或异常目标仍然冲突。提交 `9e4560e`、`a4d7ced`。

**绿**：真实根上 `coop install clink` 退出 0，`clink --version` 输出 `1.9.35.fa48d0`，Scoop `list clink` 显示 1.9.35；新增 `scoop_interop` 回归（Coop 安装 → 模拟 Scoop 删除 → 保留 Coop 元数据 → Coop 重装成功且清理旧 `.coop-shim` → 卸载无残留）；最终 15 包重跑 698/0。

证据：`.local/pi/tasks/45/evidence/clink-reinstall-fix-20261027-092910/clink-install.log`、`.local/pi/tasks/45/evidence/ctest-scoop-interop-fix2.log`、`.local/pi/tasks/45/evidence/ctest-full-a4d7ced.log`。

## 7. 人工验收步骤（照做即可）

前置：Windows x64、MSVC Build Tools + Windows SDK、CMake 3.25+、Ninja、PowerShell 7；本机已有 Scoop v0.6.0 根。所有工程依赖、构建与证据都留在项目内 `.local`。

```powershell
# 1. 准备、构建、默认测试（约 4 分钟）
./scripts/fetch-deps.ps1
./scripts/build.ps1
ctest --test-dir .local/build --output-on-failure

# 2. 只读查看真实根，不做写入
.local/build/coop.exe --root C:\Users\Neo\scoop list --json
.local/build/coop.exe --root C:\Users\Neo\scoop info main/jq --json
.local/build/coop.exe --root C:\Users\Neo\scoop update git --dry-run --json

# 3. 双向单文件流程（要求 jq 当前未安装；会临时安装、更新、卸载 jq）
pwsh -NoProfile -File tests/real-scoop-alternating.ps1 `
  -CoopExe .local/build/coop.exe `
  -EvidenceDir .local/pi/tasks/manual/alternating-<UTC>

# 4. 无 Scoop 的独立初始化（项目内全新 root）
pwsh -NoProfile -File tests/real-scoop-initialization.ps1 `
  -CoopExe .local/build/coop.exe -TestRoot .local/tests/manual-init `
  -EvidenceDir .local/pi/tasks/manual/init-<UTC>

# 5. 本机实际安装集逐项验收（会切换旧版本、重装 fastfetch、Scoop 卸载并由 Coop 重装 clink）
pwsh -NoProfile -File tests/real-scoop-cohort.ps1 `
  -CoopExe .local/build/coop.exe -EvidenceDir .local/pi/tasks/manual/cohort-<UTC> `
  -Lifecycle -CoopResetPackages 7zip,uv,git,innounp,fastfetch,fd,fzf,ripgrep,starship,zoxide `
  -ReinstallPackage fastfetch -ScoopRemovePackage clink

# 6. 真实中断与恢复
pwsh -NoProfile -File tests/real-scoop-recovery.ps1 `
  -CoopExe .local/build/coop.exe -EvidenceDir .local/pi/tasks/manual/recovery-<UTC>

# 7. 性能（真实根查询/刷新 + 项目内真实规模副本）
pwsh -NoProfile -File tests/perf-real.ps1 `
  -CoopExe .local/build/coop.exe -ScoopRoot C:\Users\Neo\scoop `
  -TestRoot .local/tests/manual-perf -EvidenceDir .local/pi/tasks/manual/perf-<UTC> `
  -Runs 3 -FirstRefreshRuns 1
```

判定标准：

- 第 1 步必须是 `100% tests passed`；退出非零即失败。
- 第 3 步 `real-scoop-alternating-evidence.json` 中 `planned_ir_operations` 必须与 `observed_ir_operations` 相同，`standard_version=1.8.2`、`previous_version_retained=true`，所有 `commands[].exit=0`。
- 第 4 步 `initialization-evidence.json` 中所有命令（除预期的未初始化 Scoop 探测）退出 0，`user_path_after_restore` 与运行前一致。
- 第 5 步 `summary.json` 必须 `status=pass`、`failures=0`、`package_count=15`；`pi-coding-agent` 的 `scoop-reset=not-run` 是执行器约束，其余 14 个为 `met`。
- 第 6 步 `summary.json` 必须 `status=pass`，崩溃退出码为 `-1073740791`、冲突场景退出 1 且带 `created-path-replaced`，运行前后 15 个安装清单一致。
- 第 7 步记录机器、样本数、p50/p95 与载荷；不得用跨运行低值替换另一运行的高值。

所有命令的包、版本、作用域、前提和运行前后事实都记录在证据目录；不要重复运行带有“安装/卸载”的步骤而不先重新盘点，也不要在同一环境同时启动两个写入者。

## 8. 证据索引

| 内容 | 位置（项目内，被忽略） |
| --- | --- |
| 默认套件 45/45 与退出码 | `.local/pi/tasks/45/evidence/ctest-full-a4d7ced.log`、`.exit.txt` |
| 二进制摘要与构建 | `.local/pi/tasks/45/evidence/binary-a4d7ced.sha256.txt`、`build-fix2-9e4560e.log` |
| 15 包逐项验收 | `.local/pi/tasks/45/evidence/cohort-a4d7ced/cohort-20261027-093907/` |
| 双向单文件流程 | `.local/pi/tasks/45/evidence/alternating-a4d7ced-20261027-225311/` |
| 独立初始化 | `.local/pi/tasks/45/evidence/initialization-a4d7ced-20261027-230628/` |
| 真实恢复 | `.local/pi/tasks/45/evidence/recovery-a4d7ced-20261027-231015/` |
| 性能 | `.local/pi/tasks/45/evidence/perf-real-a4d7ced/` |
| 缺陷复现与修复 | `.local/pi/tasks/45/evidence/cohort-9b7e65e/…/lifecycle/scoop-remove/`、`clink-reinstall-fix-20261027-092910/` |
| 历史 verifier 清单 | [docs/verifier-findings-inventory.md](../verifier-findings-inventory.md) |
