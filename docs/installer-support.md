# Installer/Uninstaller 与特殊安装机制

日期：2026-10-26。任务：[R11 / #32](https://github.com/Coh1e/coop/issues/32)（安装器/卸载器程序与多阶段脚本组合执行）与 [T14 / #16](https://github.com/Coh1e/coop/issues/16)（首版安装器机制调查），父规格 [#21](https://github.com/Coh1e/coop/issues/21) 取代 [#2](https://github.com/Coh1e/coop/issues/2) 的冲突描述。本文记录本轮实际启用的安装机制、真实样本、必要外部工具、隔离边界和未验证项；不是对任意 MSI、NSIS、Inno Setup 或安装器脚本的兼容承诺。

行为依据固定 Scoop 提交 `e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f` 的 [`Invoke-Extraction` / `Expand-7zipArchive` / `Expand-MsiArchive`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/decompress.ps1)、[`install_app` / `Invoke-Installer`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/install.ps1) 和固定样本 Manifest。实现只覆盖下面明确列出的机制。

## 机制与样本

| 机制 | 固定样本 | 本轮行为 | 证据 |
| --- | --- | --- | --- |
| ZIP / tar.gz 普通归档 | Main/ripgrep、Main/air | 原生 libarchive，既有 T09 覆盖 | `tests/archive-lifecycle.ps1` |
| 7z 普通归档 | Main/nodejs `node-v26.12.1-win-x64.7z` | 原生 libarchive 解压，`extract_dir` 与 `bin` 正常工作，不启动 7z.exe 或 PowerShell | `tests/installers.ps1` 安装真实 node 产物并运行 `node --version` → `v26.12.1` |
| `#/dl.7z` 自解压安装器载荷 | Main/unzip 6.00；Extras/git、Extras/vscode、Extras/firefox、Extras/aider-desk | 按普通 7z 载荷交给 libarchive；不解析 NSIS/Inno 安装器结构。R05 已用 Main/unzip 的真实下载改名、安装、运行和 Scoop reset 验证机制；大体积 Extras 安装器载荷仍未逐个运行 | `tests/archive-lifecycle.ps1`、`tests/real-scoop-archives.ps1`；大体积 Extras 载荷未运行 |
| MSI 管理安装提取 | Main/7zip `7z2605-x64.msi` | **未启用**。计划仍检测 `msiexec.exe` 并列出工具、可用性和隔离限制；`msiexec.exe /a` 会写入 `%WINDIR%\Installer` 的机器级 Windows Installer 缓存，超出项目根。为避免静默修改系统，执行明确阻塞 | 验证者在 `6203f08` 复现：`.local/pi/tasks/16/verify/06-msi-system-write.log`；本轮测试只验证预览/拒绝且测量缓存未变化 |
| `installer.script` | Main/python（实际样本） | 阶段已接入生命周期；脚本作为受信文本由真实 PowerShell 与本机固定 Scoop 兼容库执行，不再按脚本文本子集拒绝（#31）。python 的 installer.script 仍依赖 MSI/Dark 机制，`Expand-DarkArchive` 找不到所需 helper 时在执行时明确失败 | `tests/installers.ps1` 用测试脚本验证顺序、上下文、退出码和失败传播；python 样本只做预览 |
| `installer.file` / `installer.args` 安装器程序 | Main/groovyserv `bin\setup.bat`（真实执行）；Main/vcpkg `bootstrap-vcpkg.bat -disableMetrics`（真实只读预览）；Extras 固定样本没有此类声明 | 已启用（#32）：程序由真实 PowerShell 宿主调用固定 Scoop 兼容库的 `Invoke-Installer` 执行；`$dir` 内含性检查、缺少程序时中止、`$dir`/`$global`/`$version` 参数替换、`.ps1` 直接调用、非零退出传播和 `keep=false` 删除程序文件都是上游行为 | `tests/installer-programs.ps1`（.cmd/.ps1/参数替换/keep/失败回滚）、`tests/real-scoop-installers.ps1`（真实 groovyserv 生命周期） |
| `uninstaller.file` / `uninstaller.args` 卸载器程序 | 固定样本与当前 Main/Extras 固定修订没有此类声明 | 已启用（#32）：与安装器程序共用同一 `Invoke-Installer` 路径并在卸载/更新旧版本时以 `$dir` 指向被移除版本目录 | `tests/installer-programs.ps1` 以真实 `.cmd` 卸载器程序验证顺序、`$dir` 参数和失败保护 |
| `uninstaller.script` | Main/rclone（实际样本） | 按 `uninstaller` 阶段在真实 PowerShell 中执行原文，`$dir`/`$persist_dir` 与 Scoop 一致 | `tests/installers.ps1` 使用 rclone 原文在卸载时把 `rclone.conf` 保存到 persist；`tests/hooks.ps1` 另用真实模板生成 `.reg` 文件（不 import） |
| `reg import` 卸载脚本 | Main/7zip、Main/git、Extras/vscode、Extras/notepadplusplus | 脚本文本不再被静态拒绝，`reg import` 会作为真实外部进程执行；注册表属于项目外的用户/系统状态，Coop 不声称可回滚 | Main/git 的 `post_install` 只把 bucket `.reg` 模板渲染进包目录，`tests/hooks.ps1` 执行该原文并核对编码与替换 |
| Inno Setup / NSIS / 其他 EXE 安装器 | Extras/aider-desk、Main/python 的 setup.exe 等 | 不解析厂商安装器结构；`innosetup` 等特殊机制声明仍拒绝，`installer.file/args` 作为普通程序声明已启用（#32） | 计划诊断 |
| `installer.file` / `installer.args` 进程声明 | Main/groovyserv、Main/vcpkg（真实声明） | 已启用（#32）：程序在版本目录运行，位于 `pre_install` 之后、`current`/入口发布之前；失败使包操作失败并回滚已创建的包状态，项目外副作用不承诺回滚且不自动重试 | `tests/installer-programs.ps1`、`tests/real-scoop-installers.ps1` |
| `post_uninstall` | Extras/aider-desk、Main/azure-cli | 已启用（#31）：在版本目录移除后由真实 PowerShell 执行，`$dir` 仍指向已移除的版本路径；样本自身删除用户数据的行为是受信脚本副作用，测试只用项目内合成脚本验证阶段语义 | `tests/hooks.ps1` |

普通压缩库能力只用于普通 7z 归档和 7z 自解压载荷；它不被描述成 MSI、NSIS 或 Inno Setup 的完整安装器提取能力。

## MSI 与外部工具

- MSI 不静态链接第三方 MSI 读取库，也不把 libarchive 的 7z 能力冒充 MSI 支持。
- 计划会检测系统 `msiexec.exe` 并在 `external_tools` 中列出工具名、用途、`available`、`enabled=false`、隔离限制和“Coop 永不自动下载或安装外部工具”的策略。`available` 只表示当前系统是否找到工具，不表示该机制已启用。
- **MSI 执行被 AC4 阻塞**：验证者在非管理员令牌下复现，一次 `msiexec /a` 管理安装会更新机器级缓存文件 `C:\Windows\Installer\SourceHash{23170F69-40C1-2702-2605-000001000000}`；同窗口的 ZIP 安装对照不修改该文件。该写入不在当前项目根内，无法通过事务回滚。证据：`.local/pi/tasks/16/verify/06-msi-system-write.log`、`07-msi-system-write-control.log`、`08-zip-control.log`。
- 因此即使找到 `msiexec.exe`，预览也返回 `execution_available=false`，实际执行在下载和事务写入前以明确的 machine-cache 限制失败；不会启动 `msiexec`。
- 找不到 `msiexec.exe` 时，诊断同时指出缺失工具和上述隔离限制，不会误报支持。测试用 `COOP_MSIEXEC` 指向当前子进程的明确路径只用于检测和拒绝验证，不写用户或系统环境。
- 要启用 MSI，需要先取得项目外系统写入的人类决定，或实现不写 Windows Installer 机器缓存的隔离提取器；本轮不把管理安装路径保留为默认可用能力。

## Installer/Uninstaller 脚本生命周期

脚本相位的顺序与固定 Scoop 一致：

- 安装：下载/校验 → 解压 → `pre_install`（具体版本目录）→ `installer.script`（具体版本目录）→ 发布 `current`、入口、快捷方式和持久化 → `post_install`（`$dir=current`）→ 提交管理记录。
- 更新：旧版本 `pre_uninstall` → 旧版本 `uninstaller.script` → 移除旧 `current`/入口/快捷方式 → 旧版本 `post_uninstall` → 新版本 `pre_install` → 新版本 `installer.script` → 新 `current`/入口/持久化 → 新 `post_install` → 提交；旧版本默认保留。
- 卸载：`pre_uninstall` → `uninstaller.script`（`$dir` 仍指向版本目录）→ 移除 `current`/入口/快捷方式/版本目录 → `post_uninstall` → 提交；普通卸载保留声明数据。

阶段区分来自 IR Hook，`$purge` 只在卸载会话中定义；`$cmd` 不是 Scoop 0.6.0 的 Hook 变量（见[生命周期 Hook 与真实 PowerShell](script-support.md)），因此依赖它的 `if ($cmd -eq 'uninstall')` 分支在 Coop 与 Scoop 中都不执行。

脚本上下文、辅助函数和阶段语义见 [生命周期 Hook 与真实 PowerShell](script-support.md)。`installer.script` 和 `uninstaller.script` 与普通 Hook 共用同一真实 PowerShell 宿主、固定 Scoop 兼容库、stdout/stderr 日志、退出码传播和失败回滚；脚本不自动重试，脚本造成的项目外副作用不声称可回滚。

`installer.script` 不再按文本子集拒绝：Main/python 的原文会交给真实 PowerShell，但其中的 MSI/Dark 机制仍属于后续任务，缺少 helper 时以非零退出码失败。`installer` 阶段的可执行路径用测试脚本验证顺序、上下文、退出码和失败传播，这不等于 python 样本已兼容。Main/rclone 的 `uninstaller.script` 原文已在隔离测试与真实共用根的生命周期中实际运行。

### 安装器/卸载器程序（#32）

`installer.file`/`installer.args`（以及 `uninstaller.file`/`uninstaller.args`）不再是拒绝理由。程序由真实 PowerShell 宿主执行：宿主设置与 Hook 相同的 `$env:SCOOP`、加载固定 Scoop 兼容库、绑定 `$app`/`$version`/`$architecture`/`$dir`/`$persist_dir`/`$manifest` 等上下文，然后以**删除 `installer`/`uninstaller.script` 属性的同一份 Manifest 副本**调用上游 [`Invoke-Installer`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/install.ps1)。因为 IR 计划已把 hook 脚本作为独立操作，宿主只抑制该属性，避免同一脚本执行两次；其余全部是上游行为：

- 程序路径为 `$dir\<installer.file>`，未声明 `file` 时回退到第一个下载文件名（与 `coalesce $installer.file $Name[0]` 一致），并做 `is_in_dir` 与存在性检查。
- 参数按 `$dir`、`$global`、`$version` 替换；`.ps1` 程序以 `& $progName @fnArgs` 在宿主内执行（Scoop 只对非 `.ps1` 程序套用 `Invoke-ExternalCommand`），其位置参数绑定行为也按上游。
- 非零退出经上游 `abort` 变为宿主非零退出，Coop 记录 `installers[i].exit_code`（1）并把程序自身的退出码保留在捕获输出中；`keep` 未设置时程序文件在成功后删除，`.ps1` 程序按 Scoop 不删除。
- 程序文字输出进入 `scripts/<序号>-<阶段>-program.stdout.log` / `.stderr.log`，事务日志写 `installers[i]` 记录：声明文件、参数、`keep`、目录、上下文、宿主、兼容库版本、退出码、字节数与尾部摘要。
- 执行顺序与 IR 计划一致：安装 `pre_install` → 安装器程序 → `installer.script` → `current`/入口/快捷方式/环境/持久化 → `post_install`；更新旧版本 `pre_uninstall` → 卸载器程序 → `uninstaller.script` → …；卸载同序且普通卸载保留声明的持久化数据。
- 程序是受信包内容的外部代码，项目根之外的注册表、服务、用户目录、下载或编译等副作用无法从事务撤销；Coop 只记录“副作用未知、未自动回滚、不会自动重试”。

真实共用根上的验证见下文；组合场景（安装器程序 + 多阶段脚本 + 持久化 + `current`）在隔离但真实的 CLI/PowerShell 环境中由 `tests/installer-programs.ps1` 完成安装、更新、卸载与失败回滚。

## 隔离与阻塞

- 所有实际执行的安装目标、7z 解压临时目录、脚本日志和事务恢复记录都位于当前项目根目录内；测试根还包含空格和中文路径。
- MSI 管理安装不执行：`msiexec` 的机器缓存写入位于 `%WINDIR%\Installer`，不是项目内路径。计划把该限制作为 `external_tools[].limitation` 和 `execution-blocked` 诊断输出，默认不提供该生命周期；这符合 AC4“无法隔离时留阻塞”，而不是把系统写入声称为已隔离。
- 注册表导入、服务控制、用户/系统环境变量、任意外部进程和用户目录写入：脚本文本不再被静态拒绝（#31），真实 PowerShell 会执行它们；这些是受信包内容的外部副作用，Coop 不声称可回滚，也不在测试中执行会修改真实注册表/用户数据的样本。安装器程序声明（#32）同样会真实执行其声明的程序，因此外部副作用保护与脚本相同。
- 需要管理员的真实系统安装不进入自动路径；没有绕过 UAC 或写入 HKLM/HKCU 的测试。
- `installer.file`/`installer.args` 已启用，但仍是“受信外部程序”语义：Coop 不承诺回滚其项目外副作用，也不为失败程序重试。需要管理员权限、会改注册表/服务/系统目录的程序仍不会在自动测试中执行。
- 真实 Main/Extras 中没有 `uninstaller.file/args` 样本；卸载器程序路径由真实 `.cmd` 程序在隔离根验证，未在真实共用根执行。
- `innosetup`、NSIS、MSI 载荷的**安装器结构**仍不解析；`installer.file` 只是启动声明的那一个文件，不等同于理解厂商安装器格式。

## 本轮运行状态

### #32（安装器/卸载器程序）

- 已运行：`tests/installer-programs.ps1`（CTest `installer_programs`，75 项检查）在项目内隔离根运行真实 CLI、真实 PowerShell 与固定 Scoop 兼容库：真实 `.cmd` 安装器程序（`$dir`/`$version`/`$global` 参数替换）、`args`-only 声明的下载文件名回退、`.ps1` 安装器程序（位置参数、`keep` 不删除）、`installer.script` 在程序之后、`post_install` 经 `current` 观察程序产物、安装器产物生成的命令入口可运行、持久化映射、更新时旧版本卸载器程序 + 卸载器脚本 → 新版本 `pre_install` → 新安装器程序 → `post_install`、`keep=false` 删除、普通卸载保留持久化数据、`pre_uninstall`/卸载器程序/`uninstaller.script`/`post_uninstall` 顺序、退出码 9 的程序失败与缺少程序的上游中止都被记录且回滚，包外路径声明被拒绝。
- 已运行（真实共用根）：`tests/real-scoop-installers.ps1` 在本机 `C:\Users\Neo\scoop`（Scoop v0.6.0，`main` 修订 `a97619fe`）只读预览真实 `Main/vcpkg`（`bootstrap-vcpkg.bat -disableMetrics` + `pre_install`/`post_install`/`uninstaller.script`，操作序列 `download,verify,extract,hook,installer,publish-current,entries,environment,persistence,hook,commit-state`），并执行真实 `Main/groovyserv` 生命周期：真实 `bin\setup.bat` 在 `apps/groovyserv/1.2.0` 运行并输出 `Setup completed successfully for windows_386`，其复制出的 `groovyclient.exe`/`groovyserver.exe` 随后被 `current` 发布并生成入口，`scoop list` 能列出该安装；Coop 卸载后 Scoop 不再列出，前后应用/入口/persist 集合一致，无 pending 事务。该包自己的 `setup.bat` 会在后台删除其占位脚本，因此本轮 `program_present_after_run=false` 来自包自身行为，`keep=true` 语义由隔离测试覆盖。
- 未运行（真实共用根）：`Main/vcpkg` 的实际生命周期。它自身的 `pre_install` 会把完整 vcpkg 仓库取到 `persist`、`post_install` 会写入用户 MSBuild 集成，超出本轮有界操作范围；本轮只做真实清单的只读预览（组合声明与顺序证据）。
- 未运行：真实共用根上的升级切换（`groovyserv` 本地只有单一版本）与真实 `uninstaller.file/args`（Main/Extras 无此声明）；两者由隔离真实环境覆盖。

### #16 / #31（机制调查与脚本宿主，历史）

- 已运行（#16 本轮）：`tests/installers.ps1` 在隔离根中运行真实 CLI、真实 Node.js 26.12.1 7z、真实 PowerShell 7 和项目测试程序；覆盖 7z 安装/卸载、MSI 预览与拒绝（不启动 `msiexec`）、Windows Installer 缓存前后对比、缺失工具、installer/uninstaller 脚本安装与更新顺序、上下文与退出码、失败回滚、rclone 原文卸载脚本、notepadplusplus/python 诊断，共 86 项检查；`windows_installer_cache.unchanged=true`。
- 后续变更（#31）：脚本文本不再作为兼容性判据，`tests/installers.ps1` 已改为断言真实 PowerShell 宿主与固定 Scoop 库，并把 7zip/notepadplusplus/python 的剩余阻塞归为 MSI/安装器机制；该测试现为 88 项检查。
- 已运行（回归）：`hooks`、`archive_lifecycle`、`plan`、`lifecycle`、`archive_safety` 在本轮代码上通过；`archive_safety` 的 MSI 缺失工具用例确认不误报支持。
- 静态/历史结果：真实 7z 产物的 SHA256 与固定样本一致；Scoop 源码顺序和脚本原文来自固定提交；验证者在 `6203f08` 观察到 MSI 机器缓存写入，本轮据此改为阻塞。
- 未运行：MSI 管理安装生命周期（隔离限制阻塞，需人类批准）、git/vscode/firefox/aider-desk 的真实 `#/dl.7z` 载荷、其他厂商 MSI、lessmsi、NSIS/Inno/WiX 提取、任意 MSI 的完整安装、真实用户目录安装、需要管理员的系统级安装、python installer.script 的实际执行、`Main/vcpkg` 的实际生命周期。

具体命令、退出码和证据位置见 Issue #16 / #31 / #32 报告与 `.local/pi/tasks/16|31|32/evidence`；#32 的真实共用根证据：`.local/pi/tasks/32/evidence/real-groovyserv-707adad45c48/`（`coop.exe` SHA256 `707adad4…`，源码头 `3a148a9`，含 `99-head-binding.txt`）；另一份同源构建的记录在 `real-groovyserv-9c1f95b7ce1e/` 与 `real-groovyserv-9c1f95b7ce1e-head-da62478/`，更早的 `real-groovyserv-3aa377072ef3/` 是中间构建。MSVC 同一源码重建会得到不同 PE 摘要，因此按运行目录区分，以源码头与测试日志为准。
