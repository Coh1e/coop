# Installer/Uninstaller 与特殊安装机制

日期：2026-10-25。任务：[T14 / #16](https://github.com/Coh1e/coop/issues/16)，父规格 [#2](https://github.com/Coh1e/coop/issues/2)。本文记录本轮实际启用的安装机制、真实样本、必要外部工具、隔离边界和未验证项；不是对任意 MSI、NSIS、Inno Setup 或安装器脚本的兼容承诺。

行为依据固定 Scoop 提交 `e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f` 的 [`Invoke-Extraction` / `Expand-7zipArchive` / `Expand-MsiArchive`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/decompress.ps1)、[`install_app` / `Invoke-Installer`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/install.ps1) 和固定样本 Manifest。实现只覆盖下面明确列出的机制。

## 机制与样本

| 机制 | 固定样本 | 本轮行为 | 证据 |
| --- | --- | --- | --- |
| ZIP / tar.gz 普通归档 | Main/ripgrep、Main/air | 原生 libarchive，既有 T09 覆盖 | `tests/archive-lifecycle.ps1` |
| 7z 普通归档 | Main/nodejs `node-v26.12.1-win-x64.7z` | 原生 libarchive 解压，`extract_dir` 与 `bin` 正常工作，不启动 7z.exe 或 PowerShell | `tests/installers.ps1` 安装真实 node 产物并运行 `node --version` → `v26.12.1` |
| `#/dl.7z` 自解压安装器载荷 | Extras/git、Extras/vscode、Extras/firefox、Extras/aider-desk | 按普通 7z 载荷交给 libarchive；不解析 NSIS/Inno 安装器结构。未下载这些大体积真实产物，因此生命周期未验证 | 仅计划层与机制边界；未运行 |
| MSI 管理安装提取 | Main/7zip `7z2605-x64.msi` | **未启用**。计划仍检测 `msiexec.exe` 并列出工具、可用性和隔离限制；`msiexec.exe /a` 会写入 `%WINDIR%\Installer` 的机器级 Windows Installer 缓存，超出项目根。为避免静默修改系统，执行明确阻塞 | 验证者在 `6203f08` 复现：`.local/pi/tasks/16/verify/06-msi-system-write.log`；本轮测试只验证预览/拒绝且测量缓存未变化 |
| `installer.script` | Main/python（实际样本） | 阶段已接入生命周期；只有落在已证明脚本子集内的文本可执行。python 的 installer.script 依赖 `Expand-DarkArchive`、`Expand-MsiArchive`、子表达式等，明确阻塞 | 子集执行路径用测试脚本验证；python 样本只做诊断 |
| `uninstaller.script` | Main/rclone（实际样本） | 文本落在扩展后的子集内，按 `uninstaller` 阶段执行；`Get-Item` 只读取受限根下的 `LinkType`/`Length` | `tests/installers.ps1` 使用 rclone 原文在卸载时把 `rclone.conf` 保存到 persist |
| `reg import` 卸载脚本 | Main/7zip、Main/git、Extras/vscode、Extras/notepadplusplus | 不执行；注册表是进程外用户/系统状态，无法在项目内隔离。计划列出 `reg.exe` 与真实注册表需求 | `tests/installers.ps1` 使用 notepadplusplus 原文诊断 |
| Inno Setup / NSIS / 其他 EXE 安装器 | Extras/aider-desk、Main/python 的 setup.exe 等 | 不执行、不解析；Manifest 的 `innosetup` 或安装器进程声明仍拒绝 | 计划诊断 |
| `installer.file` / `installer.args` 进程声明 | 固定样本没有此类声明 | 不启用；外部程序失败无法从 Coop 事务安全回滚 | 计划诊断 |
| `post_uninstall` | Extras/aider-desk、Main/azure-cli | 仍不启用；样本会删除 `%APPDATA%` 或用户数据 | `tests/hooks.ps1` 诊断 |

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

- 安装：下载/校验 → 解压 → `pre_install`（具体版本目录）→ `installer.script`（具体版本目录，`$cmd=install`）→ 发布 `current`、入口、快捷方式和持久化 → `post_install`（`$dir=current`）→ 提交管理记录。
- 更新：旧版本 `pre_uninstall` → 旧版本 `uninstaller.script`（`$cmd=update`）→ 移除旧 `current`/入口/快捷方式 → 旧版本 `post_uninstall` → 新版本 `pre_install` → 新版本 `installer.script`（`$cmd=update`）→ 新 `current`/入口/持久化 → 新 `post_install` → 提交；旧版本默认保留。
- 卸载：`pre_uninstall` → `uninstaller.script`（`$cmd=uninstall`，`$dir` 仍指向版本目录）→ 移除 `current`/入口/快捷方式/版本目录 → `post_uninstall` → 提交；普通卸载保留声明数据。

脚本上下文、辅助函数和命令白名单见 [生命周期 Hook 与真实脚本兼容](script-support.md)。`installer.script` 和 `uninstaller.script` 与普通 Hook 共用同一静态检查、PowerShell 子进程、stdout/stderr 日志、退出码传播和失败回滚；脚本不自动重试，脚本造成的项目外副作用不声称可回滚。

固定样本中目前没有能通过子集的 `installer.script`；Main/python 的真实文本被明确诊断。`installer` 阶段的可执行路径用测试脚本验证顺序、上下文、退出码和失败传播，这不等于 python 样本已兼容。Main/rclone 的 `uninstaller.script` 原文可执行并已有真实运行证据。

## 隔离与阻塞

- 所有实际执行的安装目标、7z 解压临时目录、脚本日志和事务恢复记录都位于当前项目根目录内；测试根还包含空格和中文路径。
- MSI 管理安装不执行：`msiexec` 的机器缓存写入位于 `%WINDIR%\Installer`，不是项目内路径。计划把该限制作为 `external_tools[].limitation` 和 `execution-blocked` 诊断输出，默认不提供该生命周期；这符合 AC4“无法隔离时留阻塞”，而不是把系统写入声称为已隔离。
- 注册表导入、服务控制、用户/系统环境变量、任意外部进程和用户目录写入不执行。计划列出缺失工具或系统状态需求，`execution_available=false`，不静默下载、安装或修改系统。
- 需要管理员的真实系统安装不进入自动路径；没有绕过 UAC 或写入 HKLM/HKCU 的测试。
- `installer.file`/`installer.args` 仍阻塞；没有真实样本和回滚证据，不把它与已证明的脚本阶段混同。

## 本轮运行状态

- 已运行（本轮）：`tests/installers.ps1` 在隔离根中运行真实 CLI、真实 Node.js 26.12.1 7z、真实 PowerShell 7 和项目测试程序；覆盖 7z 安装/卸载、MSI 预览与拒绝（不启动 `msiexec`）、Windows Installer 缓存前后对比、缺失工具、installer/uninstaller 脚本安装与更新顺序、上下文与退出码、失败回滚、rclone 原文卸载脚本、notepadplusplus/python 诊断，共 86 项检查；`windows_installer_cache.unchanged=true`。
- 已运行（回归）：`hooks`、`archive_lifecycle`、`plan`、`lifecycle`、`archive_safety` 在本轮代码上通过；`archive_safety` 的 MSI 缺失工具用例确认不误报支持。
- 静态/历史结果：真实 7z 产物的 SHA256 与固定样本一致；Scoop 源码顺序和脚本原文来自固定提交；验证者在 `6203f08` 观察到 MSI 机器缓存写入，本轮据此改为阻塞。
- 未运行：MSI 管理安装生命周期（隔离限制阻塞，需人类批准）、git/vscode/firefox/aider-desk 的真实 `#/dl.7z` 载荷、其他厂商 MSI、lessmsi、NSIS/Inno/WiX 提取、任意 MSI 的完整安装、真实用户目录安装、需要管理员的系统级安装、`installer.file/args` 进程、python installer.script 的实际执行。

具体命令、退出码和证据位置见 Issue #16 报告与 `.local/pi/tasks/16/evidence`。
