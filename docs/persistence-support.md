# 持久化数据支持

日期：2026-10-25。状态：T10 实现与运行验证记录。范围是当前用户级、无脚本包的生命周期；不把本页当作全部 Scoop 持久化兼容声明。

## 1. Scoop 语义依据

固定 Scoop 修订 `e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f`：

- [`lib/install.ps1` 的 `persist_data`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/install.ps1#L428-L518)：`persist` 可以是字符串或 `source/target` 对；省略 target 时等于 source；数据放在 `$SCOOP\persist\<app>\<target>`。已有 target 时保留 target，若版本目录也有 source 则把 source 改名为 `.original`；没有 target 但有 source 时把 source 移到 store；两者都没有时默认创建目录。目录用 junction，文件用 hardlink。
- [`libexec/scoop-uninstall.ps1`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/libexec/scoop-uninstall.ps1#L46-L151)：卸载当前版本前先解除持久化链接，只有独立 purge 才删除 persist 存储；旧版本目录另行清理。

本项目调查样本中的声明示例：

| 样本 | 声明 | 说明 |
| --- | --- | --- |
| Main/7zip（`26.05`） | `"persist": ["Codecs", "Formats"]` | 两个目录映射；同时需要 MSI/EXE 安装器与脚本，生命周期仍未验证 |
| Main/rclone（`1.75.2`） | `"persist": "rclone.conf"` | 单文件映射；同时有 pre_install/uninstaller 脚本，生命周期仍未验证 |
| Extras/vscode（`1.143.1`） | `"persist": "data"` | 目录映射；同时使用 7z、post_install 与卸载脚本，生命周期仍未验证 |

因此首个可执行样本采用无脚本、单 EXE 的测试 Manifest，同时声明一个目录映射和一个文件映射；真实样本继续作为语义与查询对照，不宣称其生命周期已通过。

## 2. 已实现的 Coop 行为

存储位置固定为 `<root>/persist/<package>/<target>`。`source` 与 `target` 必须是无盘符、无 `..` 的包相对路径；重复 source/target 会被诊断为无效 Manifest。

### 接管

- 只验证、不搬动数据：版本目录中已存在的 junction/hardlink 必须指向声明的 store，目标类型和内容保持原样。
- junction 比较实际 reparse target；hardlink 比较文件卷序列号与文件索引。链接缺失、指向别处、变成普通目录/文件或 store 目标缺失时拒绝接管，并给出不一致证据。
- 当前 Manifest 与本地更新 Manifest 的 persist 映射必须一致；变化时接管资格为 `untested`，避免把未验证的数据迁移写成可管理。
- 管理记录保存已验证的 source、target、链接、store、类型和归属证据；迁移前备份仍只覆盖安装元数据和 Scoop 命令入口，不复制或移动用户数据。

### 安装与更新

- 准备阶段在事务 staging 中建立链接，失败不会改动当前 `current`、入口和管理记录。
- store 已有数据时复用；新版本包内同路径内容改名为 `.original`，不覆盖 store。
- store 缺失时按 Scoop 语义把包内 source 移到 store；两者都没有时创建默认目录。发生迁移后的数据保留在 store，不承诺随后失败的事务自动回滚这部分数据。
- 更新要求 persist 映射与已安装 Manifest 完全一致；映射变化明确拒绝，不静默猜测迁移。成功后旧版本目录继续保留，新版本链接到同一 store。
- 更新输出分别报告 `retained_versions`、`persistence` 和 `data_rollback: none`；保留旧程序不等于恢复数据。

### 普通卸载

- 卸载前重新验证每个声明链接的归属；任何链接被替换、重定向或文件身份变化都会在任何删除前失败。
- 卸载把版本目录移入事务并解除链接，只删除链接本身，不跟随到 store 目标；`persist` 存储、未声明的同包目录和其他用户数据保持不变。
- 当前版本目录、入口和管理记录被移除；旧版本目录按现有 `docs/archive-support.md` 约定保留，显式清理仍属后续票。
- `--purge` 尚未实现，本票只验证普通卸载保留数据。

### 冲突与恢复

- store 路径中的 reparse point、版本目录中已有的真实 source 冲突、链接创建/权限失败都明确失败，不静默覆盖。
- 更新或卸载的写阶段失败沿用事务日志恢复已移动的当前版本、入口和记录；失败后 store 数据保持不变，新版本 staging 链接被删除。
- 中断后的 pending 事务仍阻止后续写入；通用安装/接管中断路径由 `tests/lifecycle-interrupt.ps1` 与 `tests/adopt-interrupt.ps1` 验证，本票的 persist 路径额外验证写阶段失败回滚。

## 3. 验证结果

`tests/persist.ps1`（CTest `persistence`）在项目内隔离根目录运行真实 CLI：

| 场景 | 观察结果 |
| --- | --- |
| 接管前 | 原始目录 junction 与文件 hardlink、程序输出、store 内容和未声明目录均不变；预览不写 `.coop` |
| 原地接管 | 程序与链接保持原路径；管理记录包含两条已验证归属；不复制/移动数据 |
| 更新前读取 | 修改 store 后，旧版本程序实际读到新内容 |
| 写阶段失败 | 锁定管理记录使发布失败；旧程序、入口、链接和 store 内容保持；新版本目录不存在 |
| 成功更新 | 真实程序输出注入的 store 内容；旧版本仍可运行并读取同一数据；输出分开报告旧版本与数据 |
| 映射变化 | 更新被明确拒绝，无新版本或数据改动 |
| 链接归属变化 | junction 被重定向、hardlink 被替换时卸载失败；无关目录与 store 数据未被删除 |
| 普通卸载 | 当前版本、入口和记录移除；旧版本、目录链接、文件链接、声明数据和未声明目录保留 |
| 新安装 | 缺失 target 时创建默认目录；写入数据后更新复用同一 store；卸载保留数据 |
| 恶意路径 | store 路径含 junction 时安装在发布前失败，外部目录无写入，事务记录 rolled-back |

未运行项：

- `--purge`、旧版本显式清理与 persist 的交互。
- 有脚本、依赖、快捷方式、环境变量、7z/MSI/安装器与 persist 的组合。
- 真实 Main/7zip、Main/rclone、Extras/vscode 的完整生命周期（当前仍被脚本/格式能力阻止）。
- 权限拒绝、跨卷 hardlink、ReFS 128 位文件 ID、ACL 继承、全局安装 persist 权限。
- 数据迁移后整个事务失败时回滚 store 内容；当前明确不承诺该行为。
- 多个写进程并发操作同一 store 的专项竞态；现有根目录写锁与通用并发测试提供边界，但未单独重复持久化场景。
