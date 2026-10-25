# 复杂命令入口、快捷方式与环境暴露

本页记录 Coop 对 Manifest `bin`、`shortcuts`、`env_add_path`、`env_set` 的实际支持范围、归属规则、隔离验证方式和未验证项。行为依据固定提交 `e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f` 的 [`shim`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/core.ps1#L949-L1107)、[`create_shims`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/install.ps1#L170-L193)、[`env_add_path/env_set`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/install.ps1#L309-L350) 与 [`shortcuts.ps1`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/shortcuts.ps1#L1-L94)，并以项目内真实程序验证，不把解析 Manifest 等同于完整兼容。

## 命令入口

`bin` 支持字符串或数组，每项可声明目标、别名和附加参数：`["目标","别名","附加参数"]`。附加参数排在调用者参数之前转发，与 Scoop 一致。入口类型按目标文件决定，不使用一个 `.cmd` 包装所有场景：

| 目标 | 启动方式 | 参数与退出码 |
| --- | --- | --- |
| `.exe` / `.com` | 直接 `CreateProcessW` | 转发附加参数与调用者参数，返回目标退出码 |
| `.bat` / `.cmd` | `%ComSpec% /d /s /c` | 返回脚本退出码 |
| `.ps1` | `pwsh.exe`，否则系统 `powershell.exe`，`-NoProfile -ExecutionPolicy Unrestricted -File` | 返回脚本退出码 |
| `.jar` | `java.exe -jar`，工作目录为 JAR 所在目录；先查 `JAVA_HOME`，再查 `PATH` | 返回 Java 退出码；找不到运行时明确失败 |

- GUI 子系统 EXE 目标的启动器副本会改为 GUI 子系统（与 Scoop 的处理一致），避免控制台窗口；控制台程序仍等待并传播退出码。
- 命令目标缺失、别名重复或目标类型不受支持（例如 `.sh`、无扩展名）在计划阶段报告，执行前拒绝，不静默猜测启动方式。
- 入口归属记录在每个包的 `.coop-shim.json`（包名、目标、参数、启动类型、环境）和管理记录的命令摘要中。更新前核对目标、参数、启动类型与文件摘要；外部改动会拒绝更新或卸载。
- 接管保留原 Scoop 入口与路径关系；只有原入口是可识别且参数一致的 Scoop shim 才建立归属。更新后新入口指向 `apps/<包>/current`，卸载只撤销已核对摘要的入口。

## 快捷方式

- `shortcuts` 每项声明目标、名称、可选参数和图标。名称允许 `Git\Git Bash` 这类子目录写法，仍必须是包无关的相对名称。
- 快捷方式写入当前用户开始菜单的 `Programs\Scoop Apps`，并保留子目录、参数与图标。写入前检查同名文件冲突，不覆盖外部文件。
- 管理记录保存每个快捷方式的路径与摘要；更新时先核对摘要再移除旧快捷方式，随后创建新版本声明的快捷方式；卸载只移除 Coop 已核对摘要的快捷方式。外部修改过的快捷方式使操作失败并保留原文件。
- 接管时读取已有 Scoop 快捷方式并核对目标与参数，双方都声明图标时再核对图标；缺失、不可读或不一致都标记为 `untested`，不据此建立删除归属。卸载不会删除接管前就存在但未通过核对的快捷方式。

## 环境暴露

- `env_set` 与 `env_add_path` 中的 `$dir`、`$original_dir`、`$persist_dir`、`$version` 按包解析（`%变量%` 也展开），PATH 项解析到 `apps/<包>/current` 下，因此更新切换 current 后仍然正确。
- 声明的环境值和 PATH 项在启动命令入口时应用到该进程及其子进程：`env_set` 设置变量，`env_add_path` 前置于 PATH 并保留原有 PATH。测试使用真实程序读取 `%VAR%` 和 PATH 验证，而不是内存假实现。
- 首版不修改用户或系统环境变量，也不写注册表 `HKCU\Environment`。因此不存在“持久化用户环境”这一外部副作用；卸载撤销入口后，声明环境不再注入，也不会删除外部环境中同名值。接管包的旧用户级环境值保持为外部证据，Coop 不认领、不删除。
- 预览中的 `exposure.environment`、`exposure.path_entries` 与 `exposure.environment_scope` 明确列出将应用的值和作用范围；`exposure.shortcut_directory` 与来源说明快捷方式位置。

## 隔离验证

`tests/exposure.ps1`（CTest `exposure`）在项目内隔离根目录运行真实 CLI 和真实程序：

| 场景 | 观察结果 |
| --- | --- |
| 多入口与参数转发 | `.exe`、`.bat/.cmd`、`.ps1`、`.jar` 分别用对应宿主启动，附加参数在调用者参数之前，退出码逐个核对 |
| 目标类型选择 | GUI 启动器副本为 GUI 子系统（PE 头可读），控制台入口仍是控制台子系统；不支持的 `.sh` 目标在计划中拒绝 |
| 快捷方式 | 隔离目录中生成真实 `.lnk`，通过 Shell COM 回读目标与参数；卸载后消失；外部同名文件冲突时拒绝安装 |
| 环境暴露 | 真实子进程读到 `env_set` 值、展开后的 `$persist_dir`/`$version`，PATH 含 `current\bin` 且保留原 PATH |
| 占用与冲突 | 锁定的快捷方式令卸载失败并回滚，安装与入口保持；外部修改的快捷方式被拒绝且不被覆盖 |
| 失败恢复 | 快捷方式目录不可创建时整个安装回滚，事务日志为 `rolled-back`，外部文件未被改动 |
| 接管 | 多别名带参数的 Scoop shim 与快捷方式被核对后接管；更新后参数与环境仍正确转发；卸载只删除已核对归属的入口与快捷方式 |
| 隔离边界 | 使用 `COOP_PROGRAMS_DIR` 时真实开始菜单未被写入；用户级环境变量保持未设置 |

`COOP_PROGRAMS_DIR` 只作为当前子进程的环境参数传入，用于把真实快捷方式写入项目内目录；它不是持久用户设置，默认行为仍是当前用户开始菜单。

未运行或未承诺：

- 持久化用户/系统环境变量写入与广播（首版刻意不做，无法在项目内隔离验证）。
- 通过开始菜单快捷方式直接启动的程序不经过 Coop 启动器，因此不会获得 `env_set`/`env_add_path`；首版不写用户环境来实现同等效果。
- 真实默认开始菜单路径的写入（测试统一使用 `COOP_PROGRAMS_DIR` 隔离目录）。
- 快捷方式图标的像素级效果、开始菜单索引刷新和 Windows Shell 缓存行为。
- `.py`、shell 脚本等 Scoop 会转交其他宿主的入口类型；首版明确拒绝而不是猜测。
- 依赖包自身的快捷方式/环境组合仍由本页与依赖页分别说明；`tests/dependencies.ps1` 不覆盖这些组合。
