# 单文件软件的共用交替管理（#24 / R03）

本文件记录 R03 建立的单文件包共用路径：Scoop 安装后由 Coop 更新，以及 Coop 安装后由 Scoop 继续管理，都不要求先执行接管或存在 Coop 私有管理记录。正式规格见 [Issue #21](https://github.com/Coh1e/coop/issues/21)，IR 与执行边界见 [包管理 IR、校验与计划路径](ir-pipeline.md)。

## 事实来源

- 安装身份以 `apps/<包>/current` 指向的版本目录为准；Manifest 与安装记录使用 Scoop 的 `scoop-manifest.json`/`scoop-install.json`（兼容读取旧的 `manifest.json`/`install.json`）。
- 单文件包没有归档布局，安装事实可通过当前 Manifest 声明的单个产物 SHA256 与真实文件核对。
- 命令入口同时识别：
  - Scoop 原生 `<shim>.shim`（`path`/`args`）及 Scoop shim 可执行文件；
  - Coop 旧 `<shim>.coop-shim.json` 及 Coop 启动器。
  - 同一入口出现两种元数据会作为冲突拒绝。
- `.coop/packages/<包>.json` 只作为附加缓存和恢复证据。记录缺失、过期或来自另一客户端时，执行器重新读取共享事实；只有实际入口/产物被外部改写且无法确认归属时才拒绝。

## 执行顺序

`ir::plan` 为安装、更新、卸载生成唯一操作序列；执行器逐条消费 `plan.ir_steps`，并在事务日志写入 `observed_steps`。预览的 `ir_operations`、日志中的 `observed_steps` 与实际发生的入口、版本、记录写入使用同一顺序。空操作计划在执行前被拒绝。

更新保留旧版本；普通卸载只移除当前入口、current 链接与当前版本目录，持久化数据按后续任务继续细化。首个写入前保存事务日志、输入摘要与准备失败回滚边界；`recover` 读取同一日志恢复可确认归属的 Coop 操作，不重跑脚本。

## 命令入口兼容范围

当包没有声明 `env_set`/`env_add_path` 且所有入口都是 EXE/COM 直接启动时，Coop 写入 Scoop 可读的 `<name>.shim` 并复制 Coop 启动器作为 `<name>.exe`。Scoop 的 `reset`/`uninstall` 可以替换或删除这一对文件；Coop 再次更新/卸载时重新识别格式。带环境声明、脚本宿主或 JAR 入口的包仍使用 `.coop-shim.json`，其真正 Scoop 原生入口与用户环境效果由 R07/R08 继续完善。

## 验证

- `tests/scoop-interop.ps1`（CTest 名称 `scoop_interop`）：真实 Scoop 风格的 `.shim`、无 Coop 私有记录的更新/卸载、计划与执行日志逐项对应、Scoop reset 后 Coop 继续识别，以及反向 Coop 安装后由 Scoop 风格入口继续管理。
- `tests/real-scoop-alternating.ps1`：在本机同一 Scoop 根上顺序执行 Scoop 安装 → Coop 更新 → Scoop 运行/识别，再由 Coop 安装 → Scoop reset/运行 → Coop 卸载/识别；下载、入口、版本、标准记录与退出码写入任务证据目录。
- 小样本通过只证明该机制路径，不证明 Main/Extras 全量、所有入口类型、用户环境、安装器或多产物布局已完成。
