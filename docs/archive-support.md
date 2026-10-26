# 普通归档的原生生命周期覆盖

日期：2026-10-26。任务：[R05 / #26](https://github.com/Coh1e/coop/issues/26)，父规格 [#21](https://github.com/Coh1e/coop/issues/21)。本文记录当前实际启用的普通归档格式、布局语义、真实样本、验证方式与仍不适用的机制；不是对整个归档生态的兼容承诺。安装器边界见 [Installer/Uninstaller 与特殊安装机制](installer-support.md)，多下载项、架构与摘要算法见[多产物、架构与摘要算法支持](multi-artifact-support.md)。

## 库与构建

| 依赖 | 固定版本 | 用途 | 许可 |
| --- | --- | --- | --- |
| libarchive | 3.7.7 | ZIP、tar、7z 读取与条目遍历 | BSD-2-Clause |
| zlib | 1.3.1 | ZIP deflate、gzip 压缩流 | zlib |
| xz / liblzma | 5.6.4 | 7z LZMA/LZMA2、xz 与 lzma 压缩流 | 0BSD |
| zstd | 1.5.7 | zstd 压缩流（`.tar.zst`/`.tzst`） | BSD-3-Clause |
| bzip2 | 1.0.8 | bzip2 压缩流（`.tar.bz2`/`.tbz`/`.tbz2`） | bzip2 license |

全部依赖以源码固定版本由 `scripts/fetch-deps.ps1` 下载并校验 SHA256，静态链接进 `coop.exe`；构建、许可文本和测试资产只写入项目内 `.local`。普通归档路径不启动 PowerShell、7z.exe、tar.exe、bzip2.exe 或其他外部解压程序。`tests/archive-lifecycle.ps1` 用 `process_guard` 观察真实 tar.zst 与 7z SFX 安装，工作负载只有 `coop.exe`。

## 覆盖矩阵

| 格式 | 原生读取 | 安装/更新/卸载 | 本轮样本与证据 |
| --- | --- | --- | --- |
| ZIP | 已运行 | 已验证 | Main/ripgrep 14.1.1 → 15.2.0；`extract_dir`、`extract_to`、真实 `rg.exe` 入口、更新保留旧版本、普通卸载；Main/tidy 5.8.0 的嵌套 `extract_dir` 实际运行 |
| tar / tar.gz / tgz | 已运行 | 已验证 | Main/air 1.67.3 → 1.67.4；真实 `air.exe -v`、64bit 与 32bit、arm64 计划选择、Scoop reset |
| tar.xz / txz | 已运行 | 已验证 | Main/curl 8.23.0_5 的官方 release tar.xz；`extract_dir` 版本目录、真实 `curl --version`、Scoop reset；项目内 tar.xz 更新用例 |
| tar.zst / tzst | 已运行 | 已验证 | Main/luajit 2.1.1791988261-1 的 Arch/MSYS2 `.pkg.tar.zst`；嵌套 `extract_dir=mingw64`、真实 `luajit -v`、Scoop reset；坏 tar.zst 更新保留当前版本 |
| tar.bz2 / tbz / tbz2 / tar.lzma / tlz | 已运行 | 路径已验证 | 项目内真实压缩流夹具：嵌套同名目录、`extract_dir` 提升内容、程序运行与卸载；没有挑选 Main/Extras 中同时满足本票边界的真实包，因此不写成真实生态样本 |
| 7z | 已运行 | 已验证 | Main/fastfetch 2.68.1 → 2.70.0 的官方 7z；真实 `fastfetch --version`、更新保留旧版本、Scoop reset；Main/unzip 6.00 的真实 `#/dl.7z` 自解压下载改名为 7z 后安装、运行、Scoop reset 与卸载 |
| MSI | 已运行 | 已验证 | 只读 Windows Installer 数据库（`msi.dll`）+ Windows cabinet 解压 API（`cabinet.dll`）生成与 Scoop `Expand-MsiArchive` 相同的管理镜像；真实 7-Zip 26.05 → 26.03 安装/更新/卸载与损坏失败见 `tests/msi-lifecycle.ps1`，真实共用根 kalker/pkgconf 双向交替见 `tests/real-scoop-msi.ps1`；不启动 `msiexec`、不提权、不重启、不写机器缓存 |
| Inno Setup（`innosetup`） | 已运行 | 已验证 | 通过 root 内已安装的 innounp helper（不内嵌、不下载）按 Scoop `Expand-InnoArchive` 的参数与 `-c` 选择提取声明的 Inno 目录；真实 Units 2.27 → 2.26 安装/更新/卸载、项目内变体的相对 `extract_dir` 与真实 rizin `{app}\bin`、helper 缺失与截断失败见 `tests/inno-lifecycle.ps1`，真实共用根 Main/units 双向交替与逐文件镜像一致见 `tests/real-scoop-inno.ps1`；不启动厂商安装器、不提权、不重启 |
| NSIS / WiX 等其他特殊安装器 | 未启用 | 未启用 | 由 Manifest 诊断或安装器能力拒绝；普通压缩库能力不冒充安装器提取，Inno Setup 的成功也不外推到这些格式 |

`ArchiveKind` 的 ZIP、tar 系列、7z、MSI 与 Inno Setup 路径都进入真实 CLI 生命周期；MSI 使用独立的只读镜像提取后端（见 [Installer/Uninstaller 与特殊安装机制](installer-support.md#msi-管理镜像提取33)），Inno Setup 使用单独安装的 innounp helper（见 [Installer/Uninstaller 与特殊安装机制](installer-support.md#inno-setup-提取34)），两者都不与普通归档共用解压实现。普通 `adopt` 旧路径仍只接受调查过的直接单文件布局；共享归档安装的实际更新/卸载不再依赖该旧路径（见下文）。

## 目录布局语义

固定 Scoop 0.6.0 的 `expand-7zipArchive` 先解开压缩包装，再对内部 tar 应用 `extract_dir`；普通 tar 也应用同一规则。Coop 对 ZIP、7z 和全部 tar 压缩统一使用同一语义：

1. 解压到事务 staging 中的独立树。
2. 若声明 `extract_dir`，把该目录**内容**提升到归档目标目录；目录名本身不保留。嵌套同名目录（例如归档含 `wrap/deep/wrap/deep/bin` 且 `extract_dir=wrap/deep`）因此最终得到 `wrap/deep/bin`，与 Scoop 的 `robocopy /e /move` 结果一致。
3. `extract_to` 只改变该归档产物的目标子目录；多产物按顺序合并，重名文件冲突失败，不覆盖其他包或用户数据。
4. `extract_dir`/`extract_to` 只由归档类下载项按 Manifest 顺序消费，直接文件产物不消费这些字段。

真实样本覆盖了顶层的 `extract_dir`（ripgrep、luajit）、多层嵌套的 `extract_dir`（tidy、curl）、嵌套同名目录（项目内 bzip2/lzma 夹具）以及 `extract_to`（多产物 ZIP）。不存在的 `extract_dir` 会明确失败，不会静默发布空目录。

## 执行与安全边界

1. 计划先显示 `download`、`verify`、`extract`、发布入口等操作；`detail` 与 `artifacts[].algorithm` 保留来源、实际文件名、`#/` 改名和声明算法。预览不下载、不写安装状态。
2. 下载到事务目录，按 Manifest 声明的 SHA256/SHA512/SHA1/MD5 校验；全部产物校验通过并重查计划后才解压。多下载项、`#/` 改名和架构覆盖见[多产物、架构与摘要算法支持](multi-artifact-support.md)。
3. 归档条目只允许普通文件和目录。绝对路径、`..`、盘符、保留名、尾部空格/点、链接条目、设备/FIFO 等特殊类型会被拒绝；已存在的 reparse point 不会被跟随。7z 自解压文件按 7z 容器读取，不执行下载的 PE stub。
4. 解压、布局提升和入口目标检查都在事务 staging 内完成；失败时当前 `current`、入口和管理记录保持原样。提交后删除临时下载；失败事务保留 pending/rolled-back 日志。
5. 更新成功后旧版本目录保留；普通卸载不会删除旧版本目录；`coop cleanup` 在版本记录、摘要和恢复前提均可核对时显式清理非当前旧版本。无脚本包的 `persist` 目录/文件映射另按[持久化数据支持](persistence-support.md)处理；归档内部链接条目仍被拒绝。
6. 条目数量和展开大小有上限；Unicode 条目路径经 UTF-8/宽字符转换后写入项目内测试根。
7. 共享 Scoop 安装没有 Coop 私有记录时，归档布局以标准 `apps/<包>/current`、保存的 Manifest/安装记录、每个声明入口/快捷方式目标存在且可检查的版本树作为事实。Scoop 本身不保存解压树摘要，因此不会伪造“内容摘要相同”；更新只替换 current 与新版本，旧版本保留，卸载只删除已核对的当前版本目录，声明的持久化数据另行处理。命令入口恢复仍按 `.shim`/启动器证据核对。

## 真实样本与校验

测试资产由 `scripts/fetch-deps.ps1` 固定到 `.local/deps/test-archives`：

| 样本 | SHA256 |
| --- | --- |
| ripgrep 14.1.1 x86_64 ZIP | `d0f534024c42afd6cb4d38907c25cd2b249b79bbe6cc1dbee8e3e37c2b6e25a1` |
| ripgrep 15.2.0 x86_64 ZIP | `71b2fef860abe467217a538ff31de02f5258807c0129f771846f87bd029aafc5` |
| air 1.67.3 windows amd64 tar.gz | `150ab78cf4a48f46ca845660b41a913b0bae94572c061ea5dbe75cd745849a5a` |
| air 1.67.4 windows amd64 tar.gz | `c35dbd568cff98055cc382d003bfda06bcdae82389568fb5e60ce5da278fa79d` |
| air 1.67.4 windows 386 tar.gz | `91df7ef7f35da4a23129e172675137e1b8cd6835392736d817bb443c0dc424c8` |
| Node.js 26.12.1 x64 7z | `4deef78146a60555c9518438cae38da8df71722ca856920b90078f5cdeb642a6` |
| luajit 2.1.1791988261-1 MSYS2 tar.zst | `d559881bffc105af4482eab52a34fa57963047cf45e735a5c0f8daca605c68a1` |
| tidy 5.8.0 win64 ZIP（嵌套布局） | `ffb2f86484c66e70e6a6da369cb8f0f459ad2ffec7c7ca80d09a13445ee51a40` |
| curl 8.23.0_5 win64 mingw tar.xz | `b6ad235d1907d96615334532eab1db0040860e6b5adc3b8749a4331924449c3b` |
| unzip 6.00 7z SFX 下载 | `7869ee36346b47701ef01efd0bc2889f970266b66c80b30f74303d50bf7fa33d` |
| 7-Zip 26.05 x64 MSI（安装/更新目标） | `3fe4ab99fa15629c652944309a2b2bc6e41fc933fc6b63f5df1ebcf3aea68263` |
| 7-Zip 26.03 x64 MSI（更新前版本） | `c0680064d698a62dd4a5a47f403db356a6531a5473e4c4b1d090ea2590513926` |

Manifest 版本、URL、hash 与 `extract_dir` 取自真实 Main 修订与本机 Scoop 保存的安装记录；项目内测试只把 URL 改写为 `file://` 缓存（含 Unicode/空格测试根时验证转义路径）。实际程序版本由运行 `rg --version`、`air -v`、`fastfetch --version`、`luajit -v`、`curl --version`、`unzip -v`、`tidy --version` 观察，不由目录存在推断。

## 真机交替与失败保护

2026-10-26 在本机共用根 `C:\Users\Neo\scoop` 顺序执行，Scoop v0.6.0，Main 修订 `89b4cf8078b4968bca637b2ae226b16e8d04dbce`，Windows x64，代码提交见本轮报告。`tests/real-scoop-archives.ps1` 的实际结果：

| 场景 | 覆盖点 | 实际结果 |
| --- | --- | --- |
| ZIP：ripgrep 14.1.1 → 15.2.0 | Coop 安装、Scoop reset、Coop 更新、Scoop 继续、旧版本保留、cleanup/卸载 | 两端运行分别输出 14.1.1 与 15.2.0；`scoop list` 识别 15.2.0；`scoop reset` 后入口仍运行；计划与 journal 操作序列一致 |
| tar.gz：air 1.67.3 → 1.67.4 | Coop 安装/更新、Scoop reset、旧版本保留 | `air -v` 输出 1.67.3 → 1.67.4；Scoop 识别并 reset 后仍运行 |
| 7z：fastfetch 2.68.1 → 2.70.0 | Coop 安装/更新、Scoop reset、旧版本保留 | `fastfetch --version` 输出 2.68.1 → 2.70.0；Scoop 识别并 reset 后仍运行 |
| 共享 tar.gz：Scoop 安装 air 1.67.3，Coop 更新到 1.67.4 | 无私有记录、Scoop→Coop→Scoop、Scoop reset、更新失败保护 | Scoop 安装后 Coop 直接识别并更新；计划和 journal 一致；Scoop 识别 1.67.4 并 reset；损坏的 1.67.5 tar.gz 更新退出 1，journal 在 `download,verify,extract` 后回滚，当前仍运行 1.67.4，目标版本目录未出现 |
| Main/luajit | tar.zst、嵌套 `extract_dir`、Coop 安装、Scoop reset | `luajit -v` 输出 2.1.1791988261；`bin/luajit.exe` 位于正确布局；Scoop 识别并 reset 后仍运行 |
| Main/curl | tar.xz、嵌套 `extract_dir`、Coop 安装、Scoop reset | `curl --version` 输出 8.23.0；`bin/curl.exe` 位于正确布局；Scoop 识别并 reset 后仍运行 |
| Main/unzip | 真实 `#/dl.7z` 自解压下载改名、7z、Coop 安装、Scoop reset | `unzip -v` 输出 UnZip 6.00；Scoop 识别并 reset 后仍运行 |
| Main/tidy | ZIP 嵌套 `extract_dir`、Coop 安装、Scoop reset | `tidy --version` 输出 5.8.0；Scoop 识别并 reset 后仍运行 |

运行前后 Coop 安装清单相同，新增包均已卸载，未修改原 15 个安装。完整命令、退出码和原始日志位于 `.local/pi/tasks/26/evidence/real-scoop-archives/`；汇总为 `real-scoop-archives-evidence.json`。本地夹具另覆盖 bzip2/lzma、坏 tar.zst 更新、坏 ZIP、路径穿越、链接条目、中断和 `extract_to`。

## 测试

- `tests/archive-lifecycle.ps1`（CTest `archive_lifecycle`）：真实 ZIP/tar.gz/tar.xz/tar.zst、嵌套 ZIP、7z SFX、bzip2/lzma、Unicode、多产物 `extract_to`、坏 tar.zst 更新保护；tar.zst 与 7z SFX 安装由 `process_guard` 观察，不能启动外部解压器。
- `tests/archive-safety.ps1`（CTest `archive_safety`）：坏归档、缺失入口、路径穿越、链接/硬链接、损坏 MSI 在数据库阶段失败、中断更新和当前版本保护。
- `tests/msi-lifecycle.ps1`（CTest `msi_lifecycle`）：真实 7-Zip 26.05/26.03 MSI 的只读预览、安装、更新、卸载、持久化保留与截断 MSI 失败；全程 `process_guard` 观察无 `msiexec`，Windows Installer 机器缓存不变。
- `tests/real-scoop-msi.ps1`：真实共用根上 kalker/pkgconf 的 Coop↔Scoop 双向交替与客户端间版本目录逐文件 SHA256 对比。
- `tests/scoop-interop.ps1`（CTest `scoop_interop`）：无 Coop 记录的共享归档更新/卸载、Scoop reset、缺失入口拒绝，以及直接文件/多产物路径。
- `tests/real-scoop-archives.ps1`：上述同一真实 Scoop 根上的顺序交替脚本，只选择未安装的包，失败时尽力卸载本轮安装并删除临时 bucket。

## 未完成与边界

- 本文件只证明这些真实样本与机制路径，不构成 Main/Extras 完整分母、安装器、真实脚本、用户环境或全部入口类型的完成证明。
- MSI 管理镜像提取已启用（#33）；Inno Setup 提取已通过声明的外部 innounp helper 启用（#34），不内嵌也不静默下载该工具。外部 cabinet、多段/partial cabinet、NSIS/WiX 与厂商 EXE 安装器结构仍未启用；分卷/多部分归档（`.001`、`.partN.rar`）、rar/cab/nupkg 等未作为普通归档生命周期启用。`installer.file/args` 不是归档机制，已由 R11（#32）作为独立安装器程序接入，见[Installer/Uninstaller 与特殊安装机制](installer-support.md)。
- 共享归档的更新/卸载以标准布局和入口目标为事实；Scoop 不提供解压树摘要，因此用户对版本目录内部的任意修改不会像直接文件摘要那样被逐一发现。需要内容摘要的场景仍应使用可核对产物的包，或后续在卸载/清理前增加显式树摘要记录。
- `adopt` 专用旧路径仍拒绝归档布局；实际共享更新/卸载走 IR 计划路径，不要求该旧命令。由 #43 统一清理旧路径。
