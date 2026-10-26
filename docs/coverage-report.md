# Main／Extras 全量兼容盘点（R20/#41）

> 本页记录 2026-10-27 对官方 Main、Extras **完整分母**的一次盘点：固定实际 bucket 修订，逐份 Manifest 记录机制声明、读取状态、规划状态和真机验证状态。命令、逐包记录与缺口清单在 `.local/pi/tasks/41/evidence/coverage-final3/coverage-20261026-212649/`；本页与 [`tests/coverage/baseline.json`](../tests/coverage/baseline.json) 只做汇总与索引。**读取或规划成功不等于运行验证**：本轮只有 15 个包在同一修订上具有真机运行事实，其余保持“未运行”。

## 结论

- 分母为 Main 1701 + Extras 2448 = **4149 份 Manifest**。Main 使用本机共用工作树实际检出的 `5be7f8c702856c72800a0a4945b88fe6ea2bd52f`；Extras 使用本轮从官方仓库取得的 `0f8f4b5fd43bedccc7b233b77f4605bddba8085b`（本机 Scoop 根没有注册 Extras）。两份 bucket 都由项目内副本固定，Main 的 1701 份 Manifest 与共用工作树逐字节一致。
- **读取：4149/4149 通过**（`coop info --json` 均返回有效 IR 校验结果），没有无法解析或无法生成诊断的 Manifest。
- **规划：4094/4149 的 64bit 安装预览可执行**；53 个包的预览明确 `execution_available=false`；另有 2 个 helper 包（`7zip`、`innounp`）在本次盘点根内表现为“已安装”，不计入缺口。
- **运行验证：15/4149**。这 15 个包正是 [#40 逐项交替验收](real-machine-acceptance.md) 的本机实际安装集合；其安装 Manifest 的 SHA256 与本轮分母完全一致，程序运行退出码均为 0。其余 4134 个包没有本轮运行事实。
- 53 个被阻塞的包归为 6 类机制缺口：`psmodule` 28、命令入口宿主 11、Manifest 形状/路径 6、依赖缺失 5、架构产物缺失 3、依赖自身不受支持 2；其中 2 个包各涉及两类，去重后 53。完整包名、诊断码与原文见下表与证据。
- ZIP、7z、tar、MSI、Inno Setup、NSIS 载荷、脚本、入口、快捷方式、持久化、环境、依赖、多产物、重命名、四种摘要算法等机制均出现在分母中并有对应计划；计划可执行不代表该机制已经逐包或逐生命周期跑过。

## 环境与修订

| 项目 | 值 |
| --- | --- |
| 平台 | Windows 11，x64（`10.0.26300.0`），PowerShell 7.6.5 |
| 共用 Scoop | Scoop v0.6.0（2026-09-30），根 `C:\Users\Neo\scoop` |
| Main 实际工作树修订 | `5be7f8c702856c72800a0a4945b88fe6ea2bd52f`（分支 `master`，1783 个文件） |
| Main Coop 注册表记录 | `89b4cf8078b4968bca637b2ae226b16e8d04dbce`（2026-10-26T05:09:07Z，**与工作树不一致**） |
| Extras 盘点修订 | `0f8f4b5fd43bedccc7b233b77f4605bddba8085b`（官方 `master` HEAD，本轮克隆取得，2643 个文件） |
| Coop | `coop 0.1.0`，SHA256 `76666fae4dad953acaf83c17f7270d3afad91dcd7a33efe5c0cab0dcc9588a79`；盘点代码提交 `b7a20b4f910734520b0c304bf90e99326cc18c3b`（当前文档提交只增加本页、基线与链接） |
| 盘点工具 | [`tests/real-scoop-coverage.ps1`](../tests/real-scoop-coverage.ps1) 与 [`tests/coverage-manifest-features.ps1`](../tests/coverage-manifest-features.ps1) |
| 规划接口 | 真实 `coop.exe --root <项目内盘点根> --arch 64bit info <bucket/包名> --json` 与 `install <bucket/包名> --dry-run --json`，8 个并行读取工作进程 |

### 为什么修订以工作树为准

`coop bucket list` 的 `revision` 是 Coop 上一次成功刷新的记录；本机 Scoop 此后推进过 `main` 工作树，因此记录停在 `89b4cf8…`。本轮没有把缓存记录当作实际数据：盘点脚本直接解析共用工作树 `.git/HEAD` 与引用，以实际检出的 `5be7f8c…` 克隆项目内副本，并逐份比较 1701 个 Manifest 的 SHA256（`missing=0`、`extra=0`、`mismatched=0`）。下一次显式 `coop bucket update main` 会按 #23 的刷新规则核对 HEAD 并补齐记录；本票只盘点，不刷新共用 bucket。

### 盘点根与 helper

- Main、Extras 的 Git 工作树克隆在项目内 `.local/coverage/root/buckets/`，不写入共用 Scoop 根；共用根在盘点前后做递归“路径+长度+修改时间”快照，变化数为 0。
- Inno Setup 与 NSIS 载荷需要 root 内已安装的 `innounp`／`7-Zip` helper。为测量本机真实能力，盘点根通过只读 junction 复用共用根已安装的 `apps/innounp/current`（2.71.2）与 `apps/7zip/current`（26.05），不复制、下载或修改 helper。
- 这两个 junction 使 `main/7zip` 与 `main/innounp` 自身的安装预览报告 `Package already exists; use update`。它们不是机制缺口，计划列外单列“环境内已安装”；两者都在 #40 的真机验证集合中。
- 规划只使用当前平台 64bit；32bit/arm64 声明只做结构统计，未实际执行。盘点不下载产物、不执行脚本、不写安装状态。

## 总数

| Bucket | Manifest | 读取通过 | 计划可执行 | 计划被阻塞 | 盘点根内已安装 | 真机运行包 | 未运行 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Main | 1701 | 1701 | 1670 | 29 | 2 | 15 | 1686 |
| Extras | 2448 | 2448 | 2424 | 24 | 0 | 0 | 2448 |
| **合计** | **4149** | **4149** | **4094** | **53** | **2** | **15** | **4134** |

“计划可执行”只表示 `install --dry-run` 给出的计划 `execution_available=true`；“真机运行包”只来自有程序运行事实且 Manifest 摘要一致的包（包级事实，详见下文）。两者不可互相替代。

## 机制状态

机制扫描覆盖 Manifest 根对象和每个架构对象；`checkver`/`autoupdate` 不计。同一份 Manifest 对同一字段只计一次，因此同一 Manifest 可出现在多行。“计划可执行”是整包计划，被无关缺口阻塞的包也会使该行计数减少。

“真机运行包”只表示该 Manifest 属于 #40 中程序真实运行且安装 Manifest 摘要一致的 15 个包；**它不证明该行声明的机制本身在 #40 中执行过**。例如 `uv` 的 `installer` 声明、`7zip`/`git` 的卸载脚本并没有在那一轮重跑。逐机制的运行证据仍以各机制文档和历史样本为准。因此“真机运行包”为 0 的行就是本轮**没有运行验证**的机制（例如 tar、Inno Setup、NSIS 载荷、全部非 EXE/BAT 命令宿主、`post_uninstall`、`extract_to`、多下载项），这不等于机制不受支持，也不能用计划成功替代。

### 产物与校验

| 机制 | Manifest | 读取通过 | 计划可执行 | 真机运行包 |
| --- | ---: | ---: | ---: | ---: |
| ZIP | 2302 | 2302 | 2287 | 12 |
| 7z | 597 | 597 | 596 | 2 |
| tar | 172 | 172 | 171 | 0 |
| MSI | 161 | 161 | 159 | 1 |
| Inno Setup `innosetup` | 149 | 149 | 149 | 0 |
| 单文件／无归档产物 | 792 | 792 | 759 | 0 |
| 多下载项 `url` 数组 | 101 | 101 | 98 | 0 |
| `#/` 重命名产物 | 915 | 915 | 911 | 1 |
| SHA256 | 3725 | 3725 | 3675 | 15 |
| SHA512 | 181 | 181 | 180 | 0 |
| SHA1 | 204 | 204 | 203 | 0 |
| MD5 | 40 | 40 | 40 | 0 |

产物与摘要算法行按 64bit 计划实际选中的产物/算法统计（一份 Manifest 可选多个算法时各计一次）；Manifest 根与架构对象里的原始 `tar.gz`/`tar.xz`/`tar.zst` 声明另计为 tar 家族。多下载项与 `#/` 重命名是没有对应计划字段的声明特征，因此按 Manifest 结构统计。原始 URL 还包含 `.exe`（1109 个包，计划归一为 `none`/`7z`/`msi`/`inno` 并按内容识别 NSIS）、无扩展名（289 个包，多为动态下载端点）等格式；本节只列主要机制族，**完整 59 行逐机制计数**（含各 `local.*`/`download.*` 变体与 `installer.args` 等）见 `tests/coverage/baseline.json` 的 `mechanisms` 与证据 `summary.json`。

NSIS 安装器载荷不靠 Manifest 字段声明，而是 408 个包的 executable 产物在校验后按内容识别；本轮 helper 可用，因此这 408 个计划可执行，但只有真实运行的包才能证明解包行为（本轮没有新增 NSIS 真机样本）。

### 结构与暴露

| 机制 | Manifest | 读取通过 | 计划可执行 | 真机运行包 |
| --- | ---: | ---: | ---: | ---: |
| `bin` 命令入口 | 3135 | 3135 | 3110 | 14 |
| `shortcuts` 快捷方式 | 2044 | 2044 | 2041 | 3 |
| `persist` 持久化 | 876 | 876 | 869 | 1 |
| `env_add_path` | 120 | 120 | 116 | 1 |
| `env_set` | 163 | 163 | 161 | 3 |
| `depends` 依赖 | 123 | 123 | 115 | 0 |
| `extract_dir` | 1274 | 1274 | 1259 | 4 |
| `extract_to` | 33 | 33 | 33 | 0 |
| `installer` 声明 | 238 | 238 | 236 | 1 |
| `installer.file`／`installer.args` | 7／10 | 7／10 | 7／10 | 0 |
| `uninstaller` 声明 | 165 | 165 | 162 | 3 |
| `uninstaller.file`／`uninstaller.args` | 4／2 | 4／2 | 4／2 | 0 |
| `psmodule` | 28 | 28 | **0** | 0 |
| 64bit 架构对象 | 3166 | 3166 | 3152 | 13 |
| 32bit 架构对象 | 1139 | 1139 | 1132 | 7 |
| arm64 架构对象 | 967 | 967 | 958 | 13 |

### 脚本阶段

| 阶段 | Manifest | 读取通过 | 计划可执行 | 真机运行包 |
| --- | ---: | ---: | ---: | ---: |
| 任意安装/卸载脚本 | 1303 | 1303 | 1274 | 3 |
| `pre_install` | 915 | 915 | 892 | 2 |
| `post_install` | 318 | 318 | 313 | 2 |
| `pre_uninstall` | 103 | 103 | 102 | 1 |
| `post_uninstall` | 25 | 25 | 25 | 0 |
| `installer.script` | 226 | 226 | 224 | 1 |
| `uninstaller.script` | 161 | 161 | 158 | 3 |

脚本机制本身没有“不支持”诊断：所有声明脚本的包都进入计划，脚本原文不受白名单限制；计划被阻塞的 28 个脚本包均来自 `psmodule`、依赖或命令入口等非脚本机制。脚本的真实 PowerShell 语义与真机样本见[生命周期 Hook 与真实 PowerShell](script-support.md)。

### 命令宿主

| 目标类型 | Manifest | 读取通过 | 计划可执行 | 真机运行包 |
| --- | ---: | ---: | ---: | ---: |
| EXE | 2896 | 2896 | 2881 | 13 |
| BAT | 108 | 108 | 107 | 1 |
| CMD | 45 | 45 | 44 | 0 |
| PS1 | 43 | 43 | 42 | 0 |
| JAR | 38 | 38 | 37 | 0 |
| COM | 7 | 7 | 7 | 0 |
| 无扩展名 | 34 | 34 | 27 | 0 |
| `.py` | 3 | 3 | **0** | 0 |
| `.config` | 1 | 1 | **0** | 0 |

## 未覆盖机制、受影响软件与诊断

下表是 53 个计划被阻塞包的去重归因；包名可在 `.local/pi/tasks/41/evidence/coverage-final3/coverage-20261026-212649/manifests.json` 或已提交的 `tests/coverage/baseline.json` 中逐项核对。`retdec` 同时有 Manifest 形状和命令宿主问题，`lazy-posh-git` 同时有 `psmodule` 依赖和依赖自身不受支持问题，所以分行计数之和为 55。

| 机制 | 包数 | 受影响软件 | 诊断 |
| --- | ---: | --- | --- |
| `psmodule` | 28 | main/acmesharp, main/azure-ps, main/gsudo, main/importexcel, main/pester, main/powershell-beautifier, main/powershell-yaml, main/psake, main/pscompletions, main/psgithub, main/winget-ps；extras/completionpredictor, extras/dockercompletion, extras/git-aliases, extras/lazy-posh-git, extras/leet, extras/posh-docker, extras/posh-git, extras/powertab, extras/pscolor, extras/pseps, extras/psfzf, extras/pskubectlcompletion, extras/psreadline, extras/scoop-completion, extras/terminal-icons, extras/z, extras/zlocation | `adapter/unsupported-capability`: `Not yet supported: psmodule`。PowerShell 模块安装（Scoop 的 `psmodule` 声明）尚未实现，属于明确的待办机制，不是“无脚本即不支持”。 |
| 命令入口宿主 | 11 | main/git-filter-repo, main/git-quick-stats, main/lsix, main/neofetch, main/pulumi, main/retdec, main/vapoursynth, main/xtensa-esp32-elf；extras/ani-cli, extras/controlprinters, extras/pdd | `adapter/unsupported-command-host`: 目标类型不在 EXE/COM/BAT/CMD/PS1/JAR 内，例如无扩展名脚本、`.py`、`.config`。参数转发与宿主选择已有机制，但未覆盖这些类型。 |
| Manifest 形状／路径 | 6 | main/dcmtk, main/retdec, main/stdiscosrv, main/wgcf, main/zigup；extras/mqtt-spy | `adapter/manifest-shape`: `Invalid path component`、`Duplicate command alias`、`Invalid bin entry`。这些是无效或当前无法安全归一化的声明，不是静默跳过。 |
| 依赖缺失 | 5 | main/buck, main/glslviewer, main/terraform-provider-ibm；extras/node-compiler, extras/rabbitmqadmin | `ir/dependency-missing`: 依赖 `versions/python27`、`versions/ffmpeg-shared-4.4.1`、`versions/terraform011`、`python27` 不在本地 bucket（`versions` 是 Scoop 的额外 bucket，本机未注册）。 |
| 架构产物缺失 | 3 | main/gel-arm64, main/llvm-arm64；extras/cpu-z-arm64 | `ir/missing-artifact`: `No artifact for selected architecture`。这些是 arm64 专用包在 64bit 规划下没有产物；arm64 真机执行不在本轮。 |
| 依赖自身不受支持 | 2 | main/inadyn-mt；extras/lazy-posh-git | `capability/dependency-unsupported`: 依赖 `gsudo`／`posh-git` 自身被阻塞，因而主包也在写入前拒绝。 |

除此之外没有出现 `plan unavailable`、读取失败或未分类阻塞。仍被列为“计划可执行”的机制不代表行为完整：例如 Inno 149 个包依赖外部 `innounp` helper，NSIS 408 个包依赖外部 7-Zip helper，helper 缺失时会在执行前阻塞。helper 的可检测、不自动安装策略见[Installer/Uninstaller 与特殊安装机制](installer-support.md)。

## 真机已验证的 15 个包

来源为 [#40](https://github.com/Coh1e/coop/issues/40) 的 `.local/pi/tasks/40/evidence/cohort-final3/cohort-20261026-201857/`。验证绑定条件：安装副本 `current/scoop-manifest.json` 的 SHA256 与本轮分母 Manifest 相同，且记录的程序运行退出码为 0；15/15 满足。这是**包级运行事实**，不是每个声明机制的生命周期证明。

| 包 | 记录版本 | 真机操作（来自 #40 lifecycle） |
| --- | --- | --- |
| 7zip | 26.05 | Scoop reset；Coop 切到 26.03 再回当前 |
| clink | 1.9.34 | Scoop reset；Coop 真实更新到 1.9.35；Scoop 卸载后 Coop 重装 |
| cmake | 4.4.4 | Scoop reset |
| fastfetch | 2.70.0 | Scoop reset；Coop 版本往返；Coop 卸载并重装 |
| fd | 10.5.0 | Scoop reset；Coop 版本往返 |
| fzf | 0.74.5 | Scoop reset；Coop 版本往返 |
| gh | 2.103.2 | Scoop reset |
| git | 2.56.0.3 | Scoop reset；Coop 版本往返；Scoop 真实更新到 2.56.0.4 后 Coop 识别 |
| innounp | 2.71.2 | Scoop reset；Coop 版本往返 |
| ninja | 1.13.2 | Scoop reset |
| pi-coding-agent | 1.4.0 | 只读记录（执行器自身运行中，不重写入口） |
| ripgrep | 15.2.0 | Scoop reset；Coop 版本往返 |
| starship | 1.27.0 | Scoop reset；Coop 版本往返 |
| uv | 0.13.5 | Scoop reset；Coop 版本往返 |
| zoxide | 0.10.0 | Scoop reset；Coop 版本往返 |

这 15 个包在安装态上覆盖 ZIP、7z、MSI、单文件产物以及命令入口、快捷方式、环境、持久化等对象；#40 实际执行的是 `scoop reset`、Coop 本地版本往返、真实更新、卸载重装和 Scoop 卸载后重装，并没有为每个包重新执行其全部脚本或安装器，也没有新装其余 4134 个包。逐项运行、入口、环境、数据与双方识别事实见[本机安装集的逐项交替验收](real-machine-acceptance.md)；Extras 没有任何本轮真机验证。

## 历史真机样本（不计入本轮已验证数）

以下生命周期确实在本机真实执行过，但 Manifest 修订早于本轮 `5be7f8c…`（多为 `a97619fe…`／`89b4cf8…`），因此不能计入本轮分母的“已验证”列；它们继续作为机制回归证据：

- ZIP/7z/tar 归档与更新：Main/ripgrep、air、fastfetch、unzip、tidy、curl、luajit（[归档生命周期覆盖](archive-support.md)）。
- MSI：Main/7zip、kalker、pkgconf；Inno Setup：Main/units、rizin；NSIS 载荷：Main/apngasm、elm（[Installer/Uninstaller 与特殊安装机制](installer-support.md)）。
- 入口、快捷方式与环境：Main/lessmsi、red-view、spotbugs、touch、cfr（[复杂命令入口、快捷方式与环境暴露](exposure-support.md)）。
- 脚本、依赖与持久化：Main/rclone、git-tfs、frp、mediamtx、pocketbase（[生命周期 Hook 与真实 PowerShell](script-support.md)、[依赖安装与反向依赖保护](dependency-support.md)、[持久化数据支持](persistence-support.md)）。

这些样本说明对应机制已有真机路径，但不能用来把本轮 4134 个“未运行”包改写成已验证，也不能把 149 个 Inno、408 个 NSIS、161 个 MSI 包整体算作已覆盖。

## 复现

```powershell
./scripts/build.ps1 -Action build
pwsh -NoProfile -File tests/real-scoop-coverage.ps1 -CoopExe .local/build/coop.exe `
  -EvidenceDir .local/pi/tasks/41/evidence/coverage-<UTC> `
  -VerifiedFacts .local/pi/tasks/40/evidence/cohort-final3/cohort-20261026-201857/facts-all.json `
  -VerifiedLifecycle .local/pi/tasks/40/evidence/cohort-final3/cohort-20261026-201857/lifecycle.json
```

- 首次运行会把官方 Main/Extras 克隆到项目内 `.local/coverage/root`（需要网络与磁盘）；之后重复运行沿用已固定修订。Main 默认取共用工作树实际 HEAD，并要求项目内副本与它逐字节一致；共用 bucket 的本地修改或修订移动时必须显式处理，脚本会拒绝静默换数据。
- 修订变化后加 `-ResetInventory` 重建项目内副本；该开关会先安全移除 helper junction，不会递归进入共用 Scoop 安装。Extras 可用 `-ExtrasRevision <40 位 commit>` 固定；不传时沿用已有项目内副本的 HEAD。
- 脚本退出 0 表示盘点完成，不代表 4149 个包都可运行；被阻塞的包是结果。退出非零表示盘点自身失败（读取范围、修订或摘要不一致、共用根被写入、统计不闭合），不会被当作“不支持包”的正常结果。
- 脚本内置断言：读取与计划状态必须覆盖全部 Manifest；验证状态不得超过 cohort 事实；Main 分母必须与共用工作树逐字节一致；共用根快照必须无变化。
- 本轮命令、退出码与完整控制台输出在 `.local/pi/tasks/41/evidence/coverage-final3-run.log`（退出 0）。

## 证据

运行目录：`.local/pi/tasks/41/evidence/coverage-final3/coverage-20261026-212649/`

| 内容 | 文件 |
| --- | --- |
| 环境、修订、cohort 来源、盘点根与 helper | `baseline.json`、`run-baseline.json` |
| 汇总（含逐机制、缺口、能力、外部工具、产物与摘要算法） | `summary.json` |
| 逐 Manifest 记录（4149 条：特征、读取/规划状态、诊断、验证状态） | `manifests.json` |
| 每条真实命令与退出码 | `commands.log` |
| Main 与共用工作树逐份 Manifest 的比对结果 | `shared-main-manifest-verification.json` |
| 共用根前后快照（递归路径/长度/修改时间，两次快照相同，运行日志报告变化数 0） | `shared-root-before.txt`、`shared-root-after.txt` |
| 所有阻塞包与 15 个验证包的完整 `info`/`plan` 原文（68 个包） | `samples/` |

已提交的 [`tests/coverage/baseline.json`](../tests/coverage/baseline.json) 是同一脚本生成的紧凑投影：固定修订、分母、总数、逐机制状态、缺口包名、产物/摘要算法计数与 15 个验证包；完整逐包记录仍只保存在项目内被忽略的证据目录。`baseline.json` 内的 `project_head` 是生成时的代码提交，本页提交只增加文档和该投影，不改变测量逻辑。

## 未运行与限制

- 本轮没有下载任何包产物、没有执行安装/更新/卸载或脚本；“计划可执行”不能当作生命周期验证。4134 个包保持未运行。
- Extras 全部未运行；本机 Scoop 根也未注册 Extras，分母修订来自官方仓库克隆。
- arm64、32bit 没有实际执行；64bit 规划不能证明其他架构的入口、脚本或安装器行为。
- `pi-coding-agent` 只记录运行版本，不重写入口或切换版本（执行器自身正在运行）。
- Coop 注册表的 Main 修订落后于实际工作树。本轮按实际数据盘点并把该差异写入 `baseline.json`；下一次显式 `bucket update` 会核对 HEAD 与记录。把缓存记录当实际修订会让分母指错版本，因此这里不使用它。
- `main/7zip` 与 `main/innounp` 在盘点根中因 helper junction 显示为“已安装”，其安装预览不是缺口的证据；两者已由 #40 真机覆盖。
- 机制统计是“声明覆盖”，不是 Scoop 全部运行时语义的等价声明；例如企业安装器、系统级注册表/服务、私有 Git 来源、私有 PSModule 仓库仍不在本轮验证范围。
