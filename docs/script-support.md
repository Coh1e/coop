# 生命周期 Hook 与真实 PowerShell

日期：2026-10-26。任务：[R10 / #31](https://github.com/Coh1e/coop/issues/31)，父规格 [#21](https://github.com/Coh1e/coop/issues/21)。本文记录 Coop 如何用真实 PowerShell 执行 Manifest 生命周期脚本、脚本获得的 Scoop 上下文与辅助函数、阶段与目录时序、输出与退出码语义，以及仍有待真实验证的部分。

行为依据固定 Scoop 提交 `e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f`（v0.6.0）的 [`bin/scoop.ps1`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/bin/scoop.ps1)、[`install_app` / `Invoke-Installer` / `Invoke-HookScript`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/install.ps1)、[`scoop-update.ps1`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/libexec/scoop-update.ps1) 与 [`scoop-uninstall.ps1`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/libexec/scoop-uninstall.ps1)，脚本原文取自[固定样本](../tests/corpus/index.json) 与真实 `main` bucket。

## 执行模型

每个生命周期阶段在独立的真实 PowerShell 子进程中运行，Coop 不做文本白名单、不改写脚本，也不内嵌 PowerShell 解释器：

1. Coop 先写两个文件到事务目录：`scripts/<序号>-<阶段>.ps1`（该钩子的原文，UTF-8 BOM）与 `scripts/<序号>-<阶段>.host.ps1`（生成的宿主脚本）。
2. 宿主脚本设置 `$env:SCOOP` 为所选管理根，按 Scoop 自身的加载顺序 dot-source [固定 Scoop 兼容库](../assets/scoop-lib/README.md)（`core`、`buckets`、`commands`、`help`、`getopt`、`json`、`autoupdate`、`manifest`、`system`、`install`、`download`、`decompress`、`shortcuts`、`psmodules`、`versions`、`depends`），再绑定下节的上下文变量，读取事务内固定的 Manifest 副本，最后按 Scoop 的 `Invoke-HookScript` 方式执行 ``Invoke-Command ([scriptblock]::Create($hookScript))``。
3. 宿主的 stdout/stderr 由两个线程并发读取，写入 `scripts/<序号>-<阶段>.stdout.log` / `.stderr.log`；事务日志记录解释器、宿主、兼容库路径与版本、上下文、Manifest 副本、每条流的字节数和尾部 8 KiB 摘要。
4. 脚本退出码非零、`abort` 或未捕获的终止错误都使整个包操作失败并按事务回滚已创建/移动的包状态；失败脚本不会自动重试。

脚本是受信来源提供的代码执行，不是安全沙箱，与 Scoop 相同：它可以使用任意 PowerShell 命令、.NET API 和外部程序。项目根之外的注册表、服务、用户目录等外部副作用无法从事务撤销；Coop 只记录“副作用未知、未自动回滚”，不声称整体可恢复。

固定样本中曾经被拒绝的文本现在都正常执行，例如 `Main/git` 的 `post_install`（`Get-ChildItem` + `ForEach-Object` + `-replace` + `Set-Content -Encoding unicode`）、`Main/git` 的 `pre_install`（`[System.IO.File]`、`[regex]::Escape`、`Where-Object`/`Select-Object`）与 `Main/rclone` 的 `uninstaller.script`。合法修改后的脚本（例如在真实 Hook 中增加注释或额外语句）同样执行，不再因为“不在子集内”被拒绝。

## 脚本上下文

宿主绑定的变量与 Scoop 的 `install_app`/`scoop-uninstall` 调用作用域一致：

| 变量 | 值 |
| --- | --- |
| `$app` / `$bucket` / `$version` / `$architecture` | 包名、bucket 名、版本和所选架构 |
| `$fname` | 第一个产物的本地文件名 |
| `$dir` | `pre_install`/`installer`/`pre_uninstall`/`uninstaller` 为具体版本目录；`post_install` 为 `apps/<包>/current`；`post_uninstall` 为已被移除的版本目录路径 |
| `$original_dir` | 具体版本目录 |
| `$persist_dir` | `<root>/persist/<包名>` |
| `$bucketsdir` / `$scoopdir` / `$cachedir` | `<root>/buckets`、所选管理根、`<root>/cache`（由兼容库 `buckets.ps1`/`core.ps1` 计算） |
| `$global` | 恒为 `$false`；Coop 不管理系统级安装 |
| `$manifest` | 事务内逐字节固定的 Manifest 副本解析成的对象。`post_uninstall` 在版本目录移除后运行，因此不能临时读取磁盘上的已装 Manifest |
| `$purge` | 仅在卸载会话定义：`uninstall --purge` 为 `$true`，普通卸载为 `$false`（与 `scoop-uninstall.ps1` 一致） |
| `$url` | `$null`（bucket 安装没有单独的用户 Manifest 来源 URL） |

`$cmd` **不是** Scoop 0.6.0 的 Hook 变量：`Invoke-HookScript` 只创建脚本块，`scoop-install.ps1`/`scoop-update.ps1`/`scoop-uninstall.ps1` 都没有定义它。用 Scoop 自身的库和 `Invoke-HookScript` 在同一提交上运行探针，`$null -ne $cmd` 为 `false`；`tests/hooks.ps1` 与 `tests/installers.ps1` 也断言 Coop 会话中同样未定义。因此 Manifest 中 `if ($cmd -eq 'uninstall') { reg import ... }` 之类的分支在两个客户端中都不执行，Coop 不会因为“更像预期”而私自定义它。

## 辅助函数

辅助函数就是 Scoop 自己的实现，Coop 没有另建缩水副本：`ensure`、`info`、`warn`、`error`、`abort`、`success`、`appdir`、`versiondir`、`persistdir`、`env_add_path`、`env_set`、`env_rm_path`、`env_rm`、`Expand-7zipArchive`、`Expand-MsiArchive`、`Expand-InnoArchive`、`Expand-DarkArchive`、`Get-EnvVar`、`Set-EnvVar`、`Invoke-ExternalCommand`、`is_admin`、`Invoke-Git` 等全部来自固定的 Scoop 库。

- 兼容库是 `assets/scoop-lib/` 中 Scoop v0.6.0 提交 `e6aa3b36` 的逐字节副本（MIT，含上游 LICENSE 与每个文件的 blob/SHA256 来源表），构建时复制到 `coop.exe` 旁的 `scoop-lib/`；`COOP_SCOOP_LIB` 可指向另一份同布局副本（只作用于当前子进程）。Coop 不读取所选管理根内已安装 Scoop 的库，避免 Hook 语义随环境漂移。
- `info`/`warn` 通过 `Write-Host` 写 stdout 并保留 `INFO  ` / `WARN  ` 前缀，与 Scoop 一致；不再是“warn 写 stderr”的自定义行为。
- 依赖外部工具的 helper（例如 `Expand-7zipArchive` 需要 `7zip`、`Expand-DarkArchive` 需要 `dark`）会按 Scoop 的方式在该 root 下查找 helper。找不到时 Hook 以非零退出码失败并保留日志；Coop 不自动下载或安装这些工具。MSI/Inno/NSIS 等机制本身仍由后续任务跟踪。

## 阶段与目录时序

- 安装：下载/校验/解压 → 创建具体版本目录 → `pre_install`（`$dir`=版本目录）→ `installer.script`（`$dir`=版本目录）→ 建立持久化链接 → 链接 `current`、创建命令入口/快捷方式/环境 → `post_install`（`$dir`=current）→ 提交管理记录。
- 更新：下载/校验/解压新产物 → 旧版本 `pre_uninstall`/`uninstaller.script` → 移除旧 `current`/入口/快捷方式 → 旧版本 `post_uninstall` → 新版本 `pre_install`/`installer.script` → 新 `current`/入口/快捷方式/持久化 → 新 `post_install` → 提交管理记录；旧版本默认保留。
- 卸载：`pre_uninstall`/`uninstaller.script` → 移除 `current`/入口/快捷方式/版本目录 → `post_uninstall` → 提交；普通卸载保留 `persist` 数据，`--purge` 在全部 Hook 结束后才删除声明的 store。

阶段序列来自 IR Plan（`pre_install`、`installer`、`post_install`、`pre_uninstall`、`uninstaller`、`post_uninstall`），预览显示的脚本步骤与执行消费的是同一序列。`pre_install` 直接在最终版本目录运行，避免把事务临时路径写进脚本生成的文件；`post_install` 在 `current` 建立后运行；`post_uninstall` 在版本目录移除后运行。

## 输出、退出码与失败

- 预览不启动 PowerShell：`install|update|uninstall|adopt --dry-run` 只读取 Manifest，输出每个阶段的原文、宿主类型、解释器、兼容库路径/版本和 `problem`；`execution_available=false` 只在宿主确实不可用时出现（缺少 PowerShell、显式 `COOP_SCOOP_LIB` 无效或缺少兼容库）。
- `stdout`/`stderr` 全量写入每个 Hook 的日志文件，不截断；JSON 结果与事务日志记录字节数与尾部摘要（无效 UTF-8 字节替换为 `?`，原始字节仍在日志中）。
- 显式 `exit N`、`abort` 与未捕获终止错误传播为包操作失败，退出码写入 `scripts[i].exit_code`；失败后按事务回滚已创建的包状态，失败原因包含日志路径。
- **与固定 Scoop 的刻意差异**：Hook 子进程设置 `$ErrorActionPreference = 'Stop'`，Scoop 使用调用作用域默认的 `Continue`。因此 Scoop 会容忍的非终止错误在 Coop 中使操作失败并回滚，避免“脚本报错但安装记为成功”。需要使用非终止错误语义的脚本可以在语句上显式 `-ErrorAction SilentlyContinue/Ignore`，真实样本（如 `Extras/vscode`）本来就这样做。
- 卡死脚本没有超时/取消：Coop 等待脚本结束，与 Scoop 一致，不静默强杀。

## 环境参数

| 参数 | 作用 |
| --- | --- |
| `COOP_POWERSHELL` | 指定 PowerShell 解释器；未设置时优先 `pwsh.exe`，其次系统 Windows PowerShell。只作用于当前子进程 |
| `COOP_SCOOP_LIB` | 指定兼容库目录（必须含 `core.ps1`）；显式设置但无效时执行被明确阻塞，不回退到其他副本 |
| `SCOOP` | 由宿主在子进程内设置为所选管理根，让 `$scoopdir`/`$bucketsdir`/`$cachedir` 与 Scoop 语义一致；不修改用户或系统环境 |

## 验证

`tests/hooks.ps1`（CTest `hooks`，本轮 172 项检查）在项目内隔离根运行真实 CLI、真实 PowerShell、固定 Scoop 兼容库和项目固定测试程序，Hook 原文来自固定样本：

| 场景 | 观察结果 |
| --- | --- |
| 无脚本路径 | 无 Hook 的安装不启动任何 PowerShell 子进程（`process_guard` 只观察到 coop 自身） |
| 预览 | 带 Hook 的预览不启动 PowerShell、不写安装状态，列出真实脚本原文与宿主/库信息，六个阶段全部披露 |
| 真实安装 Hook | `Extras/notepadplusplus` 的 `pre_install`/`post_install` 原文运行；`$npp` 替换、注册表作用域、插件更新与入口可用性均核对 |
| 真实 `git` Hook | `Main/git` 的 `post_install` 原文把 bucket `.reg` 模板渲染为 UTF-16LE；`pre_install` 原文从 `$persist_dir` 恢复配置并用正则改写版本路径；`pre_uninstall` 原文保存配置 |
| 真实 `nodejs` Hook | `post_install` 原文把 `$persist_dir` 写进 `npmrc` |
| 真实 `rclone` Hook | `uninstaller.script` 原文用 `Get-Item`/`LinkType` 判断并复制配置 |
| 上下文与 helper | 一个 Hook 快照 `$scoopdir`/`$bucketsdir`/`$cachedir`/`$dir`/`$original_dir`/`$persist_dir`/`$manifest`/`$global`，断言 `$cmd` 与 `$purge` 未定义、真实 helper 均存在、`ensure` 建目录、`info`/`warn`/`success` 前缀 |
| 阶段时序 | 旧版本 `pre_uninstall` → 新版本 `pre_install` → `post_install`；`post_uninstall` 在版本目录移除后运行并收到 `$purge` |
| 失败传播 | 受支持的脚本失败只执行一次，`exit 9` 传播为 9，`throw` 传播为 1，安装回滚，日志记录失败与 stderr |
| 并发输出 | 约 100 KiB stdout 与约 50 KiB stderr 同时输出时安装成功，完整日志字节数和最后一行尾部均核对 |
| 合法修改 | 真实 `notepadplusplus` `pre_install` 增加注释与额外语句后仍执行；函数、哈希表、`try/catch/finally`、子表达式、.NET 调用、`Where-Object`/`Select-Object` 与 `$env:` 读取都在普通 Hook 中运行 |
| 能力诊断 | 缺少 PowerShell 或无效 `COOP_SCOOP_LIB` 在执行前诊断，不启动 PowerShell、不写事务 |
| 接管资格 | 带 Hook 的已安装包仍为 `untested`，不写管理记录；该类需要真实共用根证据 |

`tests/installers.ps1`（CTest `installers`）补充 `installer`/`uninstaller` 阶段：真实 7z 产物、rclone `uninstaller.script` 原文、installer 阶段顺序/上下文/退出码和失败传播，并确认不再把脚本原文当作可执行性判据。

### 真实共用根证据（#31）

`tests/real-scoop-hooks.ps1` 在本机真实 Scoop 根（`C:\Users\Neo\scoop`，Scoop v0.6.0，`main` 修订 `a97619fe`）上执行了一次有界的真实生命周期，证据目录 `.local/pi/tasks/31/evidence/real-rclone-1/`：

- 只读预览：已安装 `git` 的更新计划现在 `execution_available=true`，列出 `pre_install`/`post_install`/`pre_uninstall`/`uninstaller` 四个 Hook；`7zip` 仍因 MSI 机器缓存限制被阻塞，但两个 Hook 文本正常列出。
- 真实安装 `main/rclone` 1.75.2（zip、真实下载）：`pre_install` 原文在真实 PowerShell 中运行，`$scoopdir`=`C:\Users\Neo\scoop`，创建并持久化 `rclone.conf`；`shims/rclone.exe version` 返回 `rclone v1.75.2`，`scoop list` 能列出 Coop 创建的安装。
- 真实卸载：`uninstaller.script` 原文运行，普通卸载保留持久化数据，`scoop list` 不再列出 rclone；随后只删除本轮创建的 `persist/rclone` store，前后比对应用、shim、持久化目录集合一致，无 pending 事务。

## 未运行或未承诺

- 本机真实 Scoop 根上的其余 14 个已安装包的 Hook 生命周期由 [R19 / #40](https://github.com/Coh1e/coop/issues/40) 跟踪；本轮真实根只实际执行了 rclone 的 `pre_install` 与 `uninstaller.script`（见上节），其他已安装包的 Hook 文本只做了只读预览。
- `reg import`、服务控制、`Start-Process` 等会修改项目外状态的原文没有在真实根上执行；它们仍是受信脚本副作用，不承诺回滚。
- MSI/Dark、Inno Setup、NSIS 机制本身（R12–R14）：`Main/python` 的 `installer.script` 文本会运行，但缺少 Dark/MSI helper 时以失败结束。
- `post_uninstall` 中删除用户数据的真实样本（`Extras/aider-desk`、`Main/azure-cli`）没有执行；只用合成脚本验证阶段语义与 `$purge`。
- Windows PowerShell 5.1 解释器路径只实现为回退候选，本轮未单独运行；`pwsh` 路径已实际验证。
- 卡死脚本的超时/取消、无效 UTF-8 输出的可读性（JSON 只保证替换为 `?`）与任意脚本外部副作用的自动回滚不在承诺范围。
