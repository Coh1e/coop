# ADR 0006：Coop 私有状态放在 `%USERPROFILE%\.coop`

状态：提议（设计已定稿，实现待完成，见 issue #89）
日期：2026-10-30

## 背景

Coop 需要保存 Scoop 格式里没有的东西：写入期间的事务日志（崩溃恢复）、Coop 创建的入口/快捷方式/环境值/持久化的归属证据、搜索索引、诊断日志。

当前实现把它们全部放在 `<Scoop 根>\.coop` 下。后果：

1. 根的目录里多出一个隐藏目录，Scoop 看不到它，但使用者第一反应是"这是什么脏东西"。
2. 失败运行的事务目录没有保留策略。真实根上曾累积 **25 个目录 / 1341 MB**（含 407 MB 的下载产物）。
3. `Scoop 的根` 与 `Coop 的私有状态` 生命周期不同：根可能被整体移动、复制或备份，状态跟着走没有意义。

Scoop 自己不需要这样的目录，因为它的全部事实都能从根的布局推导（`apps/<包>/<版本>`、`buckets/<名>/.git`），而且它在失败时不恢复。Coop 存在的理由之一正是"失败时能恢复"，那就必须有一个持久、可核对的地方放事务证据。

## 决策（2026-10-30 人类定稿）

**Coop 相关的数据全部放在 `%USERPROFILE%\.coop` 一个目录里**，不使用 LOCALAPPDATA、不使用 `%TEMP%`、不在 Scoop 根里留任何东西、也不引入 XDG 变量。理由：一个位置，用户想清就清、想备份就备份，不需要先理解平台惯例。

```
%USERPROFILE%\.coop\
└── roots\<根目录名>-<根路径 SHA256 前 8 位>\
    ├── buckets.json  packages\  retained\  runs\  logs\  timings\
    ├── cache\index\        ← 纯缓存，可随时删
    └── transactions\       ← 写入期间的事务日志与暂存树
```

每个根一份子目录（根名 + 路径哈希），所以用户级根与测试根互不干扰。`COOP_STATE_DIR` 可把整个目录钉到别处（测试、便携用法）。

### 一个必须处理的后果：跨卷发布

状态目录在 `%USERPROFILE%`（通常在 C:），Scoop 根可能在别的盘。发布是把暂存树 **rename** 进 `apps\<包>\<版本>`，跨卷 rename 会得到 `ERROR_NOT_SAME_DEVICE`。

因此 `publish_new` 在遇到该错误时回退为 **copy + delete**：普通目录递归复制后删源；junction 在目标处重建为链接而不是跟随复制。同卷时仍走 rename（原子、不复制），跨卷时多一次复制。

早年版本（2026-10-30 之前）的三层方案保留在下面的表格里，作为被取代的设计记录：

| 层 | 位置 | 内容 | 生命周期 |
| --- | --- | --- | --- |
| 状态 | `$XDG_STATE_HOME/coop/roots/<根名>-<哈希>`，默认 `~/.local/state/coop/...` | bucket 注册表、包归属记录、保留版本清单、运行记录、日志、计时、清单缓存 | 持久；可从根与 Scoop 记录重建 |
| 缓存 | `$XDG_CACHE_HOME/coop/roots/<根名>-<哈希>`，默认 `~/.cache/coop/...` | 搜索索引、bucket 刷新暂存 | 持久但可随时删除 |
| 进行中 | `<根>\.coop` | 暂存树、事务日志、写锁、测试故障文件 | **只在写操作期间存在** |

三条硬约束决定了这个划分：

1. **发布靠同卷 rename**。暂存树通过 `MoveFileExW` 原子搬到 `apps/<包>/<版本>`；暂存区在另一个卷上会得到 `ERROR_NOT_SAME_DEVICE`（实测：`Destination cannot be published (Windows error 17)`）。所以"进行中"这一层必须在根所在的卷上。
2. **`%TEMP%` 会被清理**。事务日志是崩溃恢复的唯一依据，放进随时可能被 Storage Sense 或清理工具删除的地方等于放弃恢复能力。
3. **提交后的证据仍然有用**。事务日志与脚本 stdout/stderr 是追查"这次更新做了什么"的材料（`publish-contracts`、`msi-lifecycle` 等测试依赖它），所以提交后把**证据**（journal 与日志，不含产物）移到状态层，把**产物**删掉。

## 结果

- 日常状态下 `<Scoop 根>` 里没有 `.coop`：成功或回滚后，事务目录的文件搬去状态层，暂存树删除，空的 `.coop` 一并移除。
- 进程被杀时 `.coop` 留下，`recover` 读它；处理完同样搬走并删除。
- 状态层与缓存层跟随 XDG，与 Scoop 的 `~/.config/scoop/config.json` 同一套习惯；`COOP_STATE_DIR` / `COOP_CACHE_DIR` 作为精确覆盖（测试与便携用法）。
- 首次运行把旧的 `<根>\.coop` 中的持久部分搬到状态层、索引搬到缓存层；迁移失败只报警，不删旧目录。

## 实现要点（三次尝试的结论）

1. `RootLock` 直接用状态目录（`state_directory(root)`），锁文件与事务都落在 `%USERPROFILE%\.coop\roots\<slug>`，根里不再出现 `.coop`。
2. `ordinary_parents` 的 base 必须与路径同层：包记录、保留版本、事务全部用 `state_root(context)`；根内只保留 `apps`、`shims`、`modules`、快捷方式目录。
3. `recovery_path_allowed` 的允许前缀要同时包含根内的 apps/shims 与状态层的 packages/retained，事务仍在根内。
4. 提交路径要把 `transaction` 目录中的 journal 与日志搬到 `state/transactions/<id>` 后再删暂存。
5. 测试用 `COOP_STATE_DIR`/`COOP_CACHE_DIR` 钉在各自沙箱；多根测试（`exposure`、`acceptance`、`path-batch`）要在每个根的命令块前重设环境变量。

## 未采用

- **全部放 `%LOCALAPPDATA%`**：跨卷发布失败，除非把原子 rename 改成 copy+delete（大包慢一倍，且"写一次"的测试与语义都要改）。
- **只把缓存搬走、状态留在根**：根的目录里仍有持久目录，问题只解决一半。
- **只用 `%TEMP%`**：崩溃恢复与证据保留都不可靠。
