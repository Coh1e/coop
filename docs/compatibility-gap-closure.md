# 全量盘点缺口闭合与子票（R21/#42）

> **子票进展（2026-10-27）：** [R26/#47](https://github.com/Coh1e/coop/issues/47) 已完成并在同一固定修订上复测：`command-entry-host` 11 → **0**，13 条 `adapter/unsupported-command-host` 诊断 → **0**；计划可执行 4123 → **4131**，阻塞 24 → **16**。默认用户 PATH 无真实 `python.exe`，`main/vapoursynth`、`extras/pdd` 如实归为 `external-host:python` 2 项环境前提，不改成“不支持”。实现、真实共用根运行与证据见[命令入口宿主扩展（.py、无扩展名、.config）](command-entry-support.md)。

> [R25/#46](https://github.com/Coh1e/coop/issues/46) 已完成并在同一固定修订上复测：`capability:psmodule` 28 → 0、`dependency-unsupported` 2 → 0，阻塞包 53 → 24（命令入口宿主 11、Manifest 形状 6、依赖缺失 5、arm64 产物 3），计划可执行 4094 → 4123。实现与证据见 [PowerShell 模块暴露（psmodule）](psmodule-support.md)；本页下文的基线归因与子票提议保留为发现阶段记录，不因复测而改写。

> 本页把 [R20/#41 全量盘点](coverage-report.md)暴露的 **53 个计划阻塞包（55 行，按机制去重前）**逐项归因，并给出可独立验收的后续子票。机器可核对账本是 [`tests/coverage/gaps.json`](../tests/coverage/gaps.json)，由 CTest `coverage_gaps` 守卫。本票只做发现闭合与拆票，不修改产品实现；子票需由调度方建票、建立原生阻塞关系并逐项完成后，本票才可能关闭。

## 结论

- 53 个唯一阻塞包全部有明确处置：**4 个提议子票（R25–R28）**覆盖 50 个，**3 个 arm64-only 包**是架构边界（64bit 拒绝与 Scoop 一致，`--arch arm64` 计划可执行），没有任何包被移出分母、没有把缺口改写为“不支持”。
- 六个机制与处置的对应关系由守卫固定；减少条目、改投子票或删掉验收条件都会让 `coverage_gaps` 失败，避免后续盘点静默缩小范围。
- 待调度方创建子票并建立原生关系：R25–R28 各自 **blocks #42 与 #45**；#42 **blocked-by R25–R28**（子票未完成则本票不关闭）；#45 除现有 #43/#44 外再增加 R25–R28 的 blocked-by。R25–R28 彼此独立，不互为阻塞，也不以 #42 为前置，因此可以立即开始实现。
- 本票完成的是“缺口已全部被发现并各有独立验收出口”，不是“缺口已修复”。#42 保持打开符合其验收条件。

| 机制（baseline） | 包数 | 诊断码 | 处置 |
| --- | ---: | --- | --- |
| `capability:psmodule` | 28 | `adapter/unsupported-capability` | 子票 R25 |
| `dependency-unsupported` | 2 | `capability/dependency-unsupported` | 子票 R25（级联） |
| `command-entry-host` | 11 | `adapter/unsupported-command-host` | 子票 R26 |
| `manifest-shape` | 6 | `adapter/manifest-shape` | 子票 R27 |
| `dependency-missing` | 5 | `ir/dependency-missing` | 子票 R28（环境前提 + 跨 bucket 验证） |
| `architecture-artifact` | 3 | `ir/missing-artifact` | 架构边界：arm64-only，非机制缺口 |

`retdec` 同时属于 `command-entry-host` 与 `manifest-shape`，`lazy-posh-git` 同时属于 `capability:psmodule` 与 `dependency-unsupported`，因此机制行计数之和为 55，唯一包为 53。

## 口径与复现

盘点基线来自 #41 的测量提交 `8283e6a062f5044f8a180ede05634c0efca619c7`：Main `5be7f8c702856c72800a0a4945b88fe6ea2bd52f` 1701 份 + Extras `0f8f4b5fd43bedccc7b233b77f4605bddba8085b` 2448 份 = 4149 份 Manifest，4094 份计划可执行、53 份被阻塞、2 份在盘点根内已安装 helper、15 份有真机运行事实、4134 份未运行。本文不重新解释盘点结果，只消费同一份 `tests/coverage/baseline.json`。

本轮用真实 CLI 在同一项目内盘点根逐包重放阻塞诊断（只读，不下载、不安装）：

```powershell
pwsh -NoProfile -File .local/pi/tasks/42/evidence/closure-20261026-221524/repro-gaps.ps1
# 53 个包全部 exit 1、execution_available=false，诊断码与 baseline 逐项一致；
# 3 个 arm64-only 包在 --arch arm64 下 exit 0、execution_available=true、architecture=arm64。
```

证据（被忽略的项目内目录，不随仓库分发）：

| 内容 | 位置 |
| --- | --- |
| 53 包重放汇总（退出码、诊断码、证据文件） | `.local/pi/tasks/42/evidence/closure-20261026-221524/repro-summary.json` |
| 53 包逐包 dry-run JSON | `.../closure-20261026-221524/packages/` |
| 重放完整输出（退出 0） | `.../closure-20261026-221524/repro-gaps.log` |
| 跨 bucket 依赖 fixture（有/无 versions bucket） | `.../closure-20261026-221524/dependency-fixture-summary.json`、`dependency-bucket-present.log`、`dependency-bucket-absent.log` |
| Manifest 形状最小 fixture（四类成因逐项隔离） | `.../closure-20261026-221524/shape-fixture-summary.json`、`shape-*.log` |
| 固定 Scoop 基准源码摘录 | `.../closure-20261026-221524/scoop-compat-source-citations.txt` |

## 逐项归因

盘点根内已安装的 `main/7zip`、`main/innounp` 不计入阻塞：它们是盘点根通过只读 junction 复用的 helper，计划返回 “Package already exists; use update”，不是机制缺口。

### psmodule（28）→ R25

`main/acmesharp`、`main/azure-ps`、`main/gsudo`、`main/importexcel`、`main/pester`、`main/powershell-beautifier`、`main/powershell-yaml`、`main/psake`、`main/pscompletions`、`main/psgithub`、`main/winget-ps`、`extras/completionpredictor`、`extras/dockercompletion`、`extras/git-aliases`、`extras/lazy-posh-git`、`extras/leet`、`extras/posh-docker`、`extras/posh-git`、`extras/powertab`、`extras/pscolor`、`extras/pseps`、`extras/psfzf`、`extras/pskubectlcompletion`、`extras/psreadline`、`extras/scoop-completion`、`extras/terminal-icons`、`extras/z`、`extras/zlocation`。

Adapter 一旦读到 `psmodule` 就把它当作未支持能力（`src/ir_adapter.cpp:351-355`），所以 28 个包全部停在写入前。固定 Scoop v0.6.0 的 `psmodules.ps1:1-53` 只做两件事：把 `<root>/modules/<name>` junction 到 `$dir`，并把 `<root>/modules` 前置进 `PSModulePath`（保存/撤销由环境层负责）；没有额外专有语义，也不是脚本才能实现的能力。

### 依赖自身不受支持（2）→ R25 级联

`main/inadyn-mt`（依赖 `gsudo`）、`extras/lazy-posh-git`（依赖 `posh-git`）。这两条不是独立机制缺口：依赖解析在写入前正确传播了被依赖包的 psmodule 阻塞。R25 完成后它们应自然消失；本页不把它们单列为新机制。

### 命令入口宿主（11）→ R26

`main/git-filter-repo`、`main/git-quick-stats`、`main/lsix`、`main/neofetch`、`main/pulumi`（无扩展名）；`main/retdec`、`main/vapoursynth`、`extras/pdd`（`.py`）；`main/xtensa-esp32-elf`（`.config`）；`extras/ani-cli`、`extras/controlprinters`（无扩展名）。

Coop 的入口宿主只有 EXE/COM/BAT/CMD/PS1/JAR（`src/ir_adapter.cpp:252-255`）。固定 Scoop `core.ps1:1076-1116` 对 `.py` 生成 `@python "target" %*` 的 cmd/sh shim，对其余后缀（无扩展名、`.config` 等）走 else 分支生成 bash shim。这是宿主类型缺口，不是“这些包不可用”。

### Manifest 形状、相对路径与重复别名（6）→ R27

- `main/dcmtk`：`env_add_path: "./bin/"` 在逐段校验时因尾分隔符产生空组件被拒（`src/ir_adapter.cpp:36-46`、`src/data.cpp:87-92`）。Scoop 用 `Join-Path $dir $_ | Get-AbsolutePath` 接受该写法（`install.ps1:309-318`）。
- `main/stdiscosrv`（5 元素）、`main/wgcf`（4 元素）、`main/zigup`（4 元素）：`bin` 元组超过 3 个元素即被拒（`src/ir_adapter.cpp:245`）。Scoop 的 `shim_def` 把别名之后的全部元素作为参数数组转交 shim（`install.ps1:171-193`）；`zigup` 的 `env_add_path: "."` 本身可接受，失败发生在更早的 bin 校验。
- `main/retdec`：`retdec-unpacker.exe` 与 `retdec-unpacker.py` 派生同名别名，Coop 硬失败（`src/ir_adapter.cpp:248-250`）；Scoop 覆盖旧 shim 并给出警告，最终保留后一个定义（`core.ps1:937-947`）。
- `extras/mqtt-spy`：快捷方式目标 `..\..\..\shims\mqtt-spy.cmd` 含父目录组件被拒（`src/ir_adapter.cpp:36-46`）；Scoop 与 `$dir` 组合后按 `FileInfo` 解析，允许指向包目录之外（`shortcuts.ps1:1-22`）。

本项目内最小 fixture 把四类成因逐项隔离（证据 `shape-fixture-summary.json`）：`env_add_path: "./bin/"`、4 元素 `bin` 元组、`..` 快捷方式目标、同名派生别名各自单独触发 `adapter/manifest-shape`；而单独存在的 `env_add_path: "."` 可接受（exit 0），所以 `zigup` 的失败确实来自更早的 bin 元组，不是 `"."` 写法。

这四类都是 Scoop 实际接受的形状；处置必须同时保留 Coop 对绝对路径、盘符、越界写入的既有安全拒绝（R27 验收第 4 条）。

### 跨 bucket 依赖缺失（5）→ R28

`main/buck` → `versions/python27`，`main/glslviewer` → `versions/ffmpeg-shared-4.4.1`，`main/terraform-provider-ibm` → `versions/terraform011`，`extras/node-compiler` → `versions/python27`，`extras/rabbitmqadmin` → `python27`。

这些依赖包属于官方 `versions` bucket，本机共用根没有注册它，所以计划在写入前按缺失来源拒绝。Coop 的跨 bucket 解析本身可用：项目内 fixture 在 `buckets/versions/bucket/python27.json` 存在时给出 `versions/python27@2.7.18` 先于主包的顺序且计划可执行；移除该 bucket 后给出 `ir/dependency-missing`（证据见上表）。R28 负责用固定修订的官方 `versions` bucket 对该结论做真实规模验证；共享根是否注册 `versions` 仍由人类决定，不接受把环境前提写成“产品不支持”。

### 架构边界（3，不建子票）

`main/gel-arm64`、`main/llvm-arm64`、`extras/cpu-z-arm64` 只声明 `architecture.arm64` 产物。在 x64 主机按 64bit 规划时给出 `ir/missing-artifact` 是正确的：固定 Scoop `manifest.ps1:156-181` 的 `Get-SupportedArchitecture` 对所选架构没有 `url` 的 Manifest 同样返回空并拒绝安装。本轮实测 `--arch arm64` 下三者均 `execution_available=true`、6/6/9 个操作，说明机制本身可用；arm64 真实生命周期因没有 arm64 主机而保持“未运行”，由 #45 如实列出，不作为已支持或已排除。

## 与 Scoop 兼容基准的对照

固定兼容库版本为 Scoop v0.6.0（`e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f`，`scoop-lib/LICENSE` 随构建分发）。上述判断逐条对照以下实现，完整摘录见证据 `scoop-compat-source-citations.txt`：

| 语义 | 位置 |
| --- | --- |
| `shim()` 按后缀选择 EXE/COM、BAT/CMD、PS1、JAR、PY、else(bash) 宿主 | `core.ps1:949-1116` |
| shim 覆盖旧文件并警告（last-wins） | `core.ps1:937-947` |
| `bin` 元组保留别名后的全部参数 | `install.ps1:171-193` |
| `env_add_path` 组合 `$dir` 后解析绝对路径 | `install.ps1:309-318` |
| 快捷方式目标/图标与 `$dir` 组合后按 FileInfo 解析 | `shortcuts.ps1:1-22` |
| 架构选择与不支持架构的拒绝 | `manifest.ps1:156-181` |
| psmodule 的 junction 与 PSModulePath | `psmodules.ps1:1-53` |

## 提议子票

账本 `tests/coverage/gaps.json` 的 `tickets` 数组是建票依据：`id`、`title`、`scope`、`reason`、`acceptance`、`depends_on`、`blocks`、`verification`。调度方按现有 #21 子票模板生成正文（`## Parent` / `## What to build` / `## Acceptance criteria` / `## 执行与证据`），`scope` 对应 What to build，`acceptance` 逐条对应勾选项，并沿用统一“执行与证据”段落。

### R25：psmodule 机制与依赖级联

- **What to build**：把 `psmodule` 归一为 IR 模块名；计划与执行创建 `<root>/modules/<name>` → 安装目录的 junction，并按 Scoop 语义维护用户级 `PSModulePath`（保存原值与归属，撤销只删除 Coop 写入的条目和 junction）；安装器、脚本、入口、卸载路径复用现有机制。
- **独立验收**：真实安装 `extras/posh-git` 后 junction 与 `PSModulePath` 生效、新 PowerShell 进程 `Import-Module posh-git` 成功；卸载撤销且保留用户后续修改；`--dry-run` 无写入；`main/gsudo` 组合声明可执行；`inadyn-mt`、`lazy-posh-git` 不再级联失败；重新盘点 `psmodule` 缺口归零；Scoop 随后识别同一模块。
- **依赖关系**：不依赖其他新票；blocks #42、#45。

### R26：命令入口宿主扩展

- **What to build**：按固定 Scoop shim 分支实现 `.py`（python 宿主）、无扩展名与 `.config`（bash 宿主）；生成与 Scoop 同形的 shim；宿主缺失时执行前明确诊断，不静默失败。
- **独立验收**：三类宿主在项目内根真实运行并核对输出/退出码；真实样本 `install --dry-run` 不再报宿主缺口，至少两个真实安装并运行版本/帮助命令；shim 与 Scoop 同形、Scoop 可用；重新盘点宿主缺口归零，剩余缺口逐项列出外部程序，不改成“不支持”。
- **依赖关系**：不依赖其他新票；blocks #42、#45。

### R27：Manifest 形状、相对路径与重复别名兼容

- **What to build**：接受任意长度 `bin` 元组、`env_add_path` 的 `./`/尾分隔符写法、`shortcuts` 目标与图标的 `..` 相对路径、重复派生别名的 Scoop last-wins 覆盖；保留绝对路径、盘符、越界写入的安全拒绝。
- **独立验收**：6 个样本 `install --dry-run` 可执行且与 Scoop 解析结果逐项一致；至少两个样本真实安装/运行/卸载，核对多参数 shim、PATH、快捷方式；`retdec` 覆盖行为与 Scoop 一致并给出警告；安全边界回归；重新盘点形状缺口归零。
- **依赖关系**：不依赖其他新票；blocks #42、#45。

### R28：跨 bucket 依赖来源（versions bucket）验证

- **What to build**：用项目内固定的官方 `versions` bucket（只读修订）验证 5 个包的 `versions/*` 依赖顺序与环境诊断；若 bucket 限定名/版本化包名解析有缺陷才修核心。
- **独立验收**：记录 `versions` bucket 40 位修订；5 个包计划依赖顺序正确且可执行（或对确实缺失项给出去重诊断）；至少一个样本验证已安装依赖复用；共享根注册与否由人类决定并如实记录环境前提；重新盘点 `dependency-missing` 归零或逐项环境前提；级联项不重复计数。
- **依赖关系**：不依赖其他新票；blocks #42、#45。

### 建议的原生关系（调度方执行）

1. 创建 R25–R28 为 #21 子票，正文取 `tests/coverage/gaps.json` 的对应对象与统一模板。
2. 为 R25–R28 增加 `blocking: #42, #45`；为 #42 增加 `blocked-by: R25–R28`；为 #45 增加 `blocked-by: R25–R28`（保留已有 #43、#44 关系）。
3. R25–R28 自身不加 `blocked-by #42`：它们是 #42 的解决出口，加反向阻塞会形成环，也会让 #42 永远无法关闭。
4. #43 现有 `blocked-by #42` 保留时，原生顺序为 R25–R28 → #42 → #43 → #44 → #45；若希望先做 #43 的路径移除，需由调度方显式调整该关系并在 #42 记录，不能由实现代理自行改票。

## 剩余风险与后续核对

- 本票**未安装**这 53 个包，也未运行 arm64 真实程序、未在共享根注册 `versions` bucket；这些明确标为“未运行/环境前提”，由 R25–R28 和 #45 承担。
- 子票完成后需用同一 `tests/real-scoop-coverage.ps1` 重新盘点（固定修订），预期：`psmodule`、`dependency-unsupported`、`command-entry-host`、`manifest-shape` 归零；`dependency-missing` 归零或仅剩带环境前提的条目；3 个 arm64-only 在 64bit 下仍按设计拒绝。若盘点修订前移出现新机制，应再次走本票的“逐项归因 + 独立子票”流程，不能直接关闭 #42。
- 守卫 `coverage_gaps` 固定在当前 6 个机制和 53 个包；盘点基线更新时必须同步账本，否则 CTest 失败——这是有意的，避免数字漂移后静默丢包。
- 本轮证据都在 `.local/pi/tasks/42/evidence/closure-20261026-221524/`，不随仓库分发；重放需要项目内盘点根 `.local/coverage/root` 与同一轮 `coop.exe`，重放脚本已随证据保存。共享真实 Scoop 根本轮只读，未做写入。
