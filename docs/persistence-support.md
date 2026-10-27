# 持久化数据支持

日期：2026-10-25。状态：T10 实现与运行验证记录，T15 补充彻底删除与旧版本清理，R09 补充真机原地复用验证。范围是当前用户级、无脚本包的生命周期；不把本页当作全部 Scoop 持久化兼容声明。

## 1. Scoop 语义依据

固定 Scoop 修订 `e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f`：

- [`lib/install.ps1` 的 `persist_data`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/install.ps1#L428-L518)：`persist` 可以是字符串或 `source/target` 对；省略 target 时等于 source；数据放在 `$SCOOP\persist\<app>\<target>`。已有 target 时保留 target，若版本目录也有 source 则把 source 改名为 `.original`；没有 target 但有 source 时把 source 移到 store；两者都没有时默认创建目录。目录用 junction，文件用 hardlink。
- [`libexec/scoop-uninstall.ps1`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/libexec/scoop-uninstall.ps1#L46-L151)：卸载当前版本前先解除持久化链接，只有独立 purge 才删除 persist 存储；旧版本目录另行清理。

本项目调查样本中的声明示例：

| 样本 | 声明 | 说明 |
| --- | --- | --- |
| Main/7zip（`26.05`） | `"persist": ["Codecs", "Formats"]` | 两个目录映射；MSI 镜像与 `post_install`/`uninstaller` 已由 #31/#33 接入。真实 7zip 是用户日常工具，本轮不执行其生命周期；等价的真实 MSI + persist 安装/更新/卸载组合由 `tests/msi-lifecycle.ps1` 覆盖 |
| Main/rclone（`1.75.2`） | `"persist": "rclone.conf"` | 单文件映射；同时有 pre_install/uninstaller 脚本，生命周期仍未验证 |
| Extras/vscode（`1.143.1`） | `"persist": "data"` | 目录映射；同时使用 7z、post_install 与卸载脚本，生命周期仍未验证 |

因此首个可执行样本采用无脚本、单 EXE 的测试 Manifest，同时声明一个目录映射和一个文件映射；真实样本继续作为语义与查询对照，不宣称其生命周期已通过。

## 2. 已实现的 Coop 行为

存储位置固定为 `<root>/persist/<package>/<target>`。`source` 与 `target` 必须是无盘符、无 `..` 的包相对路径；重复 source/target 会被诊断为无效 Manifest。

### 共享安装验证

- 只验证、不搬动数据：版本目录中已存在的 junction/hardlink 必须指向声明的 store，目标类型和内容保持原样。该验证对 Scoop 创建的安装与 Coop 创建的安装完全相同，不要求私有记录或接管步骤。
- junction 比较实际 reparse target；hardlink 比较文件卷序列号与文件索引。链接缺失、指向别处、变成普通目录/文件或 store 目标缺失时拒绝更新/卸载，并给出不一致证据。
- 当前 Manifest 与本地更新 Manifest 的 persist 映射必须一致；变化时更新被明确拒绝，避免把未验证的数据迁移写成可管理。
- 管理记录（存在时）保存已验证的 source、target、链接、store、类型和归属证据；`--purge` 的范围同样来自安装自身声明与已核对链接，不以私有记录为前提。

### 安装与更新

- 准备阶段在事务 staging 中建立链接，失败不会改动当前 `current`、入口和管理记录。
- store 已有数据时复用；新版本包内同路径内容改名为 `.original`，不覆盖 store。
- store 缺失时按 Scoop 语义把包内 source 移到 store；两者都没有时创建默认目录。发生迁移后的数据保留在 store，不承诺随后失败的事务自动回滚这部分数据。
- 更新要求 persist 映射与已安装 Manifest 完全一致；映射变化明确拒绝，不静默猜测迁移。成功后旧版本目录继续保留，新版本链接到同一 store。
- 更新输出分别报告 `retained_versions`、`persistence` 和 `data_rollback: none`；保留旧程序不等于恢复数据。

### 普通卸载

- 卸载前重新验证每个声明链接的归属；任何链接被替换、重定向或文件身份变化都会在任何删除前失败。
- 卸载把版本目录移入事务并解除链接，只删除链接本身，不跟随到 store 目标；`persist` 存储、未声明的同包目录和其他用户数据保持不变。
- 当前版本目录、入口和管理记录被移除；旧版本目录按现有 `docs/archive-support.md` 约定保留，显式清理由 `coop cleanup` 负责。
- 卸载成功后把仍存在的旧版本写入 `.coop/retained/<package>.json`，使清理在包已卸载后仍有本机归属证据；没有证据的目录不会被清理。

### 彻底删除

- `coop uninstall <package> --purge` 是独立选项；不发 `--purge` 时行为不变。
- 预览（`--dry-run`）和计划输出列出 `purge.scope`：每个声明映射的 source、target、store、链接、类型和当前文件身份；不扩展到整个 `persist/<package>` 目录。
- 实际删除前重新验证管理记录中的归属、链接仍指向相同 store、store 仍是普通文件/目录且不是 reparse point，并比较写入计划时的文件身份；任一变化都在删除程序和持久化数据前失败。
- 删除只针对声明 store：目录递归删除时遇到 junction/reparse point 只解除链接，不跟随到范围外内容；文件 hardlink 只删除 store 中的链接。未声明的同包目录和其他用户数据保留。
- 删除结果分别报告 `deleted`、`already_absent` 和 `failed`；部分失败返回非零并保留准确范围，不宣称数据已全部删除。

### 旧版本清理

- `coop cleanup [package...] [--dry-run]` 只处理管理记录或卸载保留证据中登记、Manifest 与安装记录摘要未变、不是当前版本且没有 pending 事务依赖的本地版本目录。
- 未记录的目录、缺失历史 Manifest、Manifest/安装记录被修改、版本目录本身是 reparse point 或正在使用的版本全部保留并报告 `unmanageable`/`in-use`/`recovery-protected`；不猜测缺失 Manifest 或下载 URL。
- 清理先把候选目录移动到清理事务，再删除；移动失败不删除任何内容。中断的清理事务在下一次清理时先恢复，仍被占用的目录放回原位。当前版本永不进入候选。
- Scoop 会对持久化目录 junction 设置链接级只读属性（`attrib +R /L`），归档内的文件也可能是只读。清理和解链前先清除该属性，再只解除链接；否则 Scoop 创建、Coop 保留的旧版本目录会被误判为占用（R09 真机复现并修复，回归见 `tests/cleanup.ps1` 与 `tests/persist.ps1`）。

### 冲突与恢复

- store 路径中的 reparse point、版本目录中已有的真实 source 冲突、链接创建/权限失败都明确失败，不静默覆盖。
- 更新或卸载的写阶段失败沿用事务日志恢复已移动的当前版本、入口和记录；失败后 store 数据保持不变，新版本 staging 链接被删除。
- 中断后的 pending 事务仍阻止后续写入；`coop recover` 按日志分类并还原 Coop 自有路径，不重跑脚本。通用安装/发布阶段恢复由 `tests/recovery.ps1` 与 `tests/lifecycle-interrupt.ps1` 验证，本票的 persist 路径额外验证写阶段失败回滚。

## 3. 验证结果

`tests/persist.ps1`（CTest `persistence`）在项目内隔离根目录运行真实 CLI：

| 场景 | 观察结果 |
| --- | --- |
| 共享安装验证 | 原始目录 junction 与文件 hardlink、程序输出、store 内容和未声明目录均不变；预览不写 `.coop`，也不要求私有记录 |
| 共享更新 | 程序与链接保持原声明关系；更新发布新版本并从共享事实核对两条归属；不复制/移动数据 |
| 更新前读取 | 修改 store 后，旧版本程序实际读到新内容 |
| 写阶段失败 | 锁定管理记录使发布失败；旧程序、入口、链接和 store 内容保持；新版本目录不存在 |
| 成功更新 | 真实程序输出注入的 store 内容；旧版本仍可运行并读取同一数据；输出分开报告旧版本与数据 |
| 映射变化 | 更新被明确拒绝，无新版本或数据改动 |
| 链接归属变化 | junction 被重定向、hardlink 被替换时卸载失败；无关目录与 store 数据未被删除 |
| 普通卸载 | 当前版本、入口和记录移除；旧版本、目录链接、文件链接、声明数据和未声明目录保留；旧版本写入 retained 证据 |
| 显式彻底删除 | 预览准确列出两个声明 store；链接被重定向时执行前失败；删除后声明 store 移除，未声明目录和 store 内 junction 指向的外部内容保留 |
| 旧版本清理 | 更新后的旧版本可查询为 cleanable；被修改、pending 事务保护、正在使用或未记录的目录不被删除；清理只删除非当前旧版本；移除 current 后记录的当前版本被阻止清理；模拟中断的 cleanup journal 由下一次清理完成 |
| 新安装 | 缺失 target 时创建默认目录；写入数据后更新复用同一 store；卸载保留数据 |
| 恶意路径 | store 路径含 junction 时安装在发布前失败，外部目录无写入，事务记录 rolled-back |

未运行项：

- 有脚本、快捷方式、环境变量与 persist 的单包组合仍未运行；7z + persist + `post_install` 由 #31 hooks 测试覆盖，MSI + persist 的安装/更新/卸载由 #33 `tests/msi-lifecycle.ps1` 覆盖，已安装依赖与 persist 的组合见依赖生命周期测试。
- 真实 Main/7zip、Main/rclone、Extras/vscode 的完整生命周期（#33 后 MSI 机制与组合已有隔离证据，但真实 7zip 作为用户工具未执行；rclone/vscode 仍由真实根上的单阶段生命周期测试部分覆盖）。
- 权限拒绝、跨卷 hardlink、ReFS 128 位文件 ID、ACL 继承、全局安装 persist 权限。
- 数据迁移后整个事务失败时回滚 store 内容；当前明确不承诺该行为。
- 多个写进程并发操作同一 store 的专项竞态；现有根目录写锁与通用并发测试提供边界，但未单独重复持久化场景。

## 真机验证（R09 / #30）

`tests/real-scoop-persistence.ps1` 在人类选定的真实共用根（`C:\Users\Neo\scoop`）上顺序执行，只安装运行前不存在的包，结束后核对安装清单与本轮前一致并删除本轮创建的测试 store 与临时 bucket；既有 `persist/frp`、`persist/spotbugs`、`persist/uv` 数据不被改写。本轮实测 Windows 11 工作站、Scoop v0.6.0、main `a97619fec75f0c74bd74e73b0e9138df08687a50`、PowerShell 7.6.5；代码提交见本轮报告与 `versions-final-head.txt`，`coop.exe` 摘要见证据 JSON。

| 场景 | 真实观察 |
| --- | --- |
| 既有目录链接（只读） | 真实 `7zip` 26.05 的 `Codecs`、`Formats` junction 在 `coop list --json` 与本轮升级后的 `update --dry-run` 中报告为既有 store、`data_retained=true`，实际 junction 目标逐项一致；读取前后 store 内容与安装清单不变，未写 `.coop/packages/7zip.json`。R09 当时使用旧 `adopt --dry-run` 读取同一证据，该命令已由 R22 移除；同一验证现在由共享 update 预览与卸载使用 |
| 文件映射：Scoop → Coop 更新 | `scoop install mediamtx@1.21.2` 为文件映射创建 hardlink；测试值写入 store 后，真实 `mediamtx.exe` 通过版本目录链接读到 `coop-r09-store` 并以其为监听地址失败。Coop 更新到 1.21.3 的计划与执行步骤逐项一致，新版本 `mediamtx.yml` 与 store 是同一文件，store 哈希与文件标识不变，`retained_versions=[1.21.2]`、`data_rollback=none`；旧版本仍读同一 store |
| 文件映射：Scoop 继续使用 | `scoop reset mediamtx` 后真实 shim 运行 1.21.3，Coop 仍识别同一安装；`coop uninstall` 返回 `data_retained=true`，旧版本目录保留且链接仍指向 store；`coop cleanup` 删除旧版本目录后 store 不变；Scoop 重装 1.21.2 后新 hardlink 仍指向同一 store 并读到同一测试值 |
| 目录映射：Scoop → Coop 更新 | `scoop install pocketbase@0.40.5` 创建 `pb_data`、`pb_migrations` junction；store 中的迁移文件被真实程序应用并写入 store 内的 `data.db`。Coop 更新到 0.40.6 后两个 junction 仍指向同一 store，迁移文件与 `data.db` 的文件标识不变，新版本运行 `migrate up` 报告 `No new migrations to apply.`，旧版本目录保留 |
| 目录映射：卸载、清理与重装 | `scoop reset pocketbase` 后 shim 运行 0.40.6；`coop uninstall` 保留两个 store 与 `data.db`；`coop cleanup` 删除保留的 0.40.5 目录时不跟随 junction，store 数据仍在；Scoop 重装 0.40.5 后连接同一 `pb_data` 并报告无新迁移 |
| 准备失败保护 | 临时 bucket 包使用项目内 mediamtx 归档：先安装 1.21.2 并把测试值写入 store，再以损坏归档预览/执行更新。更新以 `Unrecognized archive format` 失败，退出非零；当前版本、入口、hardlink 与 store 内容不变，真实程序仍读到同一测试值；journal 为 `rolled-back` 且 `observed_steps=[download,verify,extract]`；随后普通卸载仍 `data_retained=true` |
| 回滚范围 | 成功更新单独报告 `retained_versions` 与 `data_rollback=none`；准备失败只回滚 Coop 已移动/创建的程序、入口和 staging，store 内容不被回滚也不被删除。保留旧程序不等于数据回到旧状态，数据恢复没有自动承诺 |

本轮修复了一个真机问题：Scoop 用 `attrib +R /L` 把持久化 junction 标记为链接级只读，`coop cleanup` 删除保留的 Scoop 旧版本目录时只调 `RemoveDirectoryW`，因此报告 `Cannot unlink managed junction` 并把目录当作 in-use。现在 `src/data.cpp` 的统一 `erase_tree` 在解除链接前清除只读属性，`execute`、`cleanup` 与归档 staging 共用同一实现；回归在 `tests/cleanup.ps1`（旧版本 junction）和 `tests/persist.ps1`（卸载当前版本链接）中，红/绿记录见 `.local/pi/tasks/30/evidence/`。

本轮运行的完整命令、退出码、计划、journal 与场景 JSON 保存在 `.local/pi/tasks/30/evidence/real-persistence-final/`（最终 head 运行）；中间修复运行不作为证据。

未在真机运行或未承诺：

- 文件映射样本使用 `mediamtx`；`frp` 的 `frps.exe` 在本机被 Defender 判定为 `PUA:Win32/FRProxy` 隔离，因此没有改用该包，也没有修改杀毒设置。既有的 `persist/frp` 数据仍作为历史保留证据只读核对，未被搬动。
- 测试创建的 store 是空的（本轮首次安装），因此“复用既有 store”的完整分支在真机由 Scoop/Coop 交替共享同一 store 证明；更早卸载遗留的 `frp`/`spotbugs`/`uv` store 没有被重新挂载，也没有被修改。
- 脚本、快捷方式、环境变量、MSI/7z 安装器与持久化映射的真实组合；权限拒绝、跨卷 hardlink、ReFS 128 位文件 ID、ACL 继承、全局安装以及并发写同一 store 的竞态仍未运行。#33 后 MSI + persist 的安装/更新/卸载组合已在项目内真实 MSI 产物上覆盖（`tests/msi-lifecycle.ps1`）。
- 数据迁移（persist 映射变化）仍明确拒绝而不是自动迁移；其失败回滚范围不在本页承诺内。
