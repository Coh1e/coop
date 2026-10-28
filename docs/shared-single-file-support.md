# 单文件软件的共用交替管理（#24 / R03）

本文件记录 R03 建立的单文件包共用路径：Scoop 安装后由 Coop 更新，以及 Coop 安装后由 Scoop 继续管理，都不要求先执行接管或存在 Coop 私有管理记录。正式规格见 [Issue #21](https://github.com/Coh1e/coop/issues/21)，IR 与执行边界见 [包管理 IR、校验与计划路径](ir-pipeline.md)。

> **2026-10-28 变更（[ADR-0004](adr/0004-scoop-shaped-shims-only.md)）：** 直接 EXE 入口仍是 `<别名>.exe` + `<别名>.shim`，但现在所有入口都不再写 `.coop-shim.json`；脚本入口改为一律发布 Scoop 形态的包装。下文描述“带环境声明、脚本宿主或 JAR 入口仍使用 `.coop-shim.json`”的段落已被该决定取代。

## 事实来源

- 安装身份以 `apps/<包>/current` 指向的版本目录为准；Manifest 与安装记录使用 Scoop 的 `scoop-manifest.json`/`scoop-install.json`（兼容读取旧的 `manifest.json`/`install.json`）。
- 直接文件包没有归档布局，安装事实可通过当前 Manifest 声明的每个产物及其算法/摘要与真实文件逐个核对；R04 起同一条证据路径可覆盖多个下载项，不再局限于单个文件（真机多产物证据见[多产物、架构与摘要算法支持](multi-artifact-support.md)）。归档包没有解压树摘要，R05 起以标准 `apps/<包>/current` 版本树、保存的 Manifest/安装记录和每个声明入口/快捷方式目标作为共享事实，不再拒绝更新/卸载（见[普通归档的原生生命周期覆盖](archive-support.md)）。
- 命令入口同时识别：
  - Scoop 原生 `<shim>.shim`（`path`/`args`）及 Scoop shim 可执行文件；
  - Coop 旧 `<shim>.coop-shim.json` 及 Coop 启动器。
  - 同一入口出现两种元数据会作为冲突拒绝。
- Scoop shim 可执行文件的身份按共享入口证据判断，不使用固定 SHA256 白名单：`.shim` 的 `path`/`args` 必须指向当前包和参数；启动器可以是 Coop 自身二进制、记录中已观察到的启动器、带有 Scoop shim 程序标记的 PE（GUI shim 与 console shim 只差 PE subsystem），或与同一 root 内另一 `.shim` 共用相同字节的启动器（为未来更换 shim 程序但保留共享复制行为的 Scoop 版本）。明显的外来替换会在预览和执行阶段同时被拒绝（预览把同一验证结果写入 `execution_available` 与 `execution-blocked` 诊断）。`.shim` 读取器由启动器与执行后端共用，只有一个大小/校验策略；共享更新/卸载忽略未知键，不把未来的 Scoop 字段当作无效证据。
- `.coop/packages/<包>.json` 只作为附加缓存和恢复证据。记录缺失、过期或来自另一客户端时，执行器重新读取共享事实；只有实际入口/产物被外部改写且无法确认归属时才拒绝。新建安装记录 `origin=coop`；更新已有的 Scoop 共享安装保留 `origin=scoop`，不把 Coop 创建的安装误标为 Scoop 来源。

## 执行顺序

`ir::plan` 为安装、更新、卸载与回退生成唯一操作序列；执行器逐条消费 `plan.steps`，并在事务日志写入 `observed_steps`。预览的 `ir_operations` 就是同一序列，日志中的 `observed_steps` 与实际发生的入口、版本、记录写入使用同一顺序。空操作计划由计划构建标记为诊断，执行前被拒绝。

更新保留旧版本；普通卸载只移除当前入口、current 链接与当前版本目录，持久化数据按后续任务继续细化。首个写入前保存事务日志、输入摘要与准备失败回滚边界；`recover` 读取同一日志恢复可确认归属的 Coop 操作，不重跑脚本。

## 命令入口兼容范围

当包没有声明 `env_set`/`env_add_path` 且所有入口都是 EXE/COM 直接启动时，Coop 写入 Scoop 可读的 `<name>.shim` 并复制 Coop 启动器作为 `<name>.exe`。Scoop 的 `reset`/`uninstall` 可以替换或删除这一对文件；Coop 再次更新/卸载时重新识别格式。带环境声明、脚本宿主或 JAR 入口的包仍使用 `.coop-shim.json`，R07 已用真实 EXE/BAT/PS1/JAR/GUI 包验证其入口行为、参数、退出码、工作目录和 Scoop `reset` 后的继续管理；Scoop 安装的脚本宿主包只有 `.cmd`/`.ps1`/sh 包装、没有 `.exe`/`.shim` 时，Coop 从内容与命令名识别并可在隔离根实际更新/卸载（真实 `clink` 已核对更新/卸载预览可执行）。Scoop `reset` 重建的原生包装在 Coop 卸载时只按内容指向本包清理。Coop 自身直接生成这些 Scoop 原生脚本包装仍留在后续清理票；持久用户环境已由 R08 交付，真实写入、新终端读取、用户修改保护和卸载恢复证据见[复杂命令入口、快捷方式与环境暴露](exposure-support.md#用户环境真机验证r08-29)。真实入口、快捷方式与 Scoop 交替证据见[复杂命令入口、快捷方式与环境暴露](exposure-support.md#真机验证r07-28)。

## 验证

- `tests/scoop-interop.ps1`（CTest 名称 `scoop_interop`）：真实 Scoop 风格的 `.shim`、无 Coop 私有记录的更新/卸载、计划与执行日志逐项对应、Scoop reset 后 Coop 继续识别、反向 Coop 安装后由 Scoop 风格入口继续管理，以及共享同一启动器字节的无标记回退与外来启动器拒绝。
- `tests/real-scoop-alternating.ps1`：在本机同一 Scoop 根上顺序执行 Scoop 安装 → Coop 更新 → Scoop 运行/识别，再由 Coop 安装 → Scoop reset/运行 → Coop 卸载/识别；下载、入口、版本、标准记录与退出码写入任务证据目录。
- 小样本通过只证明该机制路径，不证明 Main/Extras 全量、所有入口类型、用户环境或安装器已完成。共享归档的更新/卸载已有真实 Scoop→Coop→Scoop 证据，但版本目录内部的任意修改无法像直接文件摘要那样逐一发现；需要内容摘要的场景仍应使用可核对产物的包或后续显式树摘要记录。
