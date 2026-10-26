# 跨命令中断恢复与并发一致性

日期：2026-10-25。状态：实现与定向测试记录；父规格见 [Issue #2](https://github.com/Coh1e/coop/issues/2)。

## 协议边界

- 同一 Coop 根目录的所有写命令（接管、安装、更新、卸载、清理、bucket 变更与恢复）先取得 `.coop/write.lock` 的独占句柄；另一个写进程得到非零退出，而不是等待或并发写入。查询命令不打开写锁，也不修改状态。
- 每个包操作在第一次改动前写入 pending 事务日志；日志使用临时文件加 `MoveFileEx` 替换。下载、校验、解压、入口/链接、脚本、数据删除和管理记录提交都记录在日志中，跨文件提交不声称一次 rename 就是原子事务。
- 失败时进程内先按日志回滚 Coop 自有路径；无法确认回滚条件时保留 pending 日志。进程被终止后，下一次命令从日志读取事实，不以“进程已退出”推断成功。
- 查询只读取已发布记录与日志：pending 操作不会显示为 `succeeded`；更新/卸载已把旧管理记录移入事务时，`list` 读取该最后提交记录，不把新 `current` 或半发布入口当作安装事实；尚未发布管理记录的安装也会出现在 `list` 中，状态为 `pending-recovery`，并携带 `recovery` 分类。
- 当前包/旧版本在准备阶段失败时保持原 `current`、入口和管理记录；恢复只改动日志确认属于 Coop 的创建项与移动项。

## 恢复命令

`coop recover [包名...] [--dry-run] [--json]`

- 只处理 `state=pending` 的事务。包名是执行范围：只对指定包执行自动恢复；未指定的 pending 事务保持字节和文件状态不变，以 `requested=false`、`skipped=true` 出现在报告中。指定包没有 pending 事务时报告 `status=not-pending`，不执行任何恢复。`--dry-run` 不写日志、不移动文件，只报告分类和逐项动作。
- `automatic`：日志中的创建项均有 Coop 所有权证据，移动项可安全还原；恢复按创建项逆序删除、移动项逆序移回，然后把日志标为 `rolled-back`。接管事务按已发布管理记录标记 `committed` 或保留备份标为 `rolled-back`；清理事务继续幂等完成，仍被占用的版本放回原位。
- `manual`：日志损坏、创建项所有权未确认、移动的两端同时存在/同时缺失、路径越界或跨 reparse point 时不做任何自动删除或移动，保持 pending 并返回非零。人工核对并消除冲突后可再次运行同一命令。
- 脚本事务不会重跑脚本。脚本记录（阶段、退出码、日志路径）保留在日志中，整个事务目录（含 stdout/stderr 日志）作为恢复证据保留，不按普通缓存删除；自动恢复的结果为 `recovered-with-unknown-script-effects`，并明确声明 Coop 管理路径之外的外部副作用未知且未回滚。
- 批量恢复逐事务报告；只要仍有 pending 事务（未指定而跳过、需要人工处理或恢复失败）或指定包没有 pending 事务，总体退出码就为非零，不声称全局成功。

## 故障矩阵与本轮验证

| 故障点 | 验收行为 | 测试 |
| --- | --- | --- |
| 下载中断 | 旧版本/旧快照仍可用；pending 可见；冲突写入被拒；`recover` 后原操作可重试 | `tests/recovery.ps1`（实际终止更新/安装进程）、`tests/lifecycle-interrupt.ps1` |
| 校验/解压失败 | 当前版本保持，失败事务回滚，不发布成功 | `tests/update.ps1`、`tests/archive-safety.ps1` |
| 链接/入口/记录提交冲突 | 已有外部内容不被覆盖，失败事务日志准确 | `tests/lifecycle-race.ps1`、`tests/exposure.ps1`、`tests/update.ps1` |
| 脚本失败/中断 | 退出码与输出可查，不自动重试；恢复不重跑脚本 | `tests/hooks.ps1`、`tests/installers.ps1`、`tests/recovery.ps1` |
| 数据删除失败/中断 | 不跟随链接、不误删未声明内容，中断清理可完成 | `tests/cleanup.ps1` |
| bucket 同步中断/失败 | 共用工作树保留旧修订或进行中标记；旧注册表/查询状态保持，重试可完成；checkout 中途强杀不自动猜测覆盖 | `tests/bucket.ps1`、`tests/git-clone-interrupt.ps1` |
| 多进程写 | 第二写进程非零退出，状态不变；读取不被写锁阻塞 | `tests/recovery.ps1`、`tests/bucket.ps1` |
| 发布阶段 rollback | 新 current/版本/入口被删除，旧 current/入口/记录移回，旧程序可运行 | `tests/recovery.ps1`（实际协议状态夹具） |

`tests/recovery.ps1` 中的下载中断与并发写入使用真实 Coop 进程和受控 HTTP 端点；发布阶段用例按真实事务协议重放 current/入口/记录的移动并写入日志，再通过 CLI 恢复，因此验证的是恢复协议本身，而不是再次制造进程调度竞态。人工处理用例使用真实外部目录冲突，确认未自动删除后移除冲突并重试成功。

## 未声称事项

- 不恢复任意脚本造成的外部注册表、服务、用户目录或第三方数据修改；`recovered-with-unknown-script-effects` 只表示 Coop 管理路径已还原。
- 不把旧程序切换等同于持久化数据回滚；恢复不删除持久化 store。
- 不自动重跑失败或结果不确定的脚本，不强制结束占用文件的用户程序。
- 未运行真实用户 Scoop 迁移、系统级安装写入或真实安装器外部工具；这些仍受既有票据与规格限制。
