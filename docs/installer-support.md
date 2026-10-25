# Installer/Uninstaller 与特殊安装机制

日期：2026-10-25。任务：[T14 / #16](https://github.com/Coh1e/coop/issues/16)，父规格 [#2](https://github.com/Coh1e/coop/issues/2)。本文记录本轮实际启用的安装机制、真实样本、必要外部工具、隔离边界和未验证项；不是对任意 MSI、NSIS、Inno Setup 或安装器脚本的兼容承诺。

行为依据固定 Scoop 提交 `e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f` 的 [`Invoke-Extraction` / `Expand-7zipArchive` / `Expand-MsiArchive`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/decompress.ps1)、[`install_app` / `Invoke-Installer`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/install.ps1) 和固定样本 Manifest。实现只覆盖下面明确列出的机制。

## 机制与样本

| 机制 | 固定样本 | 本轮行为 | 证据 |
| --- | --- | --- | --- |
| ZIP / tar.gz 普通归档 | Main/ripgrep、Main/air | 原生 libarchive，既有 T09 覆盖 | `tests/archive-lifecycle.ps1` |
| 7z 普通归档 | Main/nodejs `node-v26.12.1-win-x64.7z` | 原生 libarchive 解压，`extract_dir` 与 `bin` 正常工作，不启动 7z.exe 或 PowerShell | `tests/installers.ps1` 安装真实 node 产物并运行 `node --version` → `v26.12.1` |
| `#/dl.7z` 自解压安装器载荷 | Extras/git、Extras/vscode、Extras/firefox、Extras/aider-desk | 按普通 7z 载荷交给 libarchive；不解析 NSIS/Inno 安装器结构。未下载这些大体积真实产物，因此生命周期未验证 | 仅计划层与机制边界；未运行 |
| MSI 管理安装提取 | Main/7zip `7z2605-x64.msi` | 调用系统 Windows Installer 的 `msiexec.exe /a ... /qn TARGETDIR=...`，在事务目录内提取，再按 `extract_dir` 合并；真实 7z.exe 可运行 | `tests/installers.ps1` 安装、更新、卸载真实 7-Zip 26.05 产物 |
| `installer.script` | Main/python（实际样本） | 阶段已接入生命周期；只有落在已证明脚本子集内的文本可执行。python 的 installer.script 依赖 `Expand-DarkArchive`、`Expand-MsiArchive`、子表达式等，明确阻塞 | 子集执行路径用测试脚本验证；python 样本只做诊断 |
| `uninstaller.script` | Main/rclone（实际样本） | 文本落在扩展后的子集内，按 `uninstaller` 阶段执行；`Get-Item` 只读取受限根下的 `LinkType`/`Length` | `tests/installers.ps1` 使用 rclone 原文在卸载时把 `rclone.conf` 保存到 persist |
| `reg import` 卸载脚本 | Main/7zip、Main/git、Extras/vscode、Extras/notepadplusplus | 不执行；注册表是进程外用户/系统状态，无法在项目内隔离。计划列出 `reg.exe` 与真实注册表需求 | `tests/installers.ps1` 使用 notepadplusplus 原文诊断 |
| Inno Setup / NSIS / 其他 EXE 安装器 | Extras/aider-desk、Main/python 的 setup.exe 等 | 不执行、不解析；Manifest 的 `innosetup` 或安装器进程声明仍拒绝 | 计划诊断 |
| `installer.file` / `installer.args` 进程声明 | 固定样本没有此类声明 | 不启用；外部程序失败无法从 Coop 事务安全回滚 | 计划诊断 |
| `post_uninstall` | Extras/aider-desk、Main/azure-cli | 仍不启用；样本会删除 `%APPDATA%` 或用户数据 | `tests/hooks.ps1` 诊断 |

普通压缩库能力只用于普通 7z 归档和 7z 自解压载荷；它不被描述成 MSI、NSIS 或 Inno Setup 的完整安装器提取能力。

## MSI 与外部工具

- MSI 不静态链接第三方 MSI 读取库，也不把 libarchive 的 7z 能力冒充 MSI 支持。
- 优先使用系统已安装的 `msiexec.exe` 做管理安装（administrative install）。Coop 在计划中输出 `external_tools`，包含工具名、用途、可用性和“永不自动下载或安装”的策略。
- 找不到 `msiexec.exe` 时，预览的 `execution_available=false`，诊断指出缺失工具；实际执行在下载和事务写入前失败，不会误报支持。
- 测试或固定解释器可用 `COOP_MSIEXEC` 指向当前子进程的明确工具路径；该变量不写用户或系统环境。第三方 `lessmsi` 未接入。
- MSI 提取目标、日志和临时文件都在当前事务目录内；子进程的 `TEMP`/`TMP` 指向事务内目录，`TARGETDIR` 的值单独加引号，避免含空格或 Unicode 的项目路径被 Windows Installer 误解析。管理安装不会注册产品，也不要求管理员权限；测试根位于项目内 `.local/tests`。
- MSI 失败时，`msiexec` 退出码、日志路径和 `failed` 状态写入事务日志；安装回滚，不发布 current、入口或管理记录。非零退出码不会重试。
- Main/7zip 的完整 Manifest 仍因 `post_install` 和 `uninstaller.script` 超出脚本子集而阻塞；本轮验证的是 MSI 机制加真实产物，不是整个 7zip 包的生命周期已完全接管。

## Installer/Uninstaller 脚本生命周期

脚本相位的顺序与固定 Scoop 一致：

- 安装：下载/校验 → 解压 → `pre_install`（具体版本目录）→ `installer.script`（具体版本目录，`$cmd=install`）→ 发布 `current`、入口、快捷方式和持久化 → `post_install`（`$dir=current`）→ 提交管理记录。
- 更新：旧版本 `pre_uninstall` → 旧版本 `uninstaller.script`（`$cmd=update`）→ 移除旧 `current`/入口/快捷方式 → 旧版本 `post_uninstall` → 新版本 `pre_install` → 新版本 `installer.script`（`$cmd=update`）→ 新 `current`/入口/持久化 → 新 `post_install` → 提交；旧版本默认保留。
- 卸载：`pre_uninstall` → `uninstaller.script`（`$cmd=uninstall`，`$dir` 仍指向版本目录）→ 移除 `current`/入口/快捷方式/版本目录 → `post_uninstall` → 提交；普通卸载保留声明数据。

脚本上下文、辅助函数和命令白名单见 [生命周期 Hook 与真实脚本兼容](script-support.md)。`installer.script` 和 `uninstaller.script` 与普通 Hook 共用同一静态检查、PowerShell 子进程、stdout/stderr 日志、退出码传播和失败回滚；脚本不自动重试，脚本造成的项目外副作用不声称可回滚。

固定样本中目前没有能通过子集的 `installer.script`；Main/python 的真实文本被明确诊断。`installer` 阶段的可执行路径用测试脚本验证顺序、上下文、退出码和失败传播，这不等于 python 样本已兼容。Main/rclone 的 `uninstaller.script` 原文可执行并已有真实运行证据。

## 隔离与阻塞

- 所有安装目标、MSI `TARGETDIR`、解压临时目录、脚本日志和事务恢复记录都位于当前项目根目录内；测试根还包含空格和中文路径。
- 注册表导入、服务控制、用户/系统环境变量、任意外部进程和用户目录写入不执行。计划列出缺失工具或系统状态需求，`execution_available=false`，不静默下载、安装或修改系统。
- 需要管理员的真实系统安装不进入自动路径；没有绕过 UAC 或写入 HKLM/HKCU 的测试。
- `installer.file`/`installer.args` 仍阻塞；没有真实样本和回滚证据，不把它与已证明的脚本阶段混同。

## 本轮运行状态

- 已运行（本轮）：`tests/installers.ps1` 在隔离根中运行真实 CLI、真实 7-Zip 26.05 MSI、真实 Node.js 26.12.1 7z、真实 PowerShell 7 和项目测试程序；覆盖 MSI 安装/更新/卸载、7z 安装/卸载、缺失工具、外部工具退出码 5 的失败传播、installer/uninstaller 脚本安装与更新顺序、上下文与退出码、失败回滚、rclone 原文卸载脚本、notepadplusplus/python 诊断，共 97 项检查。
- 已运行（回归）：`hooks`、`archive_lifecycle`、`plan`、`lifecycle`、`archive_safety` 在本轮代码上通过；`archive_safety` 已按 7z/MSI 新能力更新，MSI 缺失工具用例确认不误报支持。
- 静态/历史结果：真实 MSI 与 7z 产物的 SHA256 与固定样本一致；Scoop 源码顺序和脚本原文来自固定提交。
- 未运行：git/vscode/firefox/aider-desk 的真实 `#/dl.7z` 载荷、其他厂商 MSI、lessmsi、NSIS/Inno/WiX 提取、任意 MSI 的完整安装、真实用户目录安装、需要管理员的系统级安装、`installer.file/args` 进程、python installer.script 的实际执行。

具体命令、退出码和证据位置见 Issue #16 报告与 `.local/pi/tasks/16/evidence`。
