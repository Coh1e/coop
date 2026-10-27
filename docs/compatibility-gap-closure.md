# 全量盘点缺口闭合与子票（R21/#42）

> **子票进展（2026-10-27）：** [R27/#48](https://github.com/Coh1e/coop/issues/48) 已完成并在当前实际 Main 修订上复测：`manifest-shape` 6 → **0**，计划可执行 4131 → **4136**，阻塞 16 → **11**；`main/retdec` 的重复别名不再阻塞，它的 `.py` 入口与原有 `vapoursynth`/`pdd` 一样在默认 PATH 下如实归为 `external-host:python` 环境前提。实现、六包逐项对照、真实共用根交替与证据见[Manifest 形状、相对路径与重复别名兼容](manifest-shape-support.md)。

> **子票进展（2026-10-27）：** [R26/#47](https://github.com/Coh1e/coop/issues/47) 已完成并在同一固定修订上复测：`command-entry-host` 11 → **0**，13 条 `adapter/unsupported-command-host` 诊断 → **0**；计划可执行 4123 → **4131**，阻塞 24 → **16**。默认用户 PATH 无真实 `python.exe`，`main/vapoursynth`、`extras/pdd` 如实归为 `external-host:python` 2 项环境前提，不改成“不支持”。实现、真实共用根运行与证据见[命令入口宿主扩展（.py、无扩展名、.config）](command-entry-support.md)。

> [R25/#46](https://github.com/Coh1e/coop/issues/46) 已完成并在同一固定修订上复测：`capability:psmodule` 28 → 0、`dependency-unsupported` 2 → 0，阻塞包 53 → 24（命令入口宿主 11、Manifest 形状 6、依赖缺失 5、arm64 产物 3），计划可执行 4094 → 4123。实现与证据见 [PowerShell 模块暴露（psmodule）](psmodule-support.md)；本页下文的基线归因与子票提议保留为发现阶段记录，不因复测而改写。

> **子票进展（2026-10-27）：** [R28/#49](https://github.com/Coh1e/coop/issues/49) 已完成：官方 `versions` bucket 按 40 位修订 `8050ef41c72c2124b864692665ca62d34659b8bc` 固定在 [`tests/coverage/dependency-sources.json`](../tests/coverage/dependency-sources.json)，同一固定分母上重测 `dependency-missing` 5 → **0**，5 个包的 `versions/*` 依赖全部进入 `dependency_order` 首位且计划可执行，计划可执行 4136 → **4141**，阻塞 11 → **6**（arm64 产物 3、`external-host:python` 3）。真实共用根上完成固定修订注册、`versions/terraform011` 真实安装、`main/terraform-provider-ibm` 复用与安装、主动卸载与完整还原。实现、逐项验收与证据见[依赖安装与反向依赖保护](dependency-support.md)。

> 本页把 [R20/#41 全量盘点](coverage-report.md)暴露的 **53 个计划阻塞包（55 行，按机制去重前）**逐项归因，给出可独立验收的子票，并记录四票完成后的闭合核对。机器可核对账本是 [`tests/coverage/gaps.json`](../tests/coverage/gaps.json)，由 CTest `coverage_gaps` 守卫，其中包含每行的闭合状态与剩余清单。本票负责发现闭合、拆票和子票完成后的闭合核对，不重复实现子票的产品代码；子票 R25–R28（#46–#49）已关闭，闭合核对结果为 **49/55 行已解决**，剩余 6 行为 3 个明确的 Python 宿主环境前提和 3 个人类已批准的 ARM64 生命周期例外。

## 结论

- **子票全部完成并关闭：** [R25/#46](https://github.com/Coh1e/coop/issues/46)、[R26/#47](https://github.com/Coh1e/coop/issues/47)、[R27/#48](https://github.com/Coh1e/coop/issues/48)、[R28/#49](https://github.com/Coh1e/coop/issues/49)。原生关系已建立：四票各自 blocking #42 与 #45，#42 的 blocked-by 已包含四票；#42 在闭合核对通过后由调度方处理关闭，#45 继续做最终整体验收。
- **闭合核对（2026-10-27，head `991e675`）：** 同一 53 个基线包在当前盘点根重放，**49/55 行已解决**（psmodule 28、依赖级联 2、命令入口宿主 8、Manifest 形状 6、跨 bucket 依赖 5）；剩余 6 行是 3 个 `external-host:python` 环境前提（`main/retdec`、`main/vapoursynth`、`extras/pdd`，默认用户 PATH 无真实 `python.exe`）和 3 个 arm64-only 包（64bit 按设计与 Scoop 一致拒绝，ARM64 生命周期为例外未运行）。没有任何包被移出分母，也没有把缺口改写为“不支持”。
- **全量分母复测（R28/#49，`ce49eff`）：** Main `eebcee22…` 1701 + Extras `0f8f4b5f…` 2448 = 4149，读取 4149/4149、计划可执行 **4141**、阻塞 **6**（arm64 3 + `external-host:python` 3）；当前 head `991e675` 与该测量 head 之间只有文档差异，`coop.exe` SHA256 相同，因此不重复全量盘点。
- **ARM64 例外已由人类批准（2026-10-27）：** 仅限 `main/gel-arm64`、`main/llvm-arm64`、`extras/cpu-z-arm64` 三者的生命周期实跑例外；它们保留在完整分母中，ARM64 生命周期标记为未运行/未验证，x64 不适用与 `--arch arm64` 规划证据单列，不能算作 ARM64 安装、更新或运行已验证。该批准不扩展到其他缺口或未运行软件，#45 必须逐项列出。
- 六个机制与处置的对应关系、每条账目的闭合状态和剩余清单都由守卫固定；减少条目、改投子票、删掉验收条件、把环境前提或已批准例外标成已解决都会让 `coverage_gaps` 失败。

| 机制（baseline） | 包数 | 诊断码 | 子票 | 闭合状态（2026-10-27） |
| --- | ---: | --- | --- | --- |
| `capability:psmodule` | 28 | `adapter/unsupported-capability` | R25/#46 | 28 行已解决 |
| `dependency-unsupported` | 2 | `capability/dependency-unsupported` | R25/#46 | 2 行已解决（级联消失） |
| `command-entry-host` | 11 | `adapter/unsupported-command-host` | R26/#47 | 8 行已解决；3 行 `external-host:python` 环境前提 |
| `manifest-shape` | 6 | `adapter/manifest-shape` | R27/#48 | 6 行已解决 |
| `dependency-missing` | 5 | `ir/dependency-missing` | R28/#49 | 5 行已解决 |
| `architecture-artifact` | 3 | `ir/missing-artifact` | 无（人类批准例外） | 3 行 approved-exception，ARM64 生命周期未运行 |

`retdec` 同时属于 `command-entry-host` 与 `manifest-shape`，`lazy-posh-git` 同时属于 `capability:psmodule` 与 `dependency-unsupported`，因此机制行计数之和为 55，唯一包为 53。

## 口径与复现

盘点基线来自 #41 的测量提交 `8283e6a062f5044f8a180ede05634c0efca619c7`：Main `5be7f8c702856c72800a0a4945b88fe6ea2bd52f` 1701 份 + Extras `0f8f4b5fd43bedccc7b233b77f4605bddba8085b` 2448 份 = 4149 份 Manifest，4094 份计划可执行、53 份被阻塞、2 份在盘点根内已安装 helper、15 份有真机运行事实、4134 份未运行。本文不重新解释盘点结果，只消费同一份 `tests/coverage/baseline.json`。

2026-10-26（发现阶段）用真实 CLI 在同一项目内盘点根逐包重放阻塞诊断（只读，不下载、不安装）：

```powershell
pwsh -NoProfile -File .local/pi/tasks/42/evidence/closure-20261026-221524/repro-gaps.ps1
# 53 个包全部 exit 1、execution_available=false，诊断码与 baseline 逐项一致；
# 3 个 arm64-only 包在 --arch arm64 下 exit 0、execution_available=true、architecture=arm64。
```

### 闭合核对（2026-10-27）

四票完成后，本票在同一盘点根用当前构建重放同一 53 个基线包（只做 dry-run，不安装、不下载），并核对每行的闭合状态：

```powershell
pwsh -NoProfile -File .local/pi/tasks/42/evidence/closure-verify-20261027-060914/closure-verify.ps1
# head 991e675，coop sha256 20e8fdbc…19ddbf，Main eebcee22 / Extras 0f8f4b5f / versions 8050ef41
# 49/55 行 resolved；3 行 blocked-precondition（retdec/vapoursynth/pdd）；3 行 approved-exception（三个 arm64-only 包）
# 全量分母复用 R28/#49 的 ce49eff 测量：4149 份、计划可执行 4141、阻塞 6；ce49eff..991e675 只有文档差异，二进制 SHA256 相同
```

闭合核对建立在子票各自的真实验收之上（[psmodule](psmodule-support.md)、[命令入口宿主](command-entry-support.md)、[Manifest 形状](manifest-shape-support.md)、[跨 bucket 依赖](dependency-support.md)），本票不重复子票的真实安装/卸载运行，只在同一基线集合上证实缺口已经消失或降为可核对的剩余项。

证据（被忽略的项目内目录，不随仓库分发）：

| 内容 | 位置 |
| --- | --- |
| 53 包重放汇总（2026-10-26 基线重放，历史） | `.local/pi/tasks/42/evidence/closure-20261026-221524/repro-summary.json` |
| 53 包逐包 dry-run JSON（历史） | `.../closure-20261026-221524/packages/` |
| 重放完整输出（历史，退出 0） | `.../closure-20261026-221524/repro-gaps.log` |
| 跨 bucket 依赖 fixture（有/无 versions bucket，历史） | `.../closure-20261026-221524/dependency-fixture-summary.json`、`dependency-bucket-present.log`、`dependency-bucket-absent.log` |
| **作废：** 旧 Manifest 形状 fixture（bin-four 实为四个扁平条目，证据不成立，文件保留未改） | `.../closure-20261026-221524/shape-fixture-summary.json`、`shape-*.log` |
| **闭合核对（2026-10-27）** 53 包逐项状态、arm64 规划、全量分母复用核对 | `.../closure-verify-20261027-060914/closure-verify-summary.json`、`closure-verify.log` |
| **修正后的 Manifest 形状 fixture**（单条 4 元素元组；历史构建观测 `Invalid bin entry`，当前构建接受） | `.../closure-verify-20261027-060914/shape-fixture-summary.json`、`shape-*.log` |
| 固定 Scoop 基准源码摘录（历史，代码引用未变） | `.../closure-20261026-221524/scoop-compat-source-citations.txt` |

## 逐项归因

> 以下为 2026-10-26 发现阶段的现状描述与当时的建议，用于追溯为什么拆出这些子票；它不是当前 head 的行为。当前状态以上方闭合核对、账本 `closure` 块和各子票机制文档为准。

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

本项目内修正后的最小 fixture 把四类成因逐项隔离（证据 `closure-verify-20261027-060914/shape-fixture-summary.json`）：单条嵌套 4 元素 `bin` 元组在历史 pre-R27 构建 `.local/build-clean/coop.exe`（SHA256 `b23b411c…`）上确实触发 `Invalid bin entry`，当前 head `991e675` 上同一 Manifest 计划可执行（R27 已修复）；`env_add_path: "./bin/"`、`..` 快捷方式目标和两个 exe 的同名派生别名也分别单独触发对应的历史诊断，单独存在的 `env_add_path: "."` 可接受。

**更正（2026-10-27）：** 旧的 `closure-20261026-221524/shape-*` fixture 中 `bin-four` 被写成四个扁平的 bin 条目（每个字符串一个条目），实际复现的是 `Duplicate command alias` 而不是 4 元素元组超长，因此旧证据**作废**，文件保留未改、不得再作为逐项隔离的依据；verifier 的 P2 发现由此关闭。

这四类都是 Scoop 实际接受的形状；处置必须同时保留 Coop 对绝对路径、盘符、越界写入的既有安全拒绝（R27 验收第 4 条）。

### 跨 bucket 依赖缺失（5）→ R28

`main/buck` → `versions/python27`，`main/glslviewer` → `versions/ffmpeg-shared-4.4.1`，`main/terraform-provider-ibm` → `versions/terraform011`，`extras/node-compiler` → `versions/python27`，`extras/rabbitmqadmin` → `python27`。

这些依赖包属于官方 `versions` bucket，本机共用根没有注册它，所以计划在写入前按缺失来源拒绝。Coop 的跨 bucket 解析本身可用：项目内 fixture 在 `buckets/versions/bucket/python27.json` 存在时给出 `versions/python27@2.7.18` 先于主包的顺序且计划可执行；移除该 bucket 后给出 `ir/dependency-missing`（证据见上表）。

**R28/#49 已完成（2026-10-27，代码提交 `ce49eff`）：** 官方 `versions` bucket 的来源与 40 位修订固定在 `tests/coverage/dependency-sources.json`，盘点脚本按它注册只读副本且不进入分母；同一 Main `eebcee22…`／Extras `0f8f4b5f…` 分母上 `dependency-missing` 归零，5 个包的解析结果为 `versions/python27@2.7.18`、`versions/ffmpeg-shared-4.4.1@4.4.1`、`versions/terraform011@0.11.15`，均排在请求包之前且 `execution_available=true`。真实共用根上注册固定修订后：三个可用的 Main 样本 dry-run 均可执行；`versions/terraform011` 真实安装并可运行，`main/terraform-provider-ibm` 复用该依赖（`installed=true`、`skipped/already-installed`）后安装成功，日志与预览一致；卸载主包不连带依赖，依赖显式卸载后移除本轮注册与克隆，注册文件逐字节还原、原有 bucket/本地修改/15 个安装包不变。依赖声明去重：同一 Manifest 重复声明同一依赖只报一条相同诊断（真实 Main/Extras 未出现重复声明，回归由 `tests/versions-bucket.ps1` 覆盖）。细则与证据见[依赖安装与反向依赖保护](dependency-support.md)。R28 已经用固定修订的官方 `versions` bucket 完成真实规模验证；共享根上的注册是受权测试操作，完成后连同克隆、依赖产物与注册记录一起还原，原有 bucket 与本地修改不变。环境前提仍不得写成“产品不支持”。

### 架构边界（3，人类批准的例外）

`main/gel-arm64`、`main/llvm-arm64`、`extras/cpu-z-arm64` 只声明 `architecture.arm64` 产物。在 x64 主机按 64bit 规划时给出 `ir/missing-artifact` 是正确的：固定 Scoop `manifest.ps1:156-181` 的 `Get-SupportedArchitecture` 对所选架构没有 `url` 的 Manifest 同样返回空并拒绝安装。本轮实测 `--arch arm64` 下三者均 `execution_available=true`、6/6/9 个操作，说明机制本身可用；arm64 真实生命周期因没有 arm64 主机而保持“未运行”。

**人类批准（2026-10-27，记录于 #42/#45 评论）：** 接受本轮这 3 个 ARM64-only 包的生命周期实跑例外。完整 Main/Extras 分母保留，逐包标记 ARM64 生命周期未运行/未验证；x64 不适用及 `--arch arm64` 规划证据单列，不能算成 ARM64 安装、更新或运行已验证。批准仅限该 3 项，不扩展到其他兼容缺口或未运行软件。账本 `closure.human_approvals` 与 `boundaries[].approval_*` 记录同一范围，守卫要求日期与范围存在。

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

## 子票与交付结果

账本 `tests/coverage/gaps.json` 的 `tickets` 数组保留了 proposal 阶段的 `scope`、`reason`、`acceptance`、`verification`，并新增 `issue`、`issue_state=closed`、`delivered` 和 `closure_evidence`。R25–R28 已按 #21 子票模板创建为 #46–#49 并关闭；下方是实际交付与验收摘要，正文细节以各子票的 Issue/验收记录和对应机制文档为准。

### R25：psmodule 机制与依赖级联

- **状态：** 已完成并关闭（[#46](https://github.com/Coh1e/coop/issues/46)，提交 `1a7ac81`）；结果 28/28 个 psmodule 包计划可执行，依赖级联 2 个消失，真实 posh-git/gsudo 生命周期与 Scoop 读取见 [PowerShell 模块暴露（psmodule）](psmodule-support.md)。
- **What to build**：把 `psmodule` 归一为 IR 模块名；计划与执行创建 `<root>/modules/<name>` → 安装目录的 junction，并按 Scoop 语义维护用户级 `PSModulePath`（保存原值与归属，撤销只删除 Coop 写入的条目和 junction）；安装器、脚本、入口、卸载路径复用现有机制。
- **独立验收**：真实安装 `extras/posh-git` 后 junction 与 `PSModulePath` 生效、新 PowerShell 进程 `Import-Module posh-git` 成功；卸载撤销且保留用户后续修改；`--dry-run` 无写入；`main/gsudo` 组合声明可执行；`inadyn-mt`、`lazy-posh-git` 不再级联失败；重新盘点 `psmodule` 缺口归零；Scoop 随后识别同一模块。
- **依赖关系**：不依赖其他新票；blocking #42、#45（已建立）。

### R26：命令入口宿主扩展

- **状态：** 已完成并关闭（[#47](https://github.com/Coh1e/coop/issues/47)，提交 `5652f09`）；`command-entry-host` 11 → 0，13 条 unsupported-command-host 诊断消失；3 个 `.py` 包如实降为 `external-host:python` 环境前提。细则见[命令入口宿主扩展（.py、无扩展名、.config）](command-entry-support.md)。
- **What to build**：按固定 Scoop shim 分支实现 `.py`（python 宿主）、无扩展名与 `.config`（bash 宿主）；生成与 Scoop 同形的 shim；宿主缺失时执行前明确诊断，不静默失败。
- **独立验收**：三类宿主在项目内根真实运行并核对输出/退出码；真实样本 `install --dry-run` 不再报宿主缺口，至少两个真实安装并运行版本/帮助命令；shim 与 Scoop 同形、Scoop 可用；重新盘点宿主缺口归零，剩余缺口逐项列出外部程序，不改成“不支持”。
- **依赖关系**：不依赖其他新票；blocking #42、#45（已建立）。

### R27：Manifest 形状、相对路径与重复别名兼容

- **状态：** 已完成并关闭（[#48](https://github.com/Coh1e/coop/issues/48)，提交 `1d0bea1`）；`manifest-shape` 6 → 0，六个包逐项对照与真实共用根交替见[Manifest 形状、相对路径与重复别名兼容](manifest-shape-support.md)。
- **What to build**：接受任意长度 `bin` 元组、`env_add_path` 的 `./`/尾分隔符写法、`shortcuts` 目标与图标的 `..` 相对路径、重复派生别名的 Scoop last-wins 覆盖；保留绝对路径、盘符、越界写入的安全拒绝。
- **独立验收**：6 个样本 `install --dry-run` 可执行且与 Scoop 解析结果逐项一致；至少两个样本真实安装/运行/卸载，核对多参数 shim、PATH、快捷方式；`retdec` 覆盖行为与 Scoop 一致并给出警告；安全边界回归；重新盘点形状缺口归零。
- **依赖关系**：不依赖其他新票；blocking #42、#45（已建立）。

### R28：跨 bucket 依赖来源（versions bucket）验证

- **状态：** 已完成并关闭（[#49](https://github.com/Coh1e/coop/issues/49)，代码提交 `ce49eff`）；结果与证据见[依赖安装与反向依赖保护](dependency-support.md)。
- **What to build（已交付）：** 项目内固定官方 `versions` bucket 的来源与 40 位修订（`tests/coverage/dependency-sources.json`，不入分母），用同一 Main/Extras 修订验证 5 个包的 `versions/*` 依赖顺序与缺失/环境影响；同一 Manifest 重复声明同一依赖的相同诊断去重；bucket 限定名与版本化包名（`python27`、`ffmpeg-shared-4.4.1`、`terraform011`）解析无缺陷，未改核心解析路径。
- **独立验收结果：** 5 个包 `install --dry-run` 的 `dependency_order` 含 `versions/*` 且 `execution_available=true`；已安装依赖复用（`installed=true`、`ir_operations` 为空、执行记为 `skipped/already-installed`）与依赖先于主包顺序在项目内 fixture 和真实共用根上都得到；重新盘点 `dependency-missing` 为 0；级联项仍只归 R25，不重复计数。
- **未运行/环境前提：** Extras 的两个包（`extras/node-compiler`、`extras/rabbitmqadmin`）只在项目内盘点根（同一固定修订）验证计划；本机共用 Scoop 根未注册 Extras，因此没有它们的真实安装结果。共用根只新增了本轮 `versions` 注册，并已连同克隆与依赖产物、`%APPDATA%\terraform.d` 测试新增文件一起还原。

### 原生关系（已建立）

1. R25–R28 已创建为 #21 子票 #46–#49，正文取自当时的提议对象与模板。
2. 四票各自 `blocking: #42, #45`；#42 与 #45 的 `blocked-by` 均已包含四票（保留原有 #33/#34/#35/#40/#41 等已关闭关系）。
3. 四票本身没有 `blocked-by #42`，避免环；四票已各自独立完成并按票关闭。
4. #42 的现有 `blocking: #43, #45` 保持不变；原生顺序为 R25–R28 → #42 → #43 → #44 → #45，若调度方要调整需在 #42 记录，不由实现代理改票。

## 剩余风险与后续核对

- **闭合核对只重放计划，不重复安装：** 53 个基线包的当前状态来自 `install --dry-run`；真实安装/卸载/运行证据由 R25–R28 各自承担（psmodule、命令入口、Manifest 形状、跨 bucket 依赖四个机制文档）。#42 没有重新安装这 53 个包，不能把计划可执行当成生命周期验证。
- **3 个 Python 宿主前提未运行：** `main/retdec`、`main/vapoursynth`、`extras/pdd` 需要真实 `python.exe`；当前诊断给出可执行前置条件（安装 Python 3 或把 python.exe 加入 PATH），不是入口机制不支持。本轮没有安装 Python，也没有运行这三个包的入口；#45 必须带着该环境前提重新核对。
- **3 个 ARM64 例外未运行：** 人类批准的是“生命周期实跑例外”，不是“已验证”；ARM64 安装/更新/运行仍为未运行，#45 必须逐项列出，且不得把 `--arch arm64` 规划或 x64 拒绝算作 ARM64 运行证据。
- **其余 4134 个包仍为未运行：** 全量盘点的计划可执行 4141/4149 不等于逐包生命周期通过；#45 仍需从最终构建执行整体验收。#42 没有修改产品代码，当前 head 与 R28 测量 head 之间只有文档差异。
- **守卫绑定当前基线：** `coverage_gaps` 固定在 R20/#41 的 6 个机制、53 个包和当前剩余集合；若盘点修订前移出现新机制，必须再次逐项归因、更新账本并重新拆票，不能直接关闭 #42。
- **证据有效性：** 2026-10-26 的 53 包重放与旧 `shape-*` fixture 是历史证据；旧 shape fixture 的 `bin-four` 不成立，文件保留但已作废，verifier P2 的更正证据在 `closure-verify-20261027-060914/shape-fixture-summary.json`。闭合核对在项目内盘点根只读执行；共享真实根的写操作仅发生在子票的受权验收中，本票没有新增写入。
