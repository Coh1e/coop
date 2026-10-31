# 首版真实样本兼容与整体验收

> 历史报告：本页记录 T18/#20 当时的原型状态（含脚本子集分类）。#31/R10 已把生命周期脚本改为真实 PowerShell + 固定 Scoop 兼容库执行，脚本文本不再作为可执行性判据；#33/R12 已启用 MSI 只读镜像提取，不再以机器缓存限制阻塞；#34/R13 已启用 Inno Setup 的 `innosetup` 提取（通过 root 内声明的 innounp helper）。当前脚本语义见[生命周期 Hook 与真实 PowerShell](../script-support.md)，当前 MSI 与 Inno Setup 语义见[Installer/Uninstaller 与特殊安装机制](../installer-support.md)，当前固定样本分类由 `tests/acceptance.ps1` 输出；官方 Main／Extras 的完整分母、机制缺口与真机验证数量见 [Main／Extras 全量兼容盘点](../coverage-report.md)。下方分类只作追溯。

日期：2026-10-25。任务：[T18 / #20](https://github.com/Coh1e/coop/issues/20)，父规格 [#2](https://github.com/Coh1e/coop/issues/2)。代码基线为 `7426d346cfc83c1c484e924e71d3b944d2605ff9` 之后的 T18 提交；本轮工具为 Windows 11 x64、Coop 0.1.0、PowerShell 7.6.5、CMake 4.4.4、Ninja 1.13.2。所有安装、更新、卸载和数据测试都在被忽略的 `.local/tests` 项目内根目录执行，不读取或修改真实用户 Scoop 根。

## 结论

- 固定 [20 份真实 Manifest](../../tests/corpus/index.json) 全部保持字节不变并可被 `coop info` 读取；64bit 计划中 7 份可执行、9 份明确不支持、4 份因输入或前置条件被拒绝。数量不代表生态兼容率。
- 本轮实际跑通“原有 Scoop 安装 → 预览 → 原地接管 → 本地查询 → 显式更新 bucket → 更新预览 → 失败拒绝 → 更新 → 批量部分失败 → 卸载”的真实 jq 路径，并验证失败更新保留当前版本、成功更新保留旧版本、卸载保留单独记录的旧版本。
- 真实 `Main/nodejs` 的 7z、`persist`、`env_add_path` 与 `post_install` 安装成功，程序返回 `v26.12.1`；普通卸载保留 `persist/nodejs/bin`、`persist/nodejs/cache` 和测试标记，`uninstall --purge` 预览只列出这两个声明 store。
- 真实 `Main/ripgrep` 与 `Main/air` 的归档生命周期由本轮 `archive_lifecycle` 测试补充验证；`Main/jq`、`Main/nodejs` 由本轮新增 `acceptance` 测试验证。
- 其余 16 份样本的生命周期为“未运行”，其中 9 份计划已明确不支持、4 份已被拒绝、3 份可执行但本轮未下载运行。未运行不等于失败，也不冒充通过。

## 首条验收路径

`tests/acceptance.ps1`（CTest `acceptance`，本轮退出 0）在 `jq` 上执行以下真实路径。安装前使用真实的 jq 1.7.1 程序与原始 Scoop shim，bucket 中先放置同一版本的 Manifest；随后显式发布 jq 1.8.2 与 ripgrep 15.2.0。

| 步骤 | 实际命令 | 退出码 | 观察到的状态 |
| --- | --- | --- | --- |
| 原有安装可运行 | `shims/jq.exe --version` | 0 | `jq-1.7.1`，原程序、Manifest、安装记录与 shim 摘要记录在案 |
| 接管预览（历史） | `coop --root ROOT adopt jq --dry-run --json` | 0 | `eligibility=eligible`，`update/uninstall=supported-path`，程序与入口未变，无管理记录。R22（#43）已移除该命令，同一共享安装现在直接由 `update`/`uninstall` 管理 |
| 原地接管（历史） | `coop --root ROOT adopt jq --json` | 0 | `status=adopted`、`version=1.7.1`；原程序、Manifest、安装记录和命令入口摘要全部不变。R22 后不再需要此步骤 |
| 本地查询 | `coop --root ROOT list --json`、`info main/jq --json` | 0 | `management=managed`、`origin=scoop`、`version=1.7.1`；进程守卫只观察到 Coop 本身。当前实现中 Scoop 创建的安装无私有记录时为 `management=unadopted`，同样可更新/卸载 |
| 显式更新 bucket | `coop --root ROOT bucket update main --json` | 0 | 本地来源刷新后可查询 jq 1.8.2 与 ripgrep 15.2.0；未启动 git.exe 或 PowerShell |
| 更新预览 | `coop --root ROOT update jq --dry-run --json` | 0 | `previous_package.version=1.7.1`，目标 1.8.2，`execution_available=true`，安装状态和入口不变 |
| 拒绝错误输入 | 将 bucket 中 jq 1.8.2 的 SHA256 改为全零后 `coop update jq --json` | 1 | 当前入口仍为 `jq-1.7.1`，没有 `apps/jq/1.8.2`；`list` 报 `last_operation=failed` 且仍为已安装、可查询 |
| 正常更新 | 恢复真实 SHA256 后 `coop update jq --json` | 0 | `status=success`、`version=1.8.2`，入口返回 `jq-1.8.2`，旧 `apps/jq/1.7.1/jq.exe` 返回 `jq-1.7.1` |
| 批量部分失败 | `coop --root ROOT install main/ripgrep ghostpkg --json` | 1 | 两项逐包报告：`main/ripgrep=success`、`ghostpkg=failed`；每包独立事务，失败不回滚已成功的 ripgrep；`rg --version` 返回 `ripgrep 15.2.0` |
| 卸载接管包 | `coop --root ROOT uninstall jq --json` | 0 | 当前入口、`current` 与管理记录删除；旧 `1.7.1` 目录按记录保留，供显式 `cleanup` 处理 |

真实数据保留用 `Main/nodejs` 26.12.1 单独执行：安装退出 0，`post_install` 退出 0，`node_modules/npm/npmrc` 写入项目内 `persist/nodejs/bin` 与 `persist/nodejs/cache`；写入测试标记后，`uninstall --purge --dry-run` 退出 0 且列出两个 store、不删除标记；普通 `uninstall` 退出 0 且 `data_retained=true`，标记和两个持久化目录仍在，`current` 与管理记录删除。

中断恢复不在首条脚本中伪造：本轮 `recovery` 测试用本地 HTTP 协调点在真实更新/安装中杀进程，验证 pending 日志、读取可用、第二写入被拒绝、预览不改状态、自动恢复、旧程序可运行、恢复后可重试。该测试本轮退出 0。

## 20 份固定样本状态

“可执行”只表示计划中的执行能力为真；“已运行”只指本轮真实下载或使用固定真实归档并完成所述生命周期。未运行的项保持未运行。表中 jq/nodejs 以及 ripgrep 的安装/卸载由 `acceptance` 覆盖；ripgrep 更新与 air 生命周期由 `archive_lifecycle` 覆盖。`acceptance-evidence.json` 的 `lifecycle` 字段只记录 acceptance 测试自身实际运行的样本，因此 Main/air 在其中仍为 `not-run`，与本表的“已运行（archive_lifecycle）”并不矛盾。

| 样本 | 版本 | 读取 | 计划（64bit） | 本轮生命周期 | 备注 |
| --- | --- | --- | --- | --- | --- |
| Main/jq | 1.8.2 | 通过 | 可执行（单文件） | 已运行：接管 1.7.1 → 更新 1.8.2 → 卸载 | 首条验收路径；真实 jq 程序与 shim |
| Main/ripgrep | 15.2.0 | 通过 | 可执行（ZIP） | 已运行：批量安装、入口运行、卸载；另由 archive_lifecycle 覆盖更新 | 真实 15.2.0 ZIP |
| Main/neovim | 0.12.6 | 通过 | 可执行（ZIP） | 未运行 | 可执行不等于已验证 |
| Main/cmake | 4.4.4 | 通过 | 可执行（ZIP、快捷方式） | 未运行 | 可执行不等于已验证 |
| Main/git | 2.56.0.3 | 通过 | 已知不支持 | 未运行 | `pre_install`/`post_install`/`uninstaller` 超出脚本子集 |
| Main/7zip | 26.05 | 通过 | 已知不支持 | 未运行 | MSI 机器缓存限制；`post_install`/`uninstaller` 不支持 |
| Main/python | 3.15.1 | 通过 | 已知不支持 | 未运行 | `pre_install`/`post_install`/`installer`/`uninstaller` 不支持 |
| Main/nodejs | 26.12.1 | 通过 | 可执行（7z、persist、post_install） | 已运行：安装、程序版本、持久化、普通卸载保留数据 | 真实 7z 与真实 post_install；无外部 7-Zip |
| Main/wget | 1.25.0 | 通过 | 拒绝 | 未运行 | 依赖 `cacert` 不在本地 bucket；`post_install` 也不在子集 |
| Main/rclone | 1.75.2 | 通过 | 已知不支持 | 未运行 | `pre_install` 不支持；uninstaller.script 子集另有测试 |
| Main/android-clt | 15859902 | 通过 | 已知不支持 | 未运行 | `pre_install`/`post_install`/`pre_uninstall` 不支持 |
| Main/azure-cli | 2.91.0 | 通过 | 已知不支持 | 未运行 | `pre_uninstall`/`post_uninstall` 不支持 |
| Extras/notepadplusplus | 8.9.8.1 | 通过 | 已知不支持 | 未运行 | `uninstaller` 不支持；Hook 文本由 hooks 测试单独覆盖 |
| Extras/vscode | 1.143.1 | 通过 | 已知不支持 | 未运行 | `post_install`/`uninstaller` 不支持 |
| Extras/everything | 1.4.1.1032 | 通过 | 已知不支持 | 未运行 | `pre_install`/`post_install`/`pre_uninstall` 不支持 |
| Extras/firefox | 158.0.1 | 通过 | 拒绝 | 未运行 | 使用 SHA512，当前 IR 只接受 SHA256；`post_install` 也不在子集 |
| Main/air | 1.67.4 | 通过 | 可执行（tar.gz） | 已运行（archive_lifecycle）：安装 1.67.3、更新 1.67.4、旧版本保留、卸载 | 另测 32bit 归档；arm64 未执行 |
| Extras/adventuregamestudio | 3.6.2.22 | 通过 | 拒绝（历史） | 未运行 | 当时 `innosetup` 尚不支持；R13/#34 已启用通过声明的 innounp helper 提取，本样本仍未运行 |
| Extras/aider-desk | 0.88.0 | 通过 | 拒绝 | 未运行 | SHA512；`pre_install`/`post_uninstall` 也不支持 |
| Main/oh-my-posh | 31.9.1 | 通过 | 可执行（ZIP+EXE、extract_to、env_set） | 未运行 | 可执行不等于已验证 |

## 交叉核对

| 要求 | 本轮实际证据 |
| --- | --- |
| 无 Git 前置 | 本轮实际运行 `tests/git-live.ps1`（退出 0）：子进程 PATH 仅含 `System32`，`https://github.com/ScoopInstaller/Main` 克隆成功（`c31ed805...`，882055 字节），刷新保持同一 revision 且仅 113 字节、未重新发布，GitLab HTTPS 克隆成功；进程守卫在克隆/刷新中都只观察到 Coop 一个工作负载。同一测试还验证不可达代理退出 1 且不改已发布状态、自签名证书退出 1。本地查询与本地 bucket 更新同样只记录一个工作负载；`bucket` 测试另覆盖内嵌 libgit2 的分支/固定修订/增量刷新。 |
| 普通包无外部 7-Zip | 真实 nodejs 7z 安装的工作负载只有 `coop.exe` 和声明 `post_install` 所需的 `pwsh.exe`，没有 `7z.exe`/`7za.exe`/`7zr.exe`；`installers` 测试另用不带脚本的真实 7z 产物断言没有外部解压进程。MSI 仍明确阻塞。 |
| 本地查询无 PowerShell | `list`/`info`/`search` 由进程守卫断言只有 Coop 进程；查询不刷新 bucket、不启动脚本。 |
| 数据保留 | 真实 nodejs 普通卸载保留两个声明 store 与标记；`persistence` 测试覆盖链接归属、拒绝重定向和 `--purge` 实际删除。 |
| 依赖保护 | `dependencies` 测试覆盖依赖顺序、已安装依赖跳过、循环/缺失/歧义拒绝、批量逐包结果与反向依赖卸载保护；不自动连带卸载。 |
| 平台范围 | 本轮为 Windows 11 x64；32bit air 真实执行；arm64 只有计划检查，未运行。非 Windows 不支持。 |
| 不触碰真实用户根 | 所有 `--root` 指向 `.local/tests`；未使用真实 Scoop 根，未发布版本，未关闭父规格。 |

## 本轮改动与证据

- 新增 `tests/acceptance.ps1` 与 CTest `acceptance`：逐样本读取/计划分类、真实 jq 首条路径、真实 nodejs 7z/持久化保留；测试根在 `.local/tests/acceptance 中文 space`。
- 固定真实 jq 1.7.1/1.8.2 归档并加入 `scripts/fetch-deps.ps1`；`tests/process_guard.cpp` 增加只对声明 Hook 子进程生效的 `COOP_PROCESS_GUARD_ALLOW_CHILDREN=1` 观测选项。
- 补全 `coop --help` 的 `bucket`/`install`/`update`/`adopt` 与 `--arch`/`--dry-run`，并扩展 `tests/cli.cmake` 校验；修正 `tests/git-live.ps1` 从进程守卫 stderr 读取观测结果，恢复无 git.exe 的 HTTPS/刷新/代理/证书验收。
- 新增本报告；README 增加项目内准备、构建、运行、已知限制与恢复范围；`AGENTS.md` 记录 pi 编码主力与独立验收的默认分工。
- 本轮实际命令：`fetch-deps.ps1` 退出 0；`build.ps1 -Action build` 退出 0；直接 `acceptance.ps1` 退出 0；`ctest` 全量 27/27 退出 0；提交后 acceptance/cli 2/2 退出 0；`git-live.ps1` 退出 0。完整日志、`git-live` 证据与 `acceptance-evidence.json` 在 `.local/pi/tasks/20/evidence`，其中记录代码 SHA256、OS、PowerShell、逐样本计划、首条路径状态和进程观测。

## 未运行与剩余问题

- 未运行 neovim、cmake、oh-my-posh 的真实下载/安装；其计划可执行，但生命周期未验证。
- 未运行 9 份“已知不支持”样本的执行路径（这是有意拒绝），也未运行 4 份被拒绝样本的实际安装。它们的脚本、MSI、InnoSetup 或 SHA512 兼容工作属于后续范围；MSI（#33）与 Inno Setup（#34）机制随后已启用，SHA512 也已支持，但这些样本仍未运行，本报告的分类只代表该轮。
- 未执行 arm64 真实程序、真实用户 Scoop 迁移/回滚、正式发布、私有或 SSH Git 来源、跨工具交替写入。本轮 `git-live` 只验证公开 GitHub/GitLab HTTPS；未做 Main/Extras 全量规模的网络性能测量。
- 该轮 MSI 隔离提取方案、InnoSetup/NSIS 等特殊安装器、系统级注册表/环境写入尚未实现；随后 MSI（#33）、Inno Setup（#34，通过声明的外部 innounp helper）与 NSIS 安装器载荷（#35，通过声明的外部 7-Zip helper）已交付，`installer.file/args` 安装器/卸载器程序已由 R11（#32）接入真实 PowerShell 与固定 Scoop `Invoke-Installer`，但程序自身的项目外副作用不承诺回滚；WiX/Dark 等其余厂商安装器与系统级注册表/环境写入仍未实现。用户级 `env_set`/`env_add_path` 已由 R08 写入并撤销，但完整生态兼容不能由 20 个样本推断。
- 本轮完整命令、退出码和测试根证据保存在 `.local/pi/tasks/20/evidence`（被忽略的本地任务证据），其中 `acceptance-evidence.json` 记录逐样本计划分类、首条路径状态、进程观测与工具版本。可重跑入口是 `ctest --test-dir .local/build --output-on-failure -R '^acceptance$'`。
