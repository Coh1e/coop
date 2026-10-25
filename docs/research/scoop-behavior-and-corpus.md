# Scoop 生命周期、状态与初始兼容样本

日期：2026-10-25。任务：[T01 / #3](https://github.com/Coh1e/coop/issues/3)，父规格 [#2](https://github.com/Coh1e/coop/issues/2)。本轮是固定源码调查、全量 JSON 字段统计和样本采集；未运行 Scoop 安装、Hook、用户迁移或 Coop 生命周期。

## 版本与输入

| 仓库 | 固定修订 | 输入 |
| --- | --- | --- |
| Scoop | `e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f` | 官方 0.6.0 master 源码 |
| Main | `9f7439bdb2a361f4ee6eb19a51c62136a3823ca7` | 1700 份 bucket JSON |
| Extras | `8b42c8c3140ca34ed718704189d97e1da7b3c315` | 2447 份 bucket JSON |

来源为各仓库官方 GitHub 固定修订归档，Main/Extras 修订由本轮官方 branch API 返回。原始归档和解压资料位于被忽略的项目内研究目录。可重运行脚本和输入修订见 [corpus README](../../tests/corpus/README.md)，机器可读结果见 [statistics.json](../../tests/corpus/statistics.json)；样本原文及校验索引见 [index.json](../../tests/corpus/index.json)。Git 专题复用 [此前审计](scoop-git-command-audit.md)，此处不重新发明 Git 子集。

## 全量静态特征

字段在根对象及架构对象中出现即计数，每份 Manifest 每项最多一次；脚本计数排除 checkver/autoupdate，跨所有架构取并集。它不是当前机器实际会执行多少脚本，也不是可安装比例。所有 4147 份 JSON 经 PowerShell `ConvertFrom-Json` 读取，解析错误为 0；这只是该解析器的静态结果。

| 特征 | Main / 1700 | Extras / 2447 |
| --- | ---: | ---: |
| 任一安装/卸载脚本字段 | 271 | 1032 |
| 无选定安装/卸载脚本字段 | 1429 | 1415 |
| pre_install | 177 | 737 |
| post_install | 77 | 241 |
| pre_uninstall | 9 | 94 |
| post_uninstall | 8 | 17 |
| installer.script | 42 | 183 |
| uninstaller.script | 35 | 126 |
| depends | 56 | 67 |
| persist | 160 | 716 |
| bin | 1589 | 1544 |
| shortcuts | 57 | 1987 |
| env_add_path | 91 | 29 |
| env_set | 117 | 46 |
| extract_dir | 486 | 787 |
| extract_to | 7 | 26 |
| 多下载项 | 45 | 57 |
| innosetup | 23 | 126 |
| psmodule | 11 | 17 |

不能将 1429/1415 个无脚本字段包当成原生支持数量：例如 `innosetup` 自身会触发安装辅助工具，且 URL 的 `#/dl.7z` 本地命名影响提取方式。脚本还可动态调用任意程序、访问用户目录、引用 bucket 辅助脚本，因此静态字段统计不能证明行为封闭。

## 安装真实顺序

固定版 [`install_app`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/install.ps1#L8-L82) 的可见顺序是：

1. 解析 Manifest、版本及可用架构，创建具体版本目录，设置原目录和 persist 目录。
2. 下载并校验产物，再执行解压。
3. `pre_install`。
4. `Invoke-Installer`：必要的 installer file/args 进程，随后 `installer.script`。
5. 清理安装器引入的目录 PATH 影响，创建 current，再生成 shim、快捷方式、PowerShell module，设置 PATH 与环境变量。
6. 建立持久化链接及权限。
7. `post_install`。
8. 保存安装时 Manifest 与安装信息，最后输出成功、notes/suggest。

这与“先 pre_install 再解压”或“所有脚本都在 staging 运行”的假设不一致。`$dir` 在 link_current 前为版本目录、之后可能变成 current；`$original_dir` 保持具体版本目录。[Installer 与 Hook 实现](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/install.ps1#L84-L167) 使用 `arch_specific` 取脚本，installer/uninstaller 从 `.script` 取文本，以动态 scriptblock 在当前作用域执行。仅启动一个空 PowerShell 子进程不足以兼容。

## 更新与卸载真实顺序

[更新函数](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/libexec/scoop-update.ps1#L260-L395) 复用安装时架构、bucket/url，判断目标版本并检查运行进程，先下载和校验新产物；随后针对旧 Manifest 运行 pre_uninstall → uninstaller → 移除 shim/current/psmodule/环境 → post_uninstall，最后调用 install_app 安装新版本。旧版本通常仍在，强制同版本安装时改名备份。不能把这个过程描述成普遍原子升级；持久化数据和脚本外部改动可能不可逆。

[独立卸载](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/libexec/scoop-uninstall.ps1#L46-L151) 读取当前版本与保存的 Manifest：pre_uninstall → 运行进程检查 → uninstaller → 移除 shim 和快捷方式 → unlink current → psmodule 和环境清理 → 解除持久化链接并删除该版本目录 → post_uninstall → 清理旧版本。仅带 purge 才删除 persist 存储。注意 post_uninstall 时具体版本文件可能已删除；预卸载 Hook 在运行进程检测之前，不能将它当无副作用检查。

Coop 既要保持已承诺的语义，又应执行父规格的数据保留与恢复规则；若 Scoop 源码的副作用与 Coop 可控恢复存在冲突，需要在相应实现票中明确，不擅自变更 Hook 路径和顺序。

## 状态、架构与链接

**0.6.0 新旧记录名称必须同时考虑。** [`manifest.ps1:123–153`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/manifest.ps1#L123-L153) 写入 `scoop-manifest.json` 与 `scoop-install.json`；读取分别优先新名称，再回退 `manifest.json` 与 `install.json`。安装信息保留 architecture、bucket/url 并去掉空值。只读旧名称会漏掉本轮版本的真实安装记录。

[`arch_specific` 与架构选择](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/manifest.ps1#L156-L185) 对某字段先取架构值，缺失/假值时回退根字段；不是简单覆盖整个根对象。arm64 缺失时根据 Windows build 尝试 x64/x86 回退，此行为须显式验证而不能随意扩平台承诺。

[`link_current/unlink_current`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/install.ps1#L234-L279) 默认 current 为目录 junction，并有 NO_JUNCTION 路径。接管不能强制假定 current 总是目录链接；复杂或不一致布局应诊断。

[`persist_data`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/install.ps1#L428-L518) 支持字符串或 source/target 对：已有目标时保留目标，若软件目录已有内容则改名 `.original`；没有目标但有来源则移动到 persist 存储；两者都无时默认创建目录。目录用 junction，文件用 hardlink。uninstall 前先解除这些链接，避免递归删除 persist 内容。pre_install 可预建文件，post_install 才预建已太晚。

## Shim、环境与依赖

[`shim_def/create_shims`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/install.ps1#L170-L193) 的 bin 项可以指定目标、别名与附加参数。实际 [`shim`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/core.ps1#L949-L1107) 对 EXE/COM 复制小分发程序并写 `.shim` 目标/参数，对 GUI 子系统有处理；BAT/CMD、PS1、JAR 等采用不同转发路径。因此不能把所有 bin 统一实现为复制目标 EXE 或 `.cmd`。

[`env_add_path/env_set`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/install.ps1#L309-L350) 使用声明路径、原安装路径与 persist 等替换，用户/系统范围分开。快捷方式另由 [`shortcuts.ps1`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/shortcuts.ps1#L1-L94) 处理。Coop 必须记录归属及外部修改，不能只在卸载时照字段盲删。

[`Get-Dependency`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/depends.ps1#L1-L77) 合并显式 depends 与安装 helper 需求，先递归依赖、检测循环，再放入包本身；来源可 bucket 限定。helper 检测涉及所选架构 URL、pre/installer/post 脚本中的函数调用、配置及 helper 现状。[辅助工具逻辑](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/depends.ps1#L80-L162) 可能加入 7zip、lessmsi、innounp、dark。Coop 使用原生库替代自身 helper 需求，并不意味着可以删除某个包真正声明或脚本真正需要的依赖。

## 脚本上下文与辅助函数边界

直接可见的上下文来自调用作用域，不是独立的固定 JSON 契约：安装侧 app/manifest/bucket/url、architecture、version、dir、original_dir、persist_dir、global、fname 等；卸载侧另有 cmd 等入口变量，辅助函数可读取其他导入模块状态。[安装作用域](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/install.ps1#L8-L73)、[卸载作用域](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/libexec/scoop-uninstall.ps1#L46-L64)。

样本已显示需要 shim/rm_shim/shimdir、ensure、Get-HelperPath、Invoke-ExternalCommand、Expand-7zipArchive 等函数，也有直接访问 bucketsdir 中配套文件、USERPROFILE、APPDATA、注册表和自定义进程代码。它们必须按真实样本逐项验证，不能声称一个有限 helper 列表证明任意 Hook 兼容。Scoop 的动态执行本身也不保证任意 native exit code 自动变为异常，Coop 需要按已确认规格准确传播失败，并记录可观察的兼容差异。

## 解压能力矩阵：源码行为与 Coop 待验证能力分开

[`Invoke-Extraction`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/decompress.ps1#L3-L61) 根据本地文件名选择机制。下载 [`url_filename`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/download.ps1#L691-L715) 允许 fragment 改写本地文件名，例如 EXE 下载命名 dl.7z；统计不能只看 URL 路径后缀。

| 机制 | Scoop 固定版行为 | Coop 当前状态 |
| --- | --- | --- |
| ZIP | 已有7zip时用其提取，否则 PowerShell Archive | 原生库待验证，未运行 |
| 7z、tar 系列及其他7zip格式 | 调用7zip，压缩tar可能二次提取，extract_dir 有布局处理 | 原生格式覆盖待验证，未运行 |
| MSI | lessmsi 配置路径，或系统 msiexec `/a` 行政提取 | 两者均未验证；不能仅凭通用归档库宣称支持 |
| InnoSetup EXE | innosetup 声明触发 innounp | 必要外部工具或替代机制待验证，未运行 |
| 普通 EXE/COM | 无声明提取机制时保留直接产物 | jq 为最小候选，尚未下载安装运行 |
| WiX/Burn | Hook 调用 Expand-DarkArchive，使用 dark/wix | 特殊外部工具待验证，未运行 |
| NSIS/嵌套安装器 | 可能将 EXE 命名为 dl.7z，并由 pre_install 再提取内部 payload | 仅支持普通7z不足以证明这类行为兼容 |

具体函数依据：[`Expand-7zipArchive`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/decompress.ps1#L63-L145)、[`MSI/Inno/ZIP/Dark`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/decompress.ps1#L169-L342)。extract_dir/extract_to 与下载数组之间不是简单地对所有文件同索引：提取函数以成功识别的可解压项计数，不能跳过这个语义。

## 20 个真实样本与初始验证状态

完整版本、来源、哈希与特征以 [样本索引](../../tests/corpus/index.json) 为准。全部样本目前仅 PowerShell JSON 解析成功；Coop 计划和生命周期均未运行。

| 样本 | 选择理由 |
| --- | --- |
| Main/jq | 无脚本单 EXE、三架构、fragment 重命名，首条原生生命周期候选 |
| Main/ripgrep | ZIP、extract_dir、命令入口 |
| Main/neovim | devkit 真实工具、ZIP 布局与命令入口 |
| Main/cmake | 多命令入口、快捷方式、解压目录 |
| Main/git | 自解压产物、复杂脚本、环境和辅助资源 |
| Main/7zip | x64/x86 MSI 与 arm64 EXE 差异、persist、Hook 和注册表资源 |
| Main/python | installer/uninstaller 脚本、环境与持久化 |
| Main/nodejs | 7z、环境路径、post_install、持久化 |
| Main/wget | 显式 depends、post_install |
| Main/rclone | pre_install、uninstaller.script、配置持久化 |
| Main/android-clt | extract_to、环境、复杂持久化与 pre_uninstall |
| Main/azure-cli | ZIP、环境及 pre/post_uninstall |
| Main/air | tar.gz、三架构、无安装 Hook |
| Main/oh-my-posh | ZIP+EXE 多下载项，只有归档项使用 extract_to |
| Extras/notepadplusplus | pre/post_install、uninstaller、persist 与快捷方式 |
| Extras/vscode | 本地dl.7z、persist、PATH、快捷方式和 bucket 脚本资源 |
| Extras/everything | GUI/命令入口、快捷方式与 pre_uninstall |
| Extras/firefox | EXE 本地归档命名、extract_dir、persist、post_install |
| Extras/adventuregamestudio | InnoSetup 声明，无显式安装脚本但需提取能力 |
| Extras/aider-desk | 架构专属 pre_install、NSIS/嵌套7z、post_uninstall外部删除 |

这些样本刻意包含暂时不安全或不能隔离运行的行为。busybox 可写 USERPROFILE、aider-desk 的 post_uninstall 可删除 APPDATA；研究不执行它们，后续测试不能因为样本来自官方 bucket 就修改真实用户目录。可兼容但本环境无法隔离验证的项应保持未运行，不把安全拒绝当功能已实现。

## 实际命令与未运行项

本轮实际执行：官方归档下载及项目内解压（curl/tar，退出 0）；`tests/corpus/analyze.ps1` 读取全量 JSON 并复制原文（退出 0）；样本 SHA256 与解析/数量检查（见主代理验收结果）。工具运行时为 PowerShell 7.6.5；脚本不执行上游 PowerShell。源码与 Manifest 均有固定修订，样本文件哈希可独立重算。

未运行：任何 Scoop 安装/更新/卸载、真实迁移、软件产物下载/运行、Hook、注册表/用户环境修改、归档库/解压机制构建验证、Coop IR/计划/生命周期测试、性能测试。没有历史运行结果替代本轮证据。

下一步按任务阻塞关系推进：只读查询与预览使用新旧安装记录和真实字段；首条写路径优先 jq；Git、归档与脚本分别通过各票真实行为验证。具体库和复杂布局的可行性仍是实施门槛，不能从本报告推断已经支持。
