# PowerShell 模块暴露（psmodule）

> R25 / #46。本页记录 Manifest `psmodule` 的归一化、计划与执行语义、用户 `PSModulePath` 的归属与撤销规则，以及真机与项目内验证。相关缺口归因见[全量盘点缺口闭合](compatibility-gap-closure.md)，环境暴露的通用规则见[复杂命令入口、快捷方式与环境暴露](exposure-support.md)。

## 结论

- `psmodule` 已归一为 IR 的模块身份；计划中出现 `ps-module` / `remove-ps-module` 操作，执行创建 `<root>/modules/<name>` → `apps/<包>/current` 的目录 junction，并把 `<root>/modules` 前置于当前用户 `PSModulePath`。
- 用户环境写入沿用与 `env_set`/`env_add_path` 同一套 HKCU 机制：保存原值、写入值、类型与本次新增条目，广播 `WM_SETTINGCHANGE`，新 PowerShell 进程直接读到。卸载时若当前值仍等于 Coop 写入值就恢复原值（原本不存在则删除该项），用户后来改动过则只删除 Coop 新增的那一个条目。
- 预览显示 `ps_module`（操作、链接、目标、`PSModulePath` 条目与作用域）；`--dry-run` 不创建 `modules` 目录、不写注册表。
- 28 个声明 `psmodule` 的 Main/Extras Manifest 在固定修订的全量盘点中全部变为计划可执行，`capability:psmodule` 与 `dependency-unsupported` 缺口归零；`inadyn-mt`、`lazy-posh-git` 的依赖级联消失。
- 真实共用根上安装、由 Scoop 识别、再卸载的 `main/gsudo`（同包 `psmodule` + `bin` + `post_install` + `env_add_path`）与项目内真实兼容根上的 `extras/posh-git` 均有本轮实际证据；未运行项在文末列出，不计为通过。

## Scoop 兼容基准

固定兼容库为 Scoop v0.6.0（`e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f`）。相关实现：

| 语义 | 位置 |
| --- | --- |
| 安装时创建 `<root>/modules/<name>` → `$dir` 的目录 junction，并把 `<root>/modules` 前置进 `PSModulePath` | `psmodules.ps1:1-25`、`:44-54`（`install_psmodule`、`ensure_in_psmodulepath`） |
| 卸载时只删除 junction，`PSModulePath` 条目保留 | `psmodules.ps1:27-42`（`uninstall_psmodule`） |
| 安装顺序：入口 → 快捷方式 → psmodule → `env_add_path` → `env_set` → 持久化 → `post_install` | `install.ps1:59-70` |
| 用户级变量写入 `HKCU\Environment`，含 `%` 时用可展开字符串，并广播 | `system.ps1:46-74`（`Set-EnvVar`） |
| 未设置时以 `$env:USERPROFILE\Documents\WindowsPowerShell\Modules` 作为原值 | `psmodules.ps1:46-48` |

Coop 的顺序与之一致：`publish-current → entries → shortcuts → ps-module → environment → persistence → post_install → commit-state`；卸载为 `… → remove-shortcuts → remove-ps-module → remove-environment → …`。

两处与本页相关的取舍：

- **junction 指向 `apps/<包>/current`。** Scoop 的 `$dir` 是版本目录；指向稳定的 `current` 对 PowerShell 模块发现完全等价（junction 链解析到同一份文件），但更新时不需要为了让链接指向新版本目录而重写，且验收按 `<root>/modules/<包>` → `apps/<包>/current` 核对。执行仍会在更新/重置的计划里先 `remove-ps-module` 再 `ps-module`，因此预览与实际顺序一致。
- **`.nupkg` 按 ZIP 容器处理。** Scoop 的 `Test-7zipRequirement` 因 `.nupkg` 后缀调用外部 7-Zip；NuGet 包本身是 ZIP，Coop 的原生 libarchive 路径解出同一棵树，不引入核心 7-Zip 依赖。这是 `extras/posh-git`（唯一产物为 `.nupkg`）成为可执行计划的前提。

## IR、计划与执行

- Adapter 把 `psmodule` 归一为 `ir::PsModule{name}`：必须是对象且带非空 `name`；名称按与其他托管路径相同的组件边界校验（拒绝分隔符、保留名、尾随点/空格）。其他 `psmodule` 选项作为 `adapter/psmodule-field` 报告，不静默忽略。`psmodule: true` 这类形状错误在写入前失败。
- Validator 为声明 `psmodule` 的包加上 `ps-module` 能力说明；不再产生 `Not yet supported: psmodule`。
- Planner 在入口/快捷方式之后、环境之前插入 `ps-module`；卸载与更新/重置替换旧版本时在移除快捷方式之后、环境之前插入 `remove-ps-module`。两个操作都带明确 effect 文本，预览与执行消费同一 `ir_operations` 序列（真实运行日志的 `observed_steps` 与本轮预览逐项比对）。
- 执行 `ps-module`：`<root>/modules` 不存在则创建（不跟随 reparse point），`<root>/modules/<name>` 不存在则创建 junction；已存在时只接受目录 junction：目标仍是本包（`apps/<包>/current` 或本包版本目录，按文件系统身份比较）就复用，指向本包其他版本目录就替换，指向本包之外则报错拒绝，不删除用户或其他包的模块。随后写入 `PSModulePath` 条目。
- 执行 `remove-ps-module`：只移动（可回滚）指向本包 `apps/<包>/` 之下目录的 junction，其他对象一律拒绝删除；`PSModulePath` 条目按下一节的归属规则撤销。`<root>/modules` 空目录本身保留，与 Scoop 行为一致。
- 事务失败时 junction 的创建/移动与 `PSModulePath` 写入都按既有 `journal.json` 的 `created`/`moves`/`environment_undo` 记录回滚；成功提交后用于暂存旧 junction 的事务内链接被解除（不跟随删除目标）。

## `PSModulePath` 的归属与撤销

`PSModulePath` 不是单个包的私有变量：一个安装根共用同一个 `<root>/modules` 条目。Coop 因此把它当作路径列表变量，按条目归属：

1. 安装/更新时，若当前值已包含 `<root>/modules`，不重复添加；否则前置于现有一切条目之前（未设置时按 Scoop 规则以 `%USERPROFILE%\Documents\WindowsPowerShell\Modules` 作为原值），保留注册表类型并在值含 `%` 时使用可展开字符串，广播设置变更。
2. 包记录 `.coop/packages/<包>.json` 的 `psmodule` 保存模块名、junction 与目标，以及 `user_environment.ownership`：变量名、条目、写入前原值（含存在性与类型）、写入值、本次新增条目。更新时沿用同一份归属，不会把 Coop 自己写入的条目降级成“无主”。
3. 卸载（或更新为新版本不再声明 `psmodule`）时：
   - 当前值仍等于 Coop 写入值时，恢复安装前的原始值（原本不存在则删除该用户变量）；
   - 用户后来改动过（新增、删除或重排条目）时，只删除 Coop 记录为新增的 `<root>/modules` 条目，其余条目与顺序保持，并在 `preserved` 中报告该差异；
   - `<root>/modules` 还有其他模块链接时保留条目，避免卸载一个模块破坏其他模块；
   - 由 Scoop 安装、没有 Coop 归属记录的包只移除 junction，`PSModulePath` 条目按 Scoop 自身行为保留（Scoop 的 `uninstall_psmodule` 也不删除该条目）。
4. `journal.json` 记录 `ps_module`（junction 动作、链接、目标、`PSModulePath` 写入与广播结果）与 `environment_undo`，支持进程内回滚和 `recover` 预览。

## 预览

`coop install|update|uninstall <包> --dry-run --json` 的 `ps_module` 字段示例（有声明时）：

```json
{
  "operation": "create",
  "name": "posh-git",
  "link": "<root>\\modules\\posh-git",
  "kind": "directory-junction",
  "target": "<root>\\apps\\posh-git\\current",
  "user_environment": {
    "variable": "PSModulePath",
    "entry": "<root>\\modules",
    "scope": "HKCU\\Environment",
    "effect": "prepend the entry when it is absent, record the previous raw value and the entry Coop added"
  },
  "scoop_semantics": "Scoop 0.6.0 psmodules.ps1 install_psmodule/uninstall_psmodule: a directory junction <root>/modules/<name> and the user PSModulePath entry for <root>/modules"
}
```

`ir_operations` 列出 `ps-module`（卸载/替换为 `remove-ps-module`），执行器消费同一序列。`--dry-run` 只读取清单与安装事实：不创建 `modules`、不创建包目录、不写 `HKCU`。

## 本轮验证（R25 / #46）

工具与代码：`coop 0.1.0`（本票提交构建，`--version` 记录在证据目录）、Windows x64 `10.0.26300.0`、PowerShell 7.6.5、CMake/Ninja/MSVC Build Tools。

### 项目内真实兼容根：extras/posh-git

根 `.local/coverage/root`，bucket 为固定修订的官方 Main `5be7f8c702856c72800a0a4945b88fe6ea2bd52f` 与 Extras `0f8f4b5fd43bedccc7b233b77f4605bddba8085b`；`.nupkg` 从 PowerShell Gallery 实际下载并按 Manifest SHA256 校验。脚本 [`tests/real-scoop-psmodule.ps1`](../tests/real-scoop-psmodule.ps1) 顺序执行：

| 观察 | 结果 |
| --- | --- |
| 预览 | `execution_available=true`，`ps-module` 操作，`ps_module.target=<root>\apps\posh-git\current`；未创建 junction/包目录，`PSModulePath` 未变 |
| 安装 | 退出 0；`<root>/modules/posh-git` 为 `Junction`，目标 `apps/posh-git/current`；`PSModulePath` 以 `<root>\modules` 开头（本机运行前该用户值不存在，因此按 Scoop 规则以 `%USERPROFILE%\Documents\WindowsPowerShell\Modules` 作为原值）；日志 `ps_module.junction=created`、`user_environment.status=added` |
| 新 PowerShell 进程 | `Start-Process -UseNewEnvironment` 启动的 `pwsh` 读到含 `<root>\modules` 的 `PSModulePath`，`Import-Module posh-git` 成功（版本 1.1.0，`ModuleBase=<root>\modules\posh-git`） |
| 依赖级联 | `extras/lazy-posh-git` 预览 `execution_available=true`，无 `dependency-unsupported`/`unsupported-capability`，依赖 `posh-git` 以 `installed` 复用 |
| 卸载 | 退出 0；junction 消失；`PSModulePath` 恢复为安装前状态（本机运行前该用户值不存在，因此恢复为不存在），`Path` 未变 |

用户“安装后改 `PSModulePath`”的场景由项目内用例 [`tests/psmodule.ps1`](../tests/psmodule.ps1)（CTest `psmodule`）在真实 HKCU 上覆盖，因为需要可控的基线条目：安装前设置两条基线条目 → 安装 → 更新（条目仍只出现一次，模块内容切到 2.0.0）→ 用户追加一条条目 → 卸载后只删除 Coop 新增的 `<root>\modules`，基线条目、用户追加条目与顺序保持；另一次未修改的安装/卸载恢复原始值与类型。该用例同时覆盖预览无副作用、计划与 `observed_steps` 一致、无 `psmodule` 的包不改 `PSModulePath`、以及 `psmodule` + `bin` + `post_install` 组合的计划可执行。

### 真实共用根：main/gsudo

在人类选定的真实共用根 `C:\Users\Neo\scoop`（Scoop v0.6.0，Main `5be7f8c7…`）上，用同一脚本顺序执行同一套断言：预览 → Coop 安装 `main/gsudo` 2.6.1 → 新 PowerShell 进程 `Import-Module gsudoModule`（`ModuleBase=C:\Users\Neo\scoop\modules\gsudoModule`）→ 真实 `scoop list` 列出 `gsudo 2.6.1` → `main/inadyn-mt` 预览可执行 → Coop 卸载。安装日志的 `observed_steps` 为 `download,verify,extract,publish-current,entries,ps-module,environment,hook,commit-state`，与预览逐项一致；`post_install`（`gsudo.exe -k`）以真实 PowerShell 执行、退出码 0。卸载后 junction 与 Coop 写入的 `PSModulePath` 条目消失，`PSModulePath` 恢复为运行前状态（该用户值原本不存在），用户 `Path` 与运行前逐字节相同（`env_add_path` 条目被撤销），`scoop list` 不再列出 `gsudo`，`apps/gsudo`、`.coop/packages/gsudo.json` 都不存在。

### 全量盘点复测

同一盘点脚本 [`tests/real-scoop-coverage.ps1`](../tests/real-scoop-coverage.ps1) 在固定修订（Main 1701 + Extras 2448 = 4149 份）上重跑：

| 指标 | 复测前（#41 基线） | R25 复测 |
| --- | ---: | ---: |
| 计划可执行 | 4094 | **4123** |
| 计划被阻塞 | 53 | **24** |
| `capability:psmodule` | 28 | **0** |
| `dependency-unsupported` | 2 | **0** |
| 其余机制 | 命令入口宿主 11、Manifest 形状 6、依赖缺失 5、arm64 产物 3 | 同左，未改写 |

`field.psmodule` 机制的 28 份 Manifest 全部读取通过且计划可执行（`blocked=0`），`main/gsudo`、`main/inadyn-mt`、`extras/lazy-posh-git` 的 `gap_mechanisms` 均为空。盘点根内已安装的 `7zip`、`innounp` 仍是环境内 helper，不计为缺口；3 个 arm64-only 包仍按架构边界拒绝，未计为已支持。完整逐包记录、命令日志与前后共享根快照在该轮证据目录。

### 证据与工具版本

本轮证据使用的 `coop.exe` SHA256 为 `b3684216893c97dff996425901295a89e5d585d6c442ef23d7885f5d1641019b`（本票提交构建，源码与二进制摘要的逐项绑定见交付报告与 Issue）；工具为 CMake 4.4.4 / Ninja 1.13.2 / MSVC Build Tools / PowerShell 7.6.5，平台 `10.0.26300.0` x64，Scoop v0.6.0。以下目录均在被忽略的项目内，不随仓库分发；每轮目录带自己的时间戳，不覆盖旧证据：

| 内容 | 位置（`.local/pi/tasks/46/evidence/` 下） |
| --- | --- |
| 完整 CTest（43/43 通过，0 失败） | `final-head-*/ctest-full.log` |
| 构建/工具/二进制摘要与工作树状态 | `final-head-*/environment.json`、`.../real-runs-summary.json` |
| `extras/posh-git` 真机顺序：预览、安装、新进程导入、依赖预览、卸载 | `posh-git-final-*/`（`summary.json`、`*.log`、`module-probe.*`） |
| `main/gsudo` 共享根顺序：预览、安装、导入、`scoop list`、`inadyn-mt` 预览、卸载 | `gsudo-final-*/` |
| 全量盘点复测（4149 份、逐包与缺口、共享根前后快照） | `coverage-final-*/coverage-*/` |
| 隔离用例（真实 HKCU、用户修改与精确恢复、更新、组合声明） | CTest `psmodule`（`tests/psmodule.ps1`），输出在对应 `ctest-full.log` 内 |

本轮运行前 `PSModulePath` 在 HKCU 中不存在，两次真机运行的 `finally` 快照均确认结束后仍不存在；`Path` 与运行前逐字节相同。未运行项如下节。

## 未运行与限制

- 未验证 Scoop 自己卸载 Coop 安装的 psmodule 包：Scoop 0.6.0 的 `uninstall_psmodule` 会先 `Convert-Path` 再递归删除，可能顺着 junction 删除目标内容。本票不改变 Scoop 该行为，也不把它当作已兼容路径；共享状态的卸载由 Coop 完成。
- 未实现系统级（`--global`）模块与机器级 `PSModulePath`：当前只写当前用户 `HKCU\Environment`，系统级安装根本身是只读事实。
- 不额外校验模块内部布局（`.psd1`/`.psm1` 位置、清单有效性）；与 Scoop 一样，junction 指向什么，PowerShell 就按模块目录解析什么。模块自身导入失败属于包内容问题，不是 Coop 的兼容缺口。
- 未在本轮重跑 arm64 或 32bit 架构、未启用 `versions` 等未注册 bucket；这些由对应票与 #45 如实列出。
- 用户 `PSModulePath` 的基线恢复使用项目内测试脚手架（快照/还原），仅用于失败时保持人类环境不变；产品写入仍只走 Coop 的归属与撤销路径。

## 复现

```powershell
./scripts/build.ps1 -Action build
ctest --test-dir .local/build --output-on-failure -R '^psmodule$'
pwsh -NoProfile -File tests/real-scoop-psmodule.ps1 -CoopExe .local/build/coop.exe `
  -EvidenceDir .local/pi/tasks/46/evidence/posh-git-<时间戳> `
  -ScoopRoot .local/coverage/root -Package extras/posh-git `
  -ExtraPreviewPackages 'extras/lazy-posh-git' -SkipScoopList
pwsh -NoProfile -File tests/real-scoop-psmodule.ps1 -CoopExe .local/build/coop.exe `
  -EvidenceDir .local/pi/tasks/46/evidence/gsudo-<时间戳> `
  -Package main/gsudo -ExtraPreviewPackages 'main/inadyn-mt'
pwsh -NoProfile -File tests/real-scoop-coverage.ps1 -CoopExe .local/build/coop.exe `
  -EvidenceDir .local/pi/tasks/46/evidence/coverage-<时间戳> -ThrottleLimit 8
```

真实写入脚本在开始前确认目标包未安装，`finally` 中恢复 `PSModulePath`/`Path` 快照并清理失败遗留。本文的数字、版本与证据路径只代表 2026-10-27 这一次运行；重跑前应重新盘点 bucket 修订与已安装清单。
