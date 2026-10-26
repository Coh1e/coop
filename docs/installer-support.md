# Installer/Uninstaller 与特殊安装机制

日期：2026-10-26。任务：[R14 / #35](https://github.com/Coh1e/coop/issues/35)（NSIS 软件完整生命周期）、[R13 / #34](https://github.com/Coh1e/coop/issues/34)（Inno Setup 软件完整生命周期）、[R12 / #33](https://github.com/Coh1e/coop/issues/33)（MSI 软件完整生命周期）、[R11 / #32](https://github.com/Coh1e/coop/issues/32)（安装器/卸载器程序与多阶段脚本组合执行）与 [T14 / #16](https://github.com/Coh1e/coop/issues/16)（首版安装器机制调查），父规格 [#21](https://github.com/Coh1e/coop/issues/21) 取代 [#2](https://github.com/Coh1e/coop/issues/2) 的冲突描述。本文记录本轮实际启用的安装机制、真实样本、必要系统组件、隔离边界和未验证项；不是对任意 MSI、NSIS、Inno Setup 或安装器脚本的兼容承诺。

行为依据固定 Scoop 提交 `e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f` 的 [`Invoke-Extraction` / `Expand-7zipArchive` / `Expand-MsiArchive`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/decompress.ps1)、[`install_app` / `Invoke-Installer`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/install.ps1) 和固定样本 Manifest。实现只覆盖下面明确列出的机制。

## 机制与样本

| 机制 | 固定样本 | 本轮行为 | 证据 |
| --- | --- | --- | --- |
| ZIP / tar.gz 普通归档 | Main/ripgrep、Main/air | 原生 libarchive，既有 T09 覆盖 | `tests/archive-lifecycle.ps1` |
| 7z 普通归档 | Main/nodejs `node-v26.12.1-win-x64.7z` | 原生 libarchive 解压，`extract_dir` 与 `bin` 正常工作，不启动 7z.exe 或 PowerShell | `tests/installers.ps1` 安装真实 node 产物并运行 `node --version` → `v26.12.1` |
| `#/dl.7z` 自解压安装器载荷 | Main/apngasm 3.1.3（NSIS）；Main/unzip 6.00；Main/git、Extras/vscode、Extras/firefox、Extras/aider-desk | 下载改名后按内容判定：NSIS 安装器载荷由 root 内已安装的 7-Zip helper 解包（#35），其余载荷（例如 7z SFX 或普通 7z 内容）交给原生 libarchive。R05 已用 Main/unzip 的真实下载改名、安装、运行和 Scoop reset 验证普通载荷；apngasm 的真实 NSIS 安装/更新/卸载与双向交替见 #35；大体积 Extras 安装器载荷仍未逐个运行 | `tests/archive-lifecycle.ps1`、`tests/real-scoop-archives.ps1`、`tests/nsis-lifecycle.ps1`、`tests/real-scoop-nsis.ps1`；大体积 Extras 载荷未运行 |
| MSI 管理镜像提取 | Main/7zip `7z2605-x64.msi`、`7z2603-x64.msi`；真实共用根 Main/kalker、Main/pkgconf | 已启用（#33）：只读 Windows Installer 数据库（`msi.dll`）+ Windows cabinet 解压 API（`cabinet.dll`）生成与 Scoop `Expand-MsiArchive` 相同的管理镜像，不启动 `msiexec`、不提权、不重启、不写 `%WINDIR%\Installer` 机器缓存。真实共用根上 Coop 与 Scoop 的版本目录逐文件 SHA256 相同 | `tests/msi-lifecycle.ps1`（26.05 安装 → 26.03 更新 → 卸载 → 损坏失败）、`tests/real-scoop-msi.ps1`（kalker/pkgconf 双向交替与镜像对比）；#16 的历史阻塞证据保留 |
| `installer.script` | Main/python（实际样本） | 阶段已接入生命周期；脚本作为受信文本由真实 PowerShell 与本机固定 Scoop 兼容库执行，不再按脚本文本子集拒绝（#31）。python 的 installer.script 仍依赖 MSI/Dark 机制，`Expand-DarkArchive` 找不到所需 helper 时在执行时明确失败 | `tests/installers.ps1` 用测试脚本验证顺序、上下文、退出码和失败传播；python 样本只做预览 |
| `installer.file` / `installer.args` 安装器程序 | Main/groovyserv `bin\setup.bat`（真实执行）；Main/vcpkg `bootstrap-vcpkg.bat -disableMetrics`（真实只读预览）；Extras 固定样本没有此类声明 | 已启用（#32）：程序由真实 PowerShell 宿主调用固定 Scoop 兼容库的 `Invoke-Installer` 执行；`$dir` 内含性检查、缺少程序时中止、`$dir`/`$global`/`$version` 参数替换、`.ps1` 直接调用、非零退出传播和 `keep=false` 删除程序文件都是上游行为 | `tests/installer-programs.ps1`（.cmd/.ps1/参数替换/keep/失败回滚）、`tests/real-scoop-installers.ps1`（真实 groovyserv 生命周期） |
| `uninstaller.file` / `uninstaller.args` 卸载器程序 | 固定样本与当前 Main/Extras 固定修订没有此类声明 | 已启用（#32）：与安装器程序共用同一 `Invoke-Installer` 路径并在卸载/更新旧版本时以 `$dir` 指向被移除版本目录 | `tests/installer-programs.ps1` 以真实 `.cmd` 卸载器程序验证顺序、`$dir` 参数和失败保护 |
| `uninstaller.script` | Main/rclone（实际样本） | 按 `uninstaller` 阶段在真实 PowerShell 中执行原文，`$dir`/`$persist_dir` 与 Scoop 一致 | `tests/installers.ps1` 使用 rclone 原文在卸载时把 `rclone.conf` 保存到 persist；`tests/hooks.ps1` 另用真实模板生成 `.reg` 文件（不 import） |
| `reg import` 卸载脚本 | Main/7zip、Main/git、Extras/vscode、Extras/notepadplusplus | 脚本文本不再被静态拒绝，`reg import` 会作为真实外部进程执行；注册表属于项目外的用户/系统状态，Coop 不声称可回滚 | Main/git 的 `post_install` 只把 bucket `.reg` 模板渲染进包目录，`tests/hooks.ps1` 执行该原文并核对编码与替换 |
| Inno Setup（`innosetup`） | 真实 Main/units 2.27/2.26 产物（项目内 Manifest 声明 `persist`）；真实 Main/rizin 0.9.1 产物（项目内变体声明 `extract_dir: bin`）；真实共用根 Main/units 2.27 | 已启用（#34）：定位 root 内已安装的 innounp helper（`innounp-unicode` 优先，其次 `innounp`；本地 root 后 global），以 Scoop `Expand-InnoArchive` 相同的参数与 `-c` 选择解包声明的 Inno 目录；不执行厂商安装器、不提权、不重启、不下载/安装/内嵌 helper。helper 缺失时预览 `execution_available=false` 并给出具名诊断 | `tests/inno-lifecycle.ps1`（真实 Units 2.27 → 2.26 更新、项目内变体的相对 `extract_dir` rizin `{app}\bin`、截断失败、缺失 helper、普通卸载）、`tests/real-scoop-inno.ps1`（真实共用根 Main/units 双向交替与逐文件镜像一致） |
| NSIS 安装器载荷 | 真实 Main/apngasm 3.1.3 NSIS 安装器（项目内变体的 3.1.1 更新）；真实 Main/elm 0.19.3 NSIS 安装器（`extract_dir: bin`）；真实共用根 Main/apngasm 3.1.3 | 已启用（#35）：声明为归档产物的可执行自解压器在摘要校验后按内容识别 NSIS FirstHeader 签名，再以 root 内已安装的 7-Zip helper 按 Scoop `Expand-7zipArchive` 相同参数解包；不执行 `setup.exe`、不提权、不重启、不下载/安装/内嵌 helper。helper 缺失或截断载荷在发布版本前具名失败；预览给出 helper 实际可用性与条件性说明 | `tests/nsis-lifecycle.ps1`（真实 apngasm 3.1.3 → 3.1.1 更新、`$PLUGINSDIR`/`Uninstall.exe` 由真实 `pre_install` 移除、elm 的 `-ir!bin\*` 选择、截断失败、缺失 helper、普通卸载）、`tests/real-scoop-nsis.ps1`（真实共用根 Main/apngasm 双向交替与逐文件镜像一致） |
| 其他厂商 EXE 安装器（WiX/Dark、自定义引导程序） | Main/python 的 setup.exe 等 | 安装器结构仍未解析；`installer.file/args` 作为普通程序声明已启用（#32），二者都不等于理解厂商安装器格式 | 计划诊断 |
| `installer.file` / `installer.args` 进程声明 | Main/groovyserv、Main/vcpkg（真实声明） | 已启用（#32）：程序在版本目录运行，位于 `pre_install` 之后、`current`/入口发布之前；失败使包操作失败并回滚已创建的包状态，项目外副作用不承诺回滚且不自动重试 | `tests/installer-programs.ps1`、`tests/real-scoop-installers.ps1` |
| `post_uninstall` | Extras/aider-desk、Main/azure-cli | 已启用（#31）：在版本目录移除后由真实 PowerShell 执行，`$dir` 仍指向已移除的版本路径；样本自身删除用户数据的行为是受信脚本副作用，测试只用项目内合成脚本验证阶段语义 | `tests/hooks.ps1` |

普通压缩库能力只用于普通 7z 归档和 7z 自解压载荷；MSI 的内嵌 cabinet 由 Windows cabinet 解压 API 处理；Inno Setup 的厂商载荷由 root 内声明的 innounp helper 解包；NSIS 安装器载荷由 root 内声明的 7-Zip helper 解包。这些路径都不被描述成其他厂商安装器（例如 WiX/Dark、自定义引导程序）的完整安装器提取能力。

## MSI 管理镜像提取（#33）

Scoop 的 `Expand-MsiArchive` 用 `msiexec /a` 生成管理镜像；#16 的证据表明该路径会写入 `%WINDIR%\Installer` 机器缓存，超出项目根。R12 没有直接采用该路径，也没有缩减目标：Coop 从 MSI 数据库本身生成同一个管理镜像。

- **数据库只读**：用 Windows Installer 数据库 API（`msi.dll`）以 `MSIDBOPEN_READONLY` 打开数据库，查询 `Directory`、`Component`、`File`、`Media` 与 `_Streams` 表；不调用 `msiexec`、不执行 `MsiInstallProduct`、不注册产品，也没有产品卸载登记。
- **布局**：镜像根为 `TARGETDIR`，其余目录按 `Directory_Parent` 与 `DefaultDir` 的长目标名解析；`.` 保持父目录，`..` 上移；既有计划继续在镜像之后应用 `extract_dir`/`extract_to`。该规则与 `msiexec /a` 的镜像一致：真实共用根上 Coop 与 Scoop 安装同一 MSI 后，版本目录的文件集合与逐文件 SHA256 相同（`kalker`、`pkgconf`）。
- **cabinet 与文件**：`Media.Cabinet` 的 `#name` 内嵌 cabinet 从 `_Streams` 取出后交给 Windows cabinet 解压 API（`cabinet.dll` 的 `FDICopy`），支持多 folder、MSZIP 与 LZX；cabinet 条目名是 File 表主键，落盘使用 File 表长文件名。未压缩文件（`Sequence=0` 或 `msiFileAttributesNoncompressed`）直接从 `_Streams` 写出。每个文件与 File 表声明的大小核对，失败即中止。
- **权限与重启**：不请求提权，不写系统目录、注册表或服务；管理镜像提取不执行厂商安装器的重启安排，因此不需要重启。预览的 `package.msi_extraction` 明确给出 `elevation`、`reboot`、`machine_cache`、`msiexec_started`、`administrative_install` 与所用 API 路径，`artifacts[].requires_elevation`/`reboot_required` 为 `false`。
- **必要组件**：`external_tools` 以 `Windows Installer APIs` 列出 `msi.dll` 与 `cabinet.dll` 的检测结果，策略是 Windows 系统组件、Coop 不下载也不安装，`limitation` 写明只读边界；缺失时在执行前阻塞。
- **边界与失败**：外部 cabinet（`Media.Cabinet` 不以 `#` 开头）、多段/partial cabinet、cabinet 结构损坏、`_Streams` 缺流、File/Component/Directory 表引用缺失，都会在发布版本前以具名非零错误失败并回滚；不会回退到 `msiexec`。厂商 EXE 安装器（Inno/NSIS/自定义引导程序）不属于本机制。
- **与 `msiexec /a` 镜像的已记录差异**：不写管理镜像自带的 MSI 文件副本，也不创建仅承载快捷方式组件的空目录（其中没有包文件）。
- **运行记录**：安装事务日志的 `msi_extractions[i]` 记录只读访问、cabinet 名与 cabinet 文件数、未压缩流数、文件数与字节数，以及 `msiexec_started=false`、权限/重启/机器缓存说明。

## Inno Setup 提取（#34）

Scoop 的 `Expand-InnoArchive` 本身不解析 Inno Setup 格式，而是调用单独安装的 [innounp](https://www.rathlev-home.de/tools/prog-e.html#unpack)。R13 沿用同一条路线，不把 innounp 嵌入 `coop.exe`，也不把外部软件依赖混同为核心依赖。

- **辅助工具明确声明**：预览的 `package.inno_setup` 给出 `helper`、`helper_available`、`helper_problem`、查找位置、参数与 `-c` 选择规则、权限/重启/安装器效果边界；`external_tools` 以 `innounp (Inno Setup unpacker)` 单独列出 `available`/`enabled`/`path`/`policy`/`limitation`。helper 的查找顺序与 Scoop `Get-AppFilePath` 一致：本地 root 的 `apps/innounp-unicode/current/innounp.exe`、本地 `apps/innounp/current/innounp.exe`，再到可选 global root。缺失时预览 `execution_available=false`、诊断 `execution-blocked`，执行在创建事务前以具名非零失败；Coop 不会下载、安装或替换 helper。
- **参数与选择**：按固定 Scoop 0.6.0 的 `Expand-InnoArchive` 顺序传入 `-x -d<目标目录> <setup.exe> -y -c<选择>`。`extract_dir` 为空时选择 `{app}`；相对路径选择 `{app}\<extract_dir>`；以 `{` 开头时原样传递（例如 `{app}\bin`）。预览的 `artifacts[].inno_selection` 展示具体 `-c` 值，而不是只给出规则。
- **布局**：helper 只解包选中的 Inno 目录，文件内容与时间戳来自 innounp；已选目录直接作为包根，再由统一的 `extract_to` 逻辑发布，不再重复应用 `extract_dir`。真实共用根上 Coop 与 Scoop 安装同一 Main/units 2.27 后的版本目录 15 个文件逐文件 SHA256 相同；项目内变体为真实 rizin 0.9.1 安装器声明 `extract_dir: bin`，只发布声明的 37 个 `{app}\bin` 文件。
- **不执行厂商安装器**：不启动 `setup.exe`，不请求提权，不安排重启；厂商安装器的 `[Run]`、`[Registry]`、服务、开始菜单项与卸载登记都不会被创建，因此该机制不是任意 Inno 安装器的完整安装替代。加密安装器需要密码，当前不提供；innounp 无法识别的 Inno 版本或损坏产物在发布版本前以具名非零失败并回滚。
- **运行记录**：事务日志 `inno_extractions[i]` 记录 helper 路径与 SHA256、完整参数、`selection`、退出码、stdout/stderr 日志与尾部、文件数与字节数，以及 `installer_executed=false`、权限/重启/安装器效果说明；非零 helper 退出不会留下 `inno_extractions` 成功记录。

## NSIS 安装器载荷提取（#35）

Scoop 没有单独的 `nsis` 字段：Manifest 通过 `url: ...setup.exe#/dl.7z` 之类的改名把可执行自解压器声明为归档载荷，实际由 `Expand-7zipArchive` 调用的 7-Zip 识别格式并解包。R14 沿用同一条路线，不解包厂商安装器的“安装过程”，也不把 7-Zip 变成 Coop 核心依赖。

- **内容判定，而非文件名**：声明后缀只描述传输形式，同一种 `#/dl.7z` 可能是 7z SFX、普通 7z 内容或 NSIS 安装器。Coop 在摘要校验后检查载荷字节中的 NSIS FirstHeader 签名（`DE AD BE EF` + ASCII `NullsoftInst`），命中时才使用 7-Zip helper；其他载荷继续交给原生 libarchive，普通 ZIP/7z/tar 不因此需要外部工具。预览的 `package.nsis_extraction` 给出该判定规则与签名，`artifacts[].payload_check` 说明单产物规则；执行日志的 `nsis_extractions[i].detection` 记录命中的字节偏移。
- **辅助工具明确声明**：预览的 `package.nsis_extraction` 给出 `helper`、`helper_available`、`helper_problem`、查找位置、参数规则、权限/重启/安装器效果边界；`external_tools` 以 `7-Zip (NSIS installer payloads)` 单独列出 `available`/`enabled`/`path`/`policy`/`limitation`。helper 查找顺序与 Scoop `Get-AppFilePath` 一致：本地 root 的 `apps/7zip/current/7z.exe`，再到可选 global root。它是单独的软件依赖，Coop 不下载、安装、内嵌或替换；普通归档不会因为缺少它而受阻。
- **参数与选择**：按固定 Scoop 0.6.0 的 `Expand-7zipArchive` 传入 `x <payload> -o<目标目录> -xr!*.nsis -y`，声明 `extract_dir` 时追加 `-ir!<extract_dir>\*`，预览与执行日志都给出完整参数与实际 `selection`。
- **布局**：7-Zip 解出整个 NSIS 载荷（或 `extract_dir` 匹配的文件），再由统一的 `extract_dir`/`extract_to` 逻辑发布；`$PLUGINSDIR`、`Uninstall.exe` 等载荷条目在 Manifest 自己的 Hook 运行前保持原样，和 Scoop 的顺序一致。真实 Main/apngasm 3.1.3 的解包树为 16 个文件，其 `pre_install` 随后移除 `$PLUGINSDIR` 与 `Uninstall.exe`；真实 Main/elm 0.19.3 声明 `extract_dir: bin`，`-ir!bin\*` 只解出 `bin/elm.exe` 并提升到包根，安装后只有 1 个非记录文件且真实 `elm --version` 返回 `0.19.3`。
- **不执行厂商安装器**：不启动 `setup.exe`，不请求提权，不安排重启；厂商安装器写入的安装目录、`[Run]`、注册表、服务、开始菜单项与卸载登记都不会被创建，因此该机制不是任意 NSIS 安装器的完整安装替代。helper 缺失、载荷截断或 7-Zip 无法识别的 NSIS 变体在发布版本前以具名非零失败并回滚。
- **运行记录**：事务日志 `nsis_extractions[i]` 记录 helper 路径与 SHA256、完整参数、`selection`、`detection`、退出码、stdout/stderr 日志与尾部、文件数与字节数，以及 `installer_executed=false`、权限/重启/安装器效果说明；非零 helper 退出不会留下 `nsis_extractions` 成功记录。

## Installer/Uninstaller 脚本生命周期

脚本相位的顺序与固定 Scoop 一致：

- 安装：下载/校验 → 解压 → `pre_install`（具体版本目录）→ `installer.script`（具体版本目录）→ 发布 `current`、入口、快捷方式和持久化 → `post_install`（`$dir=current`）→ 提交管理记录。
- 更新：旧版本 `pre_uninstall` → 旧版本 `uninstaller.script` → 移除旧 `current`/入口/快捷方式 → 旧版本 `post_uninstall` → 新版本 `pre_install` → 新版本 `installer.script` → 新 `current`/入口/持久化 → 新 `post_install` → 提交；旧版本默认保留。
- 卸载：`pre_uninstall` → `uninstaller.script`（`$dir` 仍指向版本目录）→ 移除 `current`/入口/快捷方式/版本目录 → `post_uninstall` → 提交；普通卸载保留声明数据。

阶段区分来自 IR Hook，`$purge` 只在卸载会话中定义；`$cmd` 不是 Scoop 0.6.0 的 Hook 变量（见[生命周期 Hook 与真实 PowerShell](script-support.md)），因此依赖它的 `if ($cmd -eq 'uninstall')` 分支在 Coop 与 Scoop 中都不执行。

脚本上下文、辅助函数和阶段语义见 [生命周期 Hook 与真实 PowerShell](script-support.md)。`installer.script` 和 `uninstaller.script` 与普通 Hook 共用同一真实 PowerShell 宿主、固定 Scoop 兼容库、stdout/stderr 日志、退出码传播和失败回滚；脚本不自动重试，脚本造成的项目外副作用不声称可回滚。

`installer.script` 不再按文本子集拒绝：Main/python 的原文会交给真实 PowerShell；其中的 `Expand-DarkArchive` 等厂商安装器机制仍属于后续任务（Dark），缺少 helper 时以非零退出码失败，这不等于 python 样本已兼容。NSIS 安装器载荷本身已由 R14/#35 通过 7-Zip helper 支持，但那是 Coop 的产物解包路径，不等于让脚本里的任意厂商安装器文本自动变成可执行。`installer` 阶段的可执行路径用测试脚本验证顺序、上下文、退出码和失败传播。Main/rclone 的 `uninstaller.script` 原文已在隔离测试与真实共用根的生命周期中实际运行。

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

- 所有实际执行的安装目标、7z 解压临时目录、MSI cabinet 临时文件、脚本日志和事务恢复记录都位于当前项目根目录内；测试根还包含空格和中文路径。
- Inno Setup 提取不启动厂商 `setup.exe`；Coop 只启动 root 内已安装的 innounp helper。隔离测试从固定 innounp 包归档提供 helper 并断言其文件逐个 SHA256 不变，证明既未下载也未替换；未在隔离测试中执行需要管理员权限的厂商安装器。
- NSIS 载荷提取同样不启动厂商 `setup.exe`；Coop 只启动 root 内已安装的 7-Zip helper，并用同样的完整进程观察确认 `setup.exe` 从未被启动。隔离测试先用固定 7-Zip 26.05 MSI 以 Coop 自己的 MSI 路径安装一个普通 `7zip` helper 包，再断言该包在 NSIS 安装/更新/失败/卸载前后逐文件 SHA256 不变，证明 Coop 未下载或替换 helper。
- MSI 管理镜像提取不调用 `msiexec`，不需要提权或重启，也不写 `%WINDIR%\Installer`。测试在真实机器缓存前后快照上断言 Coop 的安装/更新/卸载不改变它；同一次真实交替运行中 Scoop 自己的 MSI 安装会改变该缓存，按客户端分别记录，不把另一客户端的行为算作 Coop 已隔离。
- 注册表导入、服务控制、用户/系统环境变量、任意外部进程和用户目录写入：脚本文本不再被静态拒绝（#31），真实 PowerShell 会执行它们；这些是受信包内容的外部副作用，Coop 不声称可回滚，也不在测试中执行会修改真实注册表/用户数据的样本。安装器程序声明（#32）同样会真实执行其声明的程序，因此外部副作用保护与脚本相同。
- 需要管理员的真实系统安装不进入自动路径；没有绕过 UAC 或写入 HKLM/HKCU 的测试。
- `installer.file`/`installer.args` 已启用，但仍是“受信外部程序”语义：Coop 不承诺回滚其项目外副作用，也不为失败程序重试。需要管理员权限、会改注册表/服务/系统目录的程序仍不会在自动测试中执行。
- 真实 Main/Extras 中没有 `uninstaller.file/args` 样本；卸载器程序路径由真实 `.cmd` 程序在隔离根验证，未在真实共用根执行。
- `innosetup` 已按 #34 通过 root 内声明的 innounp helper 提取声明的 Inno 目录；NSIS 安装器**载荷**已按 #35 通过 root 内声明的 7-Zip helper 解包。WiX/Dark 与厂商 MSI 引导程序的**安装器结构**仍不解析，MSI 支持的是管理镜像提取，`installer.file` 只是启动声明的那一个文件，它们都不等同于理解厂商安装器格式。

## 本轮运行状态

### #35（NSIS 软件完整生命周期）

- 已运行：`tests/nsis-lifecycle.ps1`（CTest `nsis_lifecycle`，151 项检查）在项目内隔离根（路径含空格与中文）用真实 CLI、真实 apngasm 3.1.3/3.1.1 与 elm 0.19.3 NSIS 安装器、真实 PowerShell 与固定 7-Zip 26.05 helper 覆盖：helper 先由固定 `7z2605-x64.msi` 经 Coop 自己的 MSI 路径安装为普通 `7zip` 包；预览只列内容判定规则、helper/参数/边界且不启动任何子进程；安装 3.1.3（守卫进程为 `coop.exe` + `apps/7zip/.../7z.exe` + 真实 `pwsh.exe`，无 `setup.exe`/`msiexec`；16 个文件、事务 `nsis_extractions` 记录签名偏移 65028 与 `-xr!*.nsis` 参数、真实 `apngasm 3.1.3` 横幅、`$PLUGINSDIR`/`Uninstall.exe` 被真实 `pre_install` 移除、Scoop 记录与两个命令入口）；更新 3.1.1（旧版本保留、`current` 重指、真实程序横幅切换）；elm 的 `extract_dir: bin` 通过 `-ir!bin\*` 只发布 1 个文件且真实 `elm --version` 可运行；截断载荷在 helper 阶段非零并回滚，原版本继续运行；helper 缺失时预览声明不可用，执行前失败且未下载/重建 helper；普通卸载清理当前版本与入口并保留旧的 3.1.3 版本供显式清理。证据：`.local/pi/tasks/35/evidence/nsis-lifecycle-df5525537d8c-r2/evidence.json`（`coop.exe` SHA256 `df552553…`，另含逐次 `run-*.json` 与 `ctest-nsis_lifecycle.log`；同一源码更早的 `nsis-lifecycle-df5525537d8c/` 是未含 elm 用例的中间运行，保留不覆盖）。
- 已运行（真实共用根）：`tests/real-scoop-nsis.ps1` 在本机 `C:\Users\Neo\scoop`（Scoop v0.6.0，`main` 修订 `a97619fe`）只读预览真实 `Main/apngasm` 3.1.3，然后执行双向交替：Coop 安装（守卫进程为 `coop.exe`、真实 `apps/7zip/26.05/7z.exe` 与真实 `pwsh.exe`；事务 `nsis_extractions` 的 7-Zip 输出显示 `Cannot open the file as [7z] archive` / `The file is open as [Nsis] archive`、16 个文件、`installer_executed=false`）→ Scoop `uninstall` → Scoop `install` → Coop `uninstall`。Coop 与 Scoop 生成的版本目录 8 个非记录文件逐文件 SHA256 相同；`apngasm` 横幅、`scoop list` 与 `coop list` 在每一步互相识别；结束后的 apps/persist/shims/Coop 记录集合与运行前一致、无 pending 事务、`apps/7zip` helper 逐文件不变。证据：`.local/pi/tasks/35/evidence/real-scoop-nsis-df5525537d8c/`（`coop.exe` SHA256 `df552553…`，含 `00-versions.txt`、`03-apngasm-coop-image.txt`、`05-apngasm-scoop-image.txt`、`99-summary.json`）。
- 未运行：Extras 中大体量的 Electron/NSIS 载荷（例如 `aider-desk`）与需要在 `installer.script` 中再次调用 `Expand-7zipArchive` 的真实样本的逐个实跑；真实共用根上的 NSIS 更新（本地 `main` bucket 的 apngasm 只有单一 3.1.3，更新由真实 3.1.3→3.1.1 产物的隔离测试覆盖）；加密或 7-Zip 无法识别的 NSIS 变体（边界由代码拒绝路径与截断失败描述，未构造伪造样本）；真实 NSIS 厂商安装器的项目外副作用（不执行 `setup.exe`，因此不声称覆盖）。

### #34（Inno Setup 软件完整生命周期）

- 已运行：`tests/inno-lifecycle.ps1`（CTest `inno_lifecycle`，130 项检查）在项目内隔离根（路径含空格与中文）用真实 CLI、真实 GNU Units 2.27/2.26 Inno Setup 产物、真实 rizin 0.9.1 安装器和固定 innounp 2.71.2 helper 覆盖：预览只列 helper/参数/选择/边界且不启动任何子进程；安装 2.27（守卫进程只有 `coop.exe` 与 `innounp.exe`，无 `setup.exe`/`msiexec`；15 个文件、持久化 junction、Scoop 记录、真实 `units.exe --version` 与单位换算）；更新 2.26（旧版本保留、`current` 重指、真实程序版本切换、持久化数据复用）；rizin 的 `extract_dir: bin` 只得到 37 个 `{app}\bin` 文件且真实 `rizin -v` 可运行；截断产物在 helper 阶段非零并回滚，原版本继续运行；helper 缺失时预览 `execution_available=false`、执行前阻塞，Coop 未下载/重建 helper；普通卸载保留声明的持久化数据。证据：`.local/pi/tasks/34/evidence/inno-lifecycle-de37b4f567e7/evidence.json`。
- 已运行（真实共用根）：`tests/real-scoop-inno.ps1` 在本机 `C:\Users\Neo\scoop`（Scoop v0.6.0，`main` 修订 `a97619fe`）只读预览真实 `Main/units` 2.27，然后执行双向交替：Coop 安装（守卫进程只有 `coop.exe` 与真实 `apps/innounp/2.71.2/innounp.exe`；事务 `inno_extractions` 记录 `-c{app}`、15 个文件、`installer_executed=false`）→ Scoop `uninstall` → Scoop `install` → Coop `uninstall`。Coop 与 Scoop 生成的版本目录 15 个文件逐文件 SHA256 相同；`units --version`、`scoop list` 与 `coop list` 在每一步互相识别；结束后的 apps/persist/shims/Coop 记录集合与运行前一致、无 pending 事务、helper 包逐文件不变。
- 未运行：加密 Inno Setup 安装器、innounp 不支持的 Inno 版本和需要提权的真实厂商安装器（边界由代码拒绝路径与具名失败描述，未构造伪造样本）；真实共用根上的 Inno 更新（固定 bucket 只有单一 units 版本，更新由真实 2.27→2.26 产物的隔离测试覆盖）；Extras 中其余 Inno 包（本地只有 main bucket）的逐个实跑。

### #33（MSI 软件完整生命周期）

- 已运行：`tests/msi-lifecycle.ps1`（CTest `msi_lifecycle`，71 项检查）在项目内隔离根用真实 CLI、真实 7-Zip 26.05/26.03 MSI 产物和 `process_guard` 覆盖：预览只读事实（`elevation`/`reboot`/`machine_cache`/`msiexec_started`、API 路径、`external_tools`）、真实安装（版本目录/`Lang`/持久化 junction/Scoop 记录/入口、事务 `msi_extractions` 的 106 个 cabinet 文件与 5903862 字节）、26.05 → 26.03 更新（旧版本保留、`current` 重指、真实 `7z.exe` 版本切换、持久化数据复用）、普通卸载保留数据，以及截断 MSI 的更新/安装失败（在数据库阶段非零、回滚、原版本继续可运行）。预览、安装、更新、卸载和失败全程 `Observed workload processes: 1`，Windows Installer 机器缓存前后快照不变。
- 已运行（真实共用根）：`tests/real-scoop-msi.ps1` 在本机 `C:\Users\Neo\scoop`（Scoop v0.6.0，`main` 修订 `a97619fe`）只读预览已安装 `Main/7zip` 的 MSI 更新，并对真实 `Main/kalker` 2.2.3 与 `Main/pkgconf` 3.0.10 执行双向交替：Coop 安装（守卫进程证明只启动 `coop.exe`）→ Scoop `uninstall` → Scoop `install` → Coop `uninstall`。Coop 与 Scoop 生成的版本目录文件集合和逐文件 SHA256 相同（`kalker` 1 个文件，`pkgconf` 5 个文件）；`scoop list` 与 `coop list` 在每一步互相识别；Coop 每次操作前后 `%WINDIR%\Installer` 快照不变，Scoop 自己的安装使缓存条目 +1（按客户端分别记录）；结束后的 apps/persist/shims/Coop 记录集合与运行前一致且无 pending 事务。
- 未运行：需要外部 cabinet、多段 cabinet 或厂商引导程序的真实 MSI 样本（Main/Extras 固定修订未发现；边界由代码拒绝路径和文档说明，未构造伪造样本）；真实共用根上的 MSI 更新（kalker/pkgconf 在固定 bucket 中只有单一版本，更新由真实 26.05→26.03 产物的隔离测试覆盖）；真实 `Main/7zip` 的更新/卸载执行（它是用户日常工具，本轮只做只读预览；其 MSI 机制与布局已由同产物隔离测试和真实共用根镜像对比覆盖）。

### #32（安装器/卸载器程序）

- 已运行：`tests/installer-programs.ps1`（CTest `installer_programs`，75 项检查）在项目内隔离根运行真实 CLI、真实 PowerShell 与固定 Scoop 兼容库：真实 `.cmd` 安装器程序（`$dir`/`$version`/`$global` 参数替换）、`args`-only 声明的下载文件名回退、`.ps1` 安装器程序（位置参数、`keep` 不删除）、`installer.script` 在程序之后、`post_install` 经 `current` 观察程序产物、安装器产物生成的命令入口可运行、持久化映射、更新时旧版本卸载器程序 + 卸载器脚本 → 新版本 `pre_install` → 新安装器程序 → `post_install`、`keep=false` 删除、普通卸载保留持久化数据、`pre_uninstall`/卸载器程序/`uninstaller.script`/`post_uninstall` 顺序、退出码 9 的程序失败与缺少程序的上游中止都被记录且回滚，包外路径声明被拒绝。
- 已运行（真实共用根）：`tests/real-scoop-installers.ps1` 在本机 `C:\Users\Neo\scoop`（Scoop v0.6.0，`main` 修订 `a97619fe`）只读预览真实 `Main/vcpkg`（`bootstrap-vcpkg.bat -disableMetrics` + `pre_install`/`post_install`/`uninstaller.script`，操作序列 `download,verify,extract,hook,installer,publish-current,entries,environment,persistence,hook,commit-state`），并执行真实 `Main/groovyserv` 生命周期：真实 `bin\setup.bat` 在 `apps/groovyserv/1.2.0` 运行并输出 `Setup completed successfully for windows_386`，其复制出的 `groovyclient.exe`/`groovyserver.exe` 随后被 `current` 发布并生成入口，`scoop list` 能列出该安装；Coop 卸载后 Scoop 不再列出，前后应用/入口/persist 集合一致，无 pending 事务。该包自己的 `setup.bat` 会在后台删除其占位脚本，因此本轮 `program_present_after_run=false` 来自包自身行为，`keep=true` 语义由隔离测试覆盖。
- 未运行（真实共用根）：`Main/vcpkg` 的实际生命周期。它自身的 `pre_install` 会把完整 vcpkg 仓库取到 `persist`、`post_install` 会写入用户 MSBuild 集成，超出本轮有界操作范围；本轮只做真实清单的只读预览（组合声明与顺序证据）。
- 未运行：真实共用根上的升级切换（`groovyserv` 本地只有单一版本）与真实 `uninstaller.file/args`（Main/Extras 无此声明）；两者由隔离真实环境覆盖。

### #16 / #31（机制调查与脚本宿主，历史）

- 已运行（#16 本轮，历史）：`tests/installers.ps1` 在隔离根中运行真实 CLI、真实 Node.js 26.12.1 7z、真实 PowerShell 7 和项目测试程序；当时 MSI 被阻塞，只验证预览/拒绝与 Windows Installer 缓存前后对比；#33 已用只读提取取代该阻塞。
- 后续变更（#31）：脚本文本不再作为兼容性判据，`tests/installers.ps1` 已改为断言真实 PowerShell 宿主与固定 Scoop 库；#33 后该测试只保留 MSI 预览事实，MSI 执行归 `tests/msi-lifecycle.ps1`。
- 已运行（回归）：`hooks`、`archive_lifecycle`、`plan`、`lifecycle`、`archive_safety` 在 #31 代码上通过；#33 后在最终代码上重跑完整 CTest（见 #33 报告）。
- 静态/历史结果：真实 7z 产物的 SHA256 与固定样本一致；Scoop 源码顺序和脚本原文来自固定提交；验证者在 `6203f08` 观察到 `msiexec /a` 的机器缓存写入，这是 #16 当时的阻塞依据。
- 未运行（历史）：MSI 管理安装生命周期、git/vscode/firefox/aider-desk 的真实 `#/dl.7z` 载荷、其他厂商 MSI、lessmsi、NSIS/Inno/WiX 提取（当时）、任意 MSI 的完整安装、真实用户目录安装、需要管理员的系统级安装、python installer.script 的实际执行、`Main/vcpkg` 的实际生命周期（其中 NSIS 载荷提取已由 #35 交付，Inno Setup 已由 #34 交付，WiX/Dark 仍为待办）。

具体命令、退出码和证据位置见 Issue #16 / #31 / #32 / #33 / #34 / #35 报告与 `.local/pi/tasks/16|31|32|33|34|35/evidence`；#35 的真实共用根证据见上文；#34 的真实共用根证据：`.local/pi/tasks/34/evidence/real-scoop-inno-de37b4f567e7/`（`coop.exe` SHA256 `de37b4f5…`，含 `00-versions.txt`、`03-units-coop-image.txt`、`05-units-scoop-image.txt`、`99-summary.json`）；#33 的真实共用根证据：`.local/pi/tasks/33/evidence/real-scoop-msi-4c75be4f5758/`（`coop.exe` SHA256 `4c75be4f…`，含 `00-versions.txt` 与 `99-summary.json`）；#32 的真实共用根证据：`.local/pi/tasks/32/evidence/real-groovyserv-707adad45c48/`（`coop.exe` SHA256 `707adad4…`，源码头 `3a148a9`，含 `99-head-binding.txt`）；另一份同源构建的记录在 `real-groovyserv-9c1f95b7ce1e/` 与 `real-groovyserv-9c1f95b7ce1e-head-da62478/`，更早的 `real-groovyserv-3aa377072ef3/` 是中间构建。MSVC 同一源码重建会得到不同 PE 摘要，因此按运行目录区分，以源码头与测试日志为准。
