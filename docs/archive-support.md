# 普通归档的原生生命周期覆盖

日期：2026-10-25。任务：[T09 / #11](https://github.com/Coh1e/coop/issues/11)，父规格 [#2](https://github.com/Coh1e/coop/issues/2)。本文记录本轮实际启用的归档格式、真实样本、验证方式与仍不适用的机制；不是对整个归档生态的兼容承诺。T14（[#16](https://github.com/Coh1e/coop/issues/16)）追加 7z 生命周期，并记录 MSI 管理安装的隔离限制（未启用）。安装器边界见 [Installer/Uninstaller 与特殊安装机制](installer-support.md)。

## 库与构建

| 依赖 | 固定版本 | 用途 | 许可 |
| --- | --- | --- | --- |
| libarchive | 3.7.7 | ZIP、tar、7z 读取与条目遍历 | BSD-2-Clause |
| zlib | 1.3.1 | ZIP deflate、gzip 压缩流 | zlib |
| xz / liblzma | 5.6.4 | 7z LZMA/LZMA2 与 xz 压缩流 | 0BSD |

三者均以源码固定版本由 `scripts/fetch-deps.ps1` 下载并校验 SHA256，静态链接进 `coop.exe`；构建、许可文本和测试资产只写入项目内 `.local`。普通归档路径不启动 PowerShell、7z.exe、tar.exe 或其他外部解压程序。

## 覆盖矩阵

| 格式 | 原生读取 | 安装/更新/卸载 | 本轮样本与证据 |
| --- | --- | --- | --- |
| ZIP | 已运行 | 已验证 | Main/ripgrep 14.1.1 → 15.2.0 的官方 release ZIP；`extract_dir` 布局、真实 `rg.exe` 入口、更新保留旧版本、普通卸载；计划覆盖 64bit/32bit/arm64 选择 |
| tar.gz | 已运行 | 已验证 | Main/air 1.67.3 → 1.67.4 的官方 release tar.gz；真实 `air.exe -v`、64bit 与 32bit 安装、arm64 计划选择 |
| tar / tar.xz / tgz / txz | 已运行（tar.gz 样本） | 路径开放，未单独验证 | 与 tar.gz 共用 tar 读取路径；没有挑选到同时满足本票边界的真实样本，不把它写成已验证 |
| 7z | 已运行 | 已验证 | Main/nodejs 26.12.1 官方 `node-v26.12.1-win-x64.7z`：真实 `node.exe --version` → `v26.12.1`，`extract_dir` 布局、安装与卸载；不启动外部 7-Zip |
| MSI | 未启用（隔离限制） | 未启用 | 计划检测并按需报告系统 `msiexec.exe`，但 `msiexec /a` 会写入 `%WINDIR%\Installer` 机器缓存，超出项目根；执行前明确阻塞，证据见 [Installer/Uninstaller 与特殊安装机制](installer-support.md) 与验证日志 `.local/pi/tasks/16/verify/06-msi-system-write.log` |
| InnoSetup / NSIS / WiX 等特殊安装器 | 未启用 | 未启用 | 由 Manifest 诊断或安装器/脚本能力拒绝；普通压缩库能力不冒充安装器提取 |

`ArchiveKind` 的 ZIP、tar.gz、7z 路径进入真实 CLI 生命周期；MSI 只在计划中显示外部工具与隔离限制，实际执行阻塞。其他 tar 压缩在 `--dry-run` 中显示产物与拒绝原因，实际执行返回非零。adoption 仍只接受调查过的直接单文件布局，归档安装的原地接管尚未验证。

## 真实样本与校验

测试资产由 `scripts/fetch-deps.ps1` 固定到 `.local/deps/test-archives`：

| 样本 | SHA256 |
| --- | --- |
| ripgrep 14.1.1 x86_64 ZIP | `d0f534024c42afd6cb4d38907c25cd2b249b79bbe6cc1dbee8e3e37c2b6e25a1` |
| ripgrep 15.2.0 x86_64 ZIP | `71b2fef860abe467217a538ff31de02f5258807c0129f771846f87bd029aafc5` |
| air 1.67.3 windows amd64 tar.gz | `150ab78cf4a48f46ca845660b41a913b0bae94572c061ea5dbe75cd745849a5a` |
| air 1.67.4 windows amd64 tar.gz | `c35dbd568cff98055cc382d003bfda06bcdae82389568fb5e60ce5da278fa79d` |
| air 1.67.4 windows 386 tar.gz | `91df7ef7f35da4a23129e172675137e1b8cd6835392736d817bb443c0dc424c8` |
| 7-Zip 26.05 x64 MSI（仅预览/拒绝） | `3fe4ab99fa15629c652944309a2b2bc6e41fc933fc6b63f5df1ebcf3aea68263` |
| Node.js 26.12.1 x64 7z | `4deef78146a60555c9518438cae38da8df71722ca856920b90078f5cdeb642a6` |

Manifest 版本、URL、hash 与 `extract_dir` 取自固定 Main 修订 `9f7439bdb2a361f4ee6eb19a51c62136a3823ca7` 的 ripgrep/air 样本；旧版本 URL 与 hash 来自对应官方 release，测试只把 URL 改写为项目内 `file://` 缓存（含 Unicode/空格测试根时验证转义路径）。实际程序版本由运行 `rg --version`、`air -v` 观察，不由目录存在推断。

## 执行与安全边界

1. 计划先显示 `download`、`verify-sha256`、`extract`、发布入口等操作；预览不下载、不写安装状态。
2. 下载到事务目录，按 Manifest SHA256 校验；全部产物校验通过并重查计划后才解压。
3. 归档条目只允许普通文件和目录。绝对路径、`..`、盘符、保留名、尾部空格/点、链接条目、设备/FIFO 等特殊类型会被拒绝；已存在的 reparse point 不会被跟随。
4. `extract_dir` 按固定版 Scoop 0.6.0 语义只作用于非 tar 归档；`extract_to` 只作用于归档产物。多产物按顺序合并，重名文件冲突失败，不覆盖其他包或用户数据。
5. 解压、`extract_dir` 和入口目标检查都在事务 staging 内完成；失败时当前 `current`、入口和管理记录保持原样。提交后删除临时下载；失败事务保留 pending/rolled-back 日志。
6. 更新成功后旧版本目录保留；入口目标摘要写入 Coop 管理记录，后续更新/卸载前重新校验。普通卸载不会删除旧版本目录，显式清理属于后续票。无脚本包的 `persist` 目录/文件映射另按 [持久化数据支持](persistence-support.md) 验证；归档内部链接条目仍被拒绝。
7. 条目数量和展开大小有上限，避免无限展开；Unicode 条目路径经 UTF-8/宽字符转换后写入项目内测试根。

## 本轮运行状态

- 已运行：真实 ZIP/tar.gz/7z 安装、预览、坏 hash 更新失败、成功更新、旧版本保留、普通卸载、64bit/32bit 入口、arm64 计划、Unicode ZIP、多产物 `extract_to`、坏归档、路径穿越、链接条目、tar.bz2 和缺失 MSI 工具明确拒绝、更新中断保留当前版本；真实 Node.js 7z 产物的安装/卸载；MSI 仅预览/拒绝并测量 Windows Installer 缓存未变化。
- 静态/历史结果：libarchive 3.7.7 对真实 7z 产物的读取探测；不作为自动化生命周期通过数。
- 未运行：所有 MSI 管理安装生命周期（隔离限制阻塞）、`#/dl.7z` 自解压载荷（git/vscode/firefox/aider-desk）、InnoSetup/NSIS 提取、其他厂商 MSI、lessmsi、归档布局的原生接管、tar.xz/tar.bz2/tar.zst 生命周期、真实用户目录安装。

具体命令、退出码与日志位置见对应 Issue 报告和 `.local` 证据目录。
