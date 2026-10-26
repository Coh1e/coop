# 直接维护共用 bucket

日期：2026-10-26。任务：[R02 / #23](https://github.com/Coh1e/coop/issues/23)，父规格 [#21](https://github.com/Coh1e/coop/issues/21)。本页记录 Git bucket 在当前实现中的共用工作树契约、已验证行为、真实环境结果和仍未覆盖的边界。产品范围以 #21 为准；本页只描述已经实现并由证据支撑的部分。

## 目标与边界

- Git bucket 不再发布到 Coop 私有快照目录，而是直接使用 Scoop 的 `<根>/buckets/<名称>` Git 工作树。Coop 与 Scoop 先后读取同一 `.git`、分支、修订、辅助脚本和资源。
- 支持公开 HTTPS（不限于 GitHub）、`file://` 和本机盘符路径的 Git 来源；普通本地目录仍作为 `local` bucket 注册并在显式刷新时重建索引。
- 首次刷新由 `bucket add` 完成；`bucket update` 在现有工作树内 fetch、校验并原地前进。已存在但未注册的 Scoop bucket 通过 `bucket update` 原地接管，不搬动或重建 `.git`。
- 不依赖 `git.exe`：clone、fetch、对象读取、树校验和 checkout 均通过 libgit2 完成；测试用 `process_guard` 观察实际进程。`git.exe` 只作为测试夹具作者和独立核对工具，不是 Coop 运行前提。
- 保留完整历史而不是浅克隆，因为 Scoop 自身仍可能在该仓库中查找历史 Manifest；刷新是增量 fetch。

## 首次、有变化、无变化

首次 `bucket add`：

1. 校验来源为公开 HTTPS 或无凭据的本地 Git 来源。
2. 在 `.coop/staging` 下克隆完整仓库，先不写工作树。
3. 解析目标分支/固定 revision，校验树内容后才 checkout；校验通过后整目录移动到 `buckets/<名称>`。
4. 写入来源记录和查询索引，输出 `first_refresh=true`、`refresh_kind=first`、完整 revision、`files_count`、`received_bytes` 与 `synced_at`。

`bucket update`：

1. 从现有 `.git` 读取实际本地分支、跟踪远端和远端分支，而不是假定 `origin` 或默认分支。
2. 未固定 revision 时 fetch 远端分支；固定 revision 时优先使用本地已有对象，缺失才按 commit 获取。
3. 解析目标 commit，校验目标树（拒绝符号链接、子模块、`.git` 条目、大小写冲突和非法路径）。
4. 工作树必须干净；在 fetch 前后各检查一次，避免外部修改被覆盖。
5. 目标与 HEAD 相同：不 checkout、不重建索引，返回 `refresh_kind=unchanged`。目标不同：使旧索引失效，硬切换工作树到目标，更新注册表，重建索引，返回 `refresh_kind=changed`、`previous_revision` 和 `changed_files`。
6. 固定 revision 的 bucket 仍保持正常分支，只把该分支停在固定 commit；后续刷新不会自行前进。

刷新记录字段：

| 字段 | 含义 |
| --- | --- |
| `revision` / `previous_revision` | 当前和目标 commit；无变化时 `previous_revision=null` |
| `changed` / `refresh_kind` | `false/unchanged` 或 `true/first|changed` |
| `first_refresh` / `adopted` | 是否首次克隆；是否原地接管已有 Scoop bucket |
| `changed_files` | 新旧树之间的 Git diff 条目数；无变化为 0 |
| `files_count` | 目标工作树中的文件数 |
| `received_bytes` | libgit2 传输回调统计的对象字节；本地来源不代表网络流量 |
| `synced_at` | 本次成功刷新的 UTC 时间 |
| `path` / `layout` | 共用工作树绝对路径和 `shared-worktree` 布局 |
| `remote` / `branch` / `url` / `fixed_revision` | 实际来源和分支语义 |

## 保留与失败行为

- **本地修改**：刷新前后都以 Git 状态检查工作树；存在已暂存、未暂存或未跟踪文件时拒绝刷新，保留文件、`.git`、HEAD 和已发布记录，不自动 `reset --hard` 或 `clean`。
- **分支与来源**：接管或刷新时保留本地分支名、实际跟踪远端和远端分支；记录中的 `url` 来自实际跟踪远端，而不是另加一个假定来源。
- **失败前可用数据**：目标树在 checkout 前完成内容校验；不支持的符号链接/子模块在写入前拒绝。checkout 失败时尝试切回原 commit；刷新中断在 `.coop/bucket-refresh/<名称>.json` 留下进行中标记，下一次刷新会覆盖该标记，已提交的注册表记录和查询仍可用。
- **索引一致性**：目标 revision 变化前先使旧查询索引失效，提交注册表后再重建。注册表提交失败时查询回退到工作树文件，不把旧索引当作新 revision 的结果；下一次刷新会核对 HEAD 与记录并补齐注册表。
- **并发**：写命令仍由 `.coop/write.lock` 串行化；查询不加写锁。Coop 刷新期间的外部读取可能看到正在 checkout 的短暂窗口，这不在“同时写入”承诺内。
- **失败撤销边界**：若进程在 checkout 中途被强制终止，Coop 不会在下次启动时自动猜测并覆盖工作树；需要在确认无用户新修改后重新刷新或人工核对。网络/校验/目标树校验/注册表提交失败的保留行为与重试由 `tests/bucket.ps1` 覆盖。

## Git 配置隔离

libgit2 不继承用户的凭据 helper、URL 重写或可执行 filter；只从实际 Git 配置复制 `core.autocrlf`、`core.eol`、`core.safecrlf` 三个与工作树内容相关的值到 `.coop/disabled-user-config`。原因是 Scoop 可能用 `core.autocrlf=true` 检出 CRLF 工作树；若 Coop 完全忽略该设置，会把所有文件误判为本地修改，或用 LF 重写同一 bucket，破坏与 Scoop 的交替使用。其他配置仍被隔离。

## 真实环境结果

本机已选定的真实 Scoop 根为 `C:\Users\Neo\scoop`，Scoop v0.6.0，`main` 来源 `https://github.com/ScoopInstaller/Main`，原分支 `master`、原修订 `dfc3b581001b2afb4242acabeec4ccde6528ed6d`。任务授权范围内只刷新了 bucket，没有安装、更新、卸载软件或执行 Manifest 脚本。最终代码提交为 `32e8573`；真实 `main` 无变化重跑和真实 `nerd-fonts` 接管/变化/无变化均在该构建上执行。

| 操作 | 结果 |
| --- | --- |
| `coop --root C:\Users\Neo\scoop bucket update main`（process_guard） | 退出 0；`changed=true`，`refresh_kind=changed`，`dfc3b58…` → `5cb1b7b…`，`changed_files=73`，`received_bytes=128876`；分支仍为 `master`，`.git` 保留，`git status --porcelain` 为空 |
| 同一命令再次运行（最终构建） | 退出 0；`changed=false`，`refresh_kind=unchanged`，revision/path/分支不变，`received_bytes=0`，索引 SHA256 不变，`git status` 为空 |
| `coop --root C:\Users\Neo\scoop bucket update nerd-fonts`（最终构建） | 退出 0；原地接管未注册 bucket，`adopted=true`，`refresh_kind=changed`，`2bcffab…` → `4b36719…`，`changed_files=10`，`received_bytes=6065`，耗时 3320.5ms；分支仍为 `master`，`git status` 为空 |
| 同一 nerd-fonts 命令第二次 | 退出 0；`changed=false`，`refresh_kind=unchanged`，索引 SHA256 不变，耗时 1297.4ms |
| `coop --root C:\Users\Neo\scoop info main/7zip --json` | 退出 0；刷新后仍通过本地索引/工作树解析 Manifest |
| 进程观察 | 两次 bucket 刷新均为 `Observed workload processes: 1`，未启动 `git.exe` 或 PowerShell |

项目内另外用完整 `main` 工作树的副本先验证了相同路径：原修订 `dfc3b58…` → `5cb1b7…`，73 个文件变化，之后无变化刷新 `received_bytes=0`、索引不变，`git status` 为空。换成最终构建后，真实 `main` 的无变化刷新和真实 `nerd-fonts` 的“接管 + 有变化 + 无变化”再次通过。证据在 `.local/pi/tasks/23/evidence/`（被忽略）：`real-scoop-bucket/`（main 第一次变化）、`real-scoop-bucket-main-final/`（main 最终无变化）、`real-scoop-bucket-nerd-fonts/`（最终构建的接管与变化）。

## 复现

```powershell
# 项目内离线夹具：首次、有变化、无变化、固定 revision、本地修改、失败与中断
ctest --test-dir .local/build --output-on-failure -R '^bucket$'

# 真实共用 bucket：只刷新指定 bucket，不安装/更新/卸载软件
pwsh -NoProfile -NonInteractive -File tests/real-scoop-bucket.ps1 `
  -CoopExe .local/build/coop.exe -ScoopRoot C:\Users\Neo\scoop -Bucket main `
  -EvidenceDir .local/pi/tasks/23/evidence/real-scoop-bucket
```

真实 bucket 的远端会继续变化；复现时应重新记录当时的原修订、目标修订、分支和本地状态，不能把本页的 SHA 当作永久值。

## 未覆盖与后续

- 未承诺两个客户端同时写入同一 bucket；Coop 写入内部串行，但不控制外部 Scoop 进程。
- checkout 中途被强制终止时没有自动回滚猜测；只保留进行中标记、旧注册表和/或 Git 对象供人工核对。后续可增加更细的发布协议。
- 固定 revision 仍是 Coop 的来源语义；不延伸到从远端历史查找本机从未安装的包版本。
- 私有/SSH 来源、reparse point bucket、外部创建的同名目录冲突仍明确拒绝或只读处理，不在本票扩展。
- Main/Extras 完整分母、逐包生命周期与真实安装/更新/卸载仍未由本票完成；相关任务保持待办。
