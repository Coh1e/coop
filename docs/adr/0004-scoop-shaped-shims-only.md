# shims 目录只放 Scoop 形态的入口文件

2026-10-28 决定：`<根>/shims` 里只写 Scoop 自己会写的文件——直接 EXE/COM 目标的 `<别名>.exe` 启动器与 `<别名>.shim`；BAT/CMD、PS1、JAR 目标只写 `<别名>.cmd`、`.ps1` 与无扩展名 sh 包装，`.py` 与 bash 分支只写 `.cmd`/sh 包装。固定 Scoop 的 `shim()` 只为 `.exe/.com` 目标写 `.shim`（`assets/scoop-lib/core.ps1:963-990`），所以脚本目标一个 `.shim` 也不写。Coop 不再写 `<别名>.coop-shim.json`，也不再为脚本目标复制以 `<别名>.exe` 命名的启动器。

原因是 PATH 解析顺序：`.exe` 先于 `.cmd`。旧设计给 `bin: clink.bat` 这类脚本入口复制了 `<别名>.exe`，用户敲 `clink` 时实际启动的是 Coop 的启动器而不是 Scoop 的 `.cmd`，入口行为、参数转发和退出码都偏离 Scoop；2026-10-27 的真机上 `clink` 因此失效。同时 `.coop-shim.json` 是 `shims` 里的外来文件，Scoop 的 `reset`/`uninstall` 不认识也不会清理它。

牺牲的能力是启动器把声明的 `env_set`/`env_add_path` 注入入口进程。补偿方式：脚本包装在调用目标前用 `set`/`export` 写入声明的环境与 PATH，Scoop 形状的文件名不变；审计字段（包名、启动类型、摘要）回到 `<根>/.coop/packages/<包>.json` 的 `commands` 记录。直接 EXE 入口仍由用户环境（HKCU）提供变量，与 Scoop 一致。

如果 Coop 在完全独立的根里运行（没有 Scoop 参与），保留更丰富的自有元数据是允许的；但一旦同一个根与 Scoop 共用，就回到本决定描述的形态，旧版本留下的 `.coop-shim.json` 与脚本别名启动器在下次发布入口时清理。判定“共用”的依据是根里存在 Scoop 自己的 `apps/scoop/current` 或外来 `.shim` 视图。

回归证据：`ctest --test-dir .local/build --output-on-failure` 45/45 通过，退出码 0，本轮运行；`exposure`、`scoop_interop`、`manifest_shape`、`command_entry_host` 的断言按新契约重写。旧版本安装的迁移（保留 `.coop-shim.json` 或脚本别名启动器时更新/卸载）由计划层的遗留入口清理覆盖，项目内 `scoop_interop` 覆盖“遗留元数据 + 缺失版本树”的重装路径；真实 Scoop 共用根上的旧安装升级与 clink 重装尚未在本轮重跑，属于未运行项。
