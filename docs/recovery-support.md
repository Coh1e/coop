# 跨机制中断恢复与冲突诊断

日期：2026-10-27。状态：R16（#37）跨机制实现与运行验证记录。协议基础来自 T16（#18），本次覆盖脚本、安装器程序、归档、持久化、入口、用户环境、版本发布与真实 MSI 阶段。父规格见 [Issue #21](https://github.com/Coh1e/coop/issues/21)。

## 1. 协议边界

- 同一 Coop 根目录的所有写命令（接管、安装、更新、卸载、清理、bucket 变更与恢复）先取得 `.coop/write.lock` 的独占句柄；另一个写进程得到非零退出，而不是等待或并发写入。查询命令不打开写锁，也不修改状态。
- 每个包操作在第一次改动前写入 pending 事务日志；日志使用临时文件加 `MoveFileEx` 替换。下载、校验、解压、入口/链接、脚本、安装器程序、用户环境、数据删除和管理记录提交都记录在日志中，跨文件提交不声称一次 rename 就是原子事务。
- 失败时进程内先按日志回滚 Coop 自有路径；无法确认回滚条件时保留 pending 日志。进程被终止后，下一次命令从日志读取事实，不以“进程已退出”推断成功。
- 查询只读取已发布记录、实际安装事实与日志：pending 操作不会显示为 `succeeded`；更新/卸载已把旧管理记录移入事务时，`list` 读取该最后提交记录；`current` 已被移入事务但旧管理记录仍在时，`list` 报告该记录的版本并保留“当前链接缺失”的事实诊断；尚未发布管理记录的安装也会出现在 `list` 中，状态为 `pending-recovery`，并携带 `recovery` 分类。后续 Scoop 操作实际安装了同名包时，`list` 报告实际安装版本（`management` 为 `unadopted`/`none`），同时保留 pending 事务。
- 当前包/旧版本在准备阶段失败时保持原 `current`、入口和管理记录；恢复只改动日志确认属于 Coop 的创建项与移动项。

## 2. 所有权证据与冲突诊断

每个新建对象在创建完成时写入日志 `created[].evidence`：

- `file_identity`：卷序列号 + 文件索引，记录 Coop 创建的那个对象本身；
- 普通文件另有 `sha256`，reparse point 另有 `target`；
- 目录只记录对象身份，因为解压、脚本、安装器与持久化链接会合法改变目录内容。

恢复删除前核对证据。对象已被替换、文件内容被外部修改、链接被重定向时，恢复不删除该对象，返回非零并给出稳定冲突代码：

| 代码 | 含义 |
| --- | --- |
| `created-path-replaced` | 创建路径现在是另一个文件系统对象（例如另一客户端重建了版本目录、`current` 或入口） |
| `created-file-modified` | Coop 创建的文件内容已改变（例如另一客户端重写了 shim） |
| `created-link-repointed` | Coop 创建的链接现在指向别处 |
| `created-path-unreadable` | 记录的创建对象无法打开核对身份 |
| `created-path-outside-root` | 日志路径越过 Coop 管理范围或穿过 reparse point |
| `created-path-ownership-unconfirmed` | `owned` 未确认，拒绝删除 |
| `move-endpoint-conflict` | 日志移动的两端同时存在，恢复会覆盖数据 |
| `move-endpoints-missing` | 日志移动的两端同时缺失（例如另一客户端已删除） |
| `moved-path-outside-root` | 移动路径越过管理范围 |
| `journal-unreadable` | 日志或条目无法读取 |
| `environment-value-modified` | 用户在事务之后改了 Coop 写过的环境值；恢复保留较新值（不阻塞路径回退） |

`recover --dry-run --json` 与 `recover --json` 的每条事务都带 `diagnostics`/`conflicts`；`mode=manual` 的冲突不做任何删除或移动，保持 `state=pending`，人工消除冲突后可用同一命令重试。旧日志没有 `evidence` 时报告 `ownership_evidence=not-recorded`，沿用 `owned` 标志的旧行为，不伪造新证据。

## 3. 用户环境回退

环境操作在写入后立即把 `undo` 记录追加到日志 `environment_undo`。恢复时：

- 先用 `preview_user_environment_undo` 只读报告将恢复的值（`recover --dry-run` 不写注册表）；
- 路径回退完成后按逆序恢复日志记录的 HKCU 值并广播环境变更；
- 当前值仍等于 Coop 写过的值时恢复旧值并报告 `restored`；
- 用户已改为其他值时保留用户值，报告 `preserved`、`environment-value-modified` 与 `recovered-with-user-changes`，不覆盖用户修改。

## 4. 故障注入测试缝（仅工程使用）

确定性阶段失败使用两个开关同时满足才生效的测试缝：

- 当前进程环境含 `COOP_ALLOW_TEST_FAULTS=1`；
- 所选根存在 `.coop/test-faults.json`，内容形如 `{"crash":["after-extract"],"fail":["after-entry"]}`。

`fail` 在指定阶段抛出异常，走产品自身的进程内回滚；`crash` 调用 `TerminateProcess`，不析构、不回滚，留下真实 pending 事务。可用阶段名：`after-version-publish`、`after-extract`、`after-entry`、`after-environment`、`after-persistence`、`after-shortcut`、`after-script:<phase>`、`after-installer`、`before-commit`。无开关、无文件或文件不可读时完全是 no-op；正常用户操作不会创建该文件。该缝只用于在真实执行路径上到达阶段，不能替代真机结果，也不作为发布行为对外承诺。

## 5. 恢复命令

`coop recover [包名...] [--dry-run] [--json]`

- 只处理 `state=pending` 的事务。包名是执行范围：只对指定包执行自动恢复；未指定的 pending 事务保持字节和文件状态不变，以 `requested=false`、`skipped=true` 出现在报告中。指定包没有 pending 事务时报告 `status=not-pending`，不执行任何恢复。`--dry-run` 不写日志、不移动文件、不写注册表，只报告分类、冲突、环境预览和逐项动作。
- `automatic`：日志中的创建项均有可核对的所有权证据，移动项可安全还原；恢复按创建项逆序删除、移动项逆序移回，恢复环境值，然后把日志标为 `rolled-back`。接管事务按已发布管理记录标记 `committed` 或保留备份标为 `rolled-back`；清理事务继续幂等完成，仍被占用的版本放回原位。
- `manual`：存在上表冲突、日志损坏、路径不安全时不做任何自动删除或移动，保持 pending 并返回非零。
- 脚本与安装器程序事务不会重跑。脚本/程序记录（阶段、退出码、日志路径）保留在日志中，整个事务目录（含 stdout/stderr 日志）作为恢复证据保留；自动恢复结果为 `recovered-with-unknown-script-effects`，并明确声明 Coop 管理路径之外的外部副作用未知且未回滚。
- 批量恢复逐事务报告；只要仍有 pending 事务（未指定而跳过、需要人工处理或恢复失败）或指定包没有 pending 事务，总体退出码就为非零，不声称全局成功。

## 6. 跨机制故障矩阵与本轮验证

| 机制/阶段 | 注入方式 | 验收行为 | 测试 |
| --- | --- | --- | --- |
| 版本发布（归档更新） | 真实崩溃 `after-version-publish` | 旧版本目录与记录保护；查询显示最后提交版本与 pending；预览不改状态；恢复删除可确认的创建项、移回旧 `current`/入口；重试成功；持久化 store 不变 | `tests/recovery-matrix.ps1` A |
| 解压（归档 / 真实 MSI / 真实 Inno Setup / 真实 NSIS） | 真实崩溃 `after-extract` | 只留 staging，无发布状态；恢复丢弃准备状态；旧版本继续运行；重试成功；journal 记录 `msi_extractions`/`inno_extractions`/`nsis_extractions` 真实机制证据 | `tests/recovery-matrix.ps1` A、D、E、F |
| 命令入口 | 失败 `after-entry` | 进程内回滚已创建的部分入口/版本/current，其他包入口不受影响 | `tests/recovery-matrix.ps1` B |
| 用户环境 | 崩溃 `after-environment` | 日志含 `environment_undo`；预览只报告将恢复值；恢复旧值；用户后来改值时保留新值并诊断 | `tests/recovery-matrix.ps1` B |
| 持久化 | 崩溃 `after-persistence` / 版本发布崩溃 | 链接随版本目录回退，store 内容不搬动、不回滚 | `tests/recovery-matrix.ps1` A |
| 生命周期 Hook | 崩溃 `after-script:post_install` | 结果 `recovered-with-unknown-script-effects`；事务证据保留；Hook 不重跑（外部标记计数不变） | `tests/recovery-matrix.ps1` C |
| 声明的安装器程序 | 崩溃 `after-installer` / 失败 `after-installer` | 程序不重跑；路径可回滚；外部副作用未知 | `tests/recovery-matrix.ps1` C |
| 创建项被外部替换 | 崩溃后替换版本目录/修改 shim | `created-path-replaced`/`created-file-modified` 人工冲突，不删除外部对象；人工处理后可恢复 | `tests/recovery-matrix.ps1` A、G |
| 下载中断、并发写、发布阶段回退、接管/清理日志、包名范围 | 实际终止进程 / 真实协议夹具 | 旧版本可用、查询可读、第二写者非零、恢复分类与逐项动作正确 | `tests/recovery.ps1`（T16 保留） |
| 真实共用根：更新解压崩溃 → 真实 `scoop reset` → 恢复 → 重试 → `scoop reset` | `after-extract` | 崩溃退出码 `-1073740791`；Scoop 在 pending 期间可正常 reset 并运行 v1；恢复丢弃准备；重试后 v2 可运行；store 不变 | `tests/real-scoop-recovery.ps1` 场景 2 |
| 真实共用根：安装崩溃后 Scoop reset/安装覆盖 | 崩溃 `after-entry` | Coop 重新识别 Scoop 实际安装版本（`unadopted`）；恢复报告 `created-path-replaced` 冲突并保留 Scoop 的 `current` 与入口；Scoop 卸载后恢复只报告 `already-absent`、无删除动作 | `tests/real-scoop-recovery.ps1` 场景 3 |

自动化命令（项目内隔离根，真实 CLI、真实 PowerShell、真实 MSI/Inno/NSIS 产物）：

```powershell
./scripts/build.ps1
ctest --test-dir .local/build --output-on-failure -R '^(recovery|recovery_matrix)$'
```

本轮运行证据：`.local/pi/tasks/37/evidence/ctest-recovery-matrix-13.log`（含真实 MSI/Inno/NSIS 的 `recovery_matrix` 通过）；`.local/pi/tasks/37/evidence/ctest-full-final.log`（37/37 通过）；`.local/pi/tasks/37/evidence/user-env-compare-final.log`（完整测试运行前后 `HKCU\Environment` 无差异）。会话根内 `recovery-matrix-evidence.json` 记录 10 次真实进程崩溃、2 次阶段失败、真实 MSI/Inno/NSIS 产物和所有根路径；本轮最后一次会话 `checks=124`。

真机共用根（本机 Scoop 根 `C:\Users\Neo\scoop`，Scoop v0.6.0，Coop `coop 0.1.0`，二进制 SHA256 `3da498333c65c7f7902c593702dbcbd80a72a8447f456e6924a93416c7b59ca8`）：

```powershell
pwsh -NoProfile -File tests/real-scoop-recovery.ps1 -CoopExe .local/build/coop.exe `
  -EvidenceDir .local/pi/tasks/37/evidence/real-scoop-recovery-run5
```

`commands.json` 记录全部命令、退出码与日志。关键结果：`update-crash`/`install-crash` 退出码 `-1073740791`；`scoop-reset-during`/`scoop-reset-v2` 与 `recover-after-crash` 退出码 0；`recover-conflict` 退出码 1 并报告 `created-path-replaced`；Scoop 卸载后最终恢复 `recovered` 且 `remove` 动作数为 0；操作前后真实根安装清单均为同样的 15 个包。测试创建并清理了临时 bucket、测试包、store、入口与 Hook 标记，根内既有安装、bucket、记录和 store 未改动。

## 7. 未声称事项

- 不恢复任意脚本、安装器程序造成的外部注册表、服务、用户目录或第三方数据修改；`recovered-with-unknown-script-effects` 只表示 Coop 管理路径已还原。
- 不把旧程序切换等同于持久化数据回滚；恢复不删除或搬动持久化 store 与用户数据。
- 不自动重跑失败或结果不确定的脚本/安装器程序，不强制结束占用文件的用户程序。
- 不承诺两客户端同时写入；测试中的 Scoop 操作都在 Coop 进程退出之后进行。
- 系统级安装、系统级环境、远端历史版本和私有/SSH 来源未在本票覆盖。
