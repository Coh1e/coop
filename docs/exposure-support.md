# 复杂命令入口、快捷方式与环境暴露

本页记录 Coop 对 Manifest `bin`、`shortcuts`、`env_add_path`、`env_set` 的实际支持范围、归属规则、隔离与真机验证方式和未验证项。行为依据固定提交 `e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f` 的 [`shim`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/core.ps1#L949-L1107)、[`create_shims`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/install.ps1#L170-L193)、[`env_add_path/env_set`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/install.ps1#L309-L350) 与 [`shortcuts.ps1`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/shortcuts.ps1#L1-L94)，并以项目内真实程序和本机共用 Scoop 根的真机操作验证，不把解析 Manifest 等同于完整兼容。

## 命令入口

`bin` 支持字符串或数组，每项可声明目标、别名和附加参数：`["目标","别名","附加参数"]`。附加参数排在调用者参数之前转发，与 Scoop 一致。入口类型按目标文件决定，不使用一个 `.cmd` 包装所有场景：

| 目标 | 启动方式 | 参数与退出码 |
| --- | --- | --- |
| `.exe` / `.com` | 直接 `CreateProcessW` | 转发附加参数与调用者参数，返回目标退出码 |
| `.bat` / `.cmd` | `%ComSpec% /d /s /c` | 返回脚本退出码 |
| `.ps1` | `pwsh.exe`，否则系统 `powershell.exe`，`-NoProfile -ExecutionPolicy Unrestricted -File` | 返回脚本退出码 |
| `.jar` | `java.exe -jar`，工作目录为 JAR 所在目录；先查 `JAVA_HOME`，再查 `PATH` | 返回 Java 退出码；找不到运行时明确失败 |

- GUI 子系统 EXE 目标的启动器副本会改为 GUI 子系统（与 Scoop 的处理一致），避免控制台窗口；控制台程序仍等待并传播退出码。R07 已用真实 `red-view` GUI 程序启动并观察到 `Red Console` 窗口。
- `bin` 的附加参数在预览、`.shim` 元数据、`.coop-shim.json` 与管理记录中使用与 Scoop 相同的 `$dir`、`$original_dir`、`$persist_dir` 展开值；展开发生在创建入口时，`$dir`/`$original_dir` 指向 `apps/<包>/current`。真实 `touch`（PS1）、`cfr`（JAR）、`lessmsi`（EXE）与 `spotbugs`（BAT）入口验证了参数转发、退出码和调用者/包目录语义。
- 命令目标缺失、别名重复或目标类型不受支持（例如 `.sh`、无扩展名）在计划阶段报告，执行前拒绝，不静默猜测启动方式。
- 入口归属记录在每个包的 `.coop-shim.json`（包名、目标、参数、启动类型、环境）和管理记录的命令摘要中。更新前核对目标、参数、启动类型与文件摘要；外部改动会拒绝更新或卸载。
- 真实 `scoop reset` 会在 Coop 的启动器旁重建 Scoop 自己的 `.cmd`/`.ps1`/无扩展名 sh 包装。预览的 `scoop_entry_wrappers` 只列出内容确实指向 `apps/<包>/` 的包装；执行时重新核对内容后随 `remove-entries` 一起撤销，不删除同名但指向其他包的文件。Scoop 安装的脚本宿主包只有这些包装而没有 `.exe`/`.shim` 时，更新/卸载从同一内容与命令名证据识别；真实 `clink`（BAT）的更新与卸载预览均可执行（本轮未实际更新用户 clink）。接管保留原 Scoop 入口与路径关系；只有原入口是可识别且参数一致的 Scoop shim 才建立归属。更新后新入口指向 `apps/<包>/current`，卸载只撤销已核对摘要的入口。

## 快捷方式

- `shortcuts` 每项声明目标、名称、可选参数和图标。名称允许 `Git\Git Bash` 这类子目录写法，仍必须是包无关的相对名称。
- 快捷方式写入当前用户开始菜单的 `Programs\Scoop Apps`，并保留子目录、参数与图标。写入前检查同名文件冲突，不覆盖外部文件。`shortcuts` 参数与 `bin` 参数一样展开 `$dir`、`$original_dir`、`$persist_dir`；真实 `scoop reset` 重建的同身份快捷方式可按目标、参数、图标重新核对，不因两个客户端写入的 `.lnk` 字节不同而拒绝管理。
- 管理记录保存每个快捷方式的路径与摘要；更新时先核对摘要再移除旧快捷方式，随后创建新版本声明的快捷方式；卸载只移除 Coop 已核对摘要的快捷方式。外部修改过的快捷方式使操作失败并保留原文件，失败的事务日志记录具体 Windows 错误供诊断。若摘要不同但目标、参数与图标仍与声明完全一致（例如另一客户端重建），则按同一归属处理；无法读取或任何启动身份不一致仍拒绝。
- 用户在 Coop 之外删除已拥有的快捷方式时，该快捷方式已经不存在，无需再撤销：更新和卸载会跳过它、在事务日志与结果中记录 `shortcuts_already_absent`，并继续处理其余归属；更新仍会按新 Manifest 重建声明的快捷方式。只有“文件存在但摘要不同”的外部修改才继续被拒绝。
- 预览在更新/卸载时用 `exposure.missing_shortcuts` 列出已经不存在的声明快捷方式。
- 为子目录快捷方式创建的空目录在最后一个归属快捷方式被撤销（提交成功后）被删除；包含其他文件的目录不会被删除。
- 接管时读取已有 Scoop 快捷方式并核对目标与参数，双方都声明图标时再核对图标；缺失、不可读或不一致都标记为 `untested`，不据此建立删除归属。卸载不会删除接管前就存在但未通过核对的快捷方式。

## 环境暴露

- `env_set` 与 `env_add_path` 中的 `$dir`、`$original_dir`、`$persist_dir`、`$version` 按包解析（`%变量%` 也展开），PATH 项解析到 `apps/<包>/current` 下，因此更新切换 current 后仍然正确。
- 安装/更新时，声明的环境值写入当前用户注册表 `HKCU\Environment`，并向所有顶层窗口广播 `WM_SETTINGCHANGE`，参数为 `Environment`。因此新终端、普通进程启动和其他不经过 Coop 启动器的入口读取同一组值，不再只依赖启动器子进程注入；Coop 启动器仍按既有方式把同一组值应用到自身进程，保持快速路径一致。
- `env_add_path` 解析为 `apps/<包>/current` 下的绝对路径并前置于用户 PATH；原有 PATH 项及其顺序保留。注册表值的字符串类型（`REG_SZ`/`REG_EXPAND_SZ`）也按 Scoop 规则保留，含 `%` 的值使用可展开字符串。
- 每个包的 `.coop/packages/<包>.json` 保存 `user_environment` 证据：作用域、每个变量的写入前原始值和类型、Coop 写入值、PATH 的 `previous`/`applied` 及本次新增项、写入/广播结果。更新时只有当前值仍等于 Coop 上次写入值才替换；用户后来修改的值被保留并在 `preserved` 中报告。新 Manifest 不再声明的变量和 PATH 项在同一次更新中撤销。
- 卸载时若当前值仍等于 Coop 写入值，恢复安装前的原始值（原本不存在则删除）；若用户已修改，则保留新值。PATH 只删除 Coop 实际新增且仍存在的项，用户新增项和其余顺序不动。事务失败时使用同一记录做进程内回滚，`journal.json` 保存写入、广播、保留和回滚证据。
- 预览中的 `exposure.environment`、`exposure.path_entries` 与 `exposure.environment_scope` 明确列出将应用的值和作用范围；`exposure.shortcut_directory` 与来源说明快捷方式位置。系统级环境变量和 `HKLM` 不开放，仍只报告必要时需人工处理。

## 真机验证（R07 / #28）

`tests/real-scoop-exposure.ps1` 在人类选定的真实共用根（`C:\Users\Neo\scoop`）上顺序安装、运行、由真实 Scoop `reset`，再由 Coop 卸载以下 Main 包：`lessmsi` 2.12.9、`red-view` 25oct26、`spotbugs` 4.10.5、`touch` 0.2018.07.25、`cfr` 0.152。脚本先确认这些包未安装，结束后核对安装清单与运行前一致；本轮实测 Scoop v0.6.0、main `89b4cf8078b4968bca637b2ae226b16e8d04dbce`、Java 来自 `JAVA_HOME`。

| 场景 | 真实观察 |
| --- | --- |
| 直接 EXE 与工作目录 | `lessmsi.exe` 以调用者目录中的相对 `sample.msi` 列出真实 MSI 文件表，退出码 0；入口是 `<name>.shim`，没有 `.coop-shim.json` |
| GUI 程序 | `red-view` 目标与 Coop 启动器均为 GUI 子系统（PE 头）；通过 Coop 入口启动后真实 `Red Console` 窗口存在，关闭后无残留进程 |
| BAT/CMD 入口 | `spotbugs` 的 `bin\spotbugs.bat` 经 `%ComSpec%` 启动，输出版本 `4.10.5`，退出码 0；快捷方式目标、参数、工作目录与 `bin\spotbugs.ico` 图标均回读一致 |
| PS1 入口 | `touch` 经真实 PowerShell 创建调用者目录中的参数文件 `created-by-ps1.txt`，退出码 0 |
| JAR 入口 | `cfr` 从 JAR 所在目录解析相对类名并反编译真实 class，退出码 0；证明 JAR 工作目录语义 |
| 快捷方式身份 | Unicode 名称 `Less MSIérables` 的目标、空参数、工作目录和记录摘要一致；`Red GUI Console` 同；另一客户端重建但启动身份相同的 `.lnk` 不再因字节不同被拒绝 |
| 真实 Scoop 快捷方式 | `7zip` 的 `7-Zip\...` 子目录与 `git` 的 `Git\Git Bash`/`Git CMD` `--cd-to-home` 参数在卸载预览中与真实 `.lnk` 逐项一致，预览未写入或认领它们 |
| Scoop 安装的 BAT 入口 | 真实已安装 `clink` 只有 `clink.cmd`/sh 包装；`coop update clink --dry-run` 与 `uninstall clink --dry-run` 均 `execution_available=true`，预览列出两个包装，未执行真实写入 |
| Scoop reset 后继续管理 | 五个包逐个 `scoop reset` 后 Coop 仍识别同一版本；Coop 卸载成功，只撤销 Coop 入口、已核对归属的快捷方式和内容指向该包的 Scoop `.cmd`/`.ps1`/sh 包装，不影响其他软件 |

入口/快捷方式参数的 `$dir` 展开在隔离测试 `tests/exposure.ps1` 中用真实 CLI、真实程序与真实 `.lnk` 验证（预览、`.shim`、管理记录与子进程观察一致）；所选真实包没有声明这些变量，因此没有在真实根重复制造该组合。上述真机运行的原始日志与 JSON 保存在 `.local/pi/tasks/28/evidence/real-exposure-head/`（最终 head 运行；中间修复运行不作为证据）。

## 用户环境真机验证（R08 / #29）

`tests/user-environment.ps1`（CTest `user_environment`）在项目内隔离安装根中安装一个边界明确的测试包，但环境读写作用于真实当前用户 `HKCU\Environment` 和真实新终端进程。测试先保存 `Path` 及测试变量快照，`finally` 逐项恢复。

| 步骤 | 真实观察 |
| --- | --- |
| 安装 v1 | 三个 `env_set` 值写入注册表，`env_add_path=bin` 前置于用户 PATH；管理记录保存 `user_environment`；journal 记录四项写入及 `WM_SETTINGCHANGE` 的 `sent=true` |
| 新终端 | 用 `Start-Process -UseNewEnvironment` 启动真实 `cmd.exe`，它从 Windows 用户环境块而非测试父进程继承环境；读到 v1 值和声明的 PATH 项 |
| 用户修改 | 手工把其中一个变量改为 `modified-by-user` 并追加用户自己的 PATH 项 |
| 更新 v2 | 未修改的两个变量替换为 v2，用户修改值保持 `modified-by-user`；用户 PATH 项保留，Coop PATH 项仍存在；journal 的 `preserved` 列出保留原因 |
| 卸载 | Coop 创建的变量被删除，安装前已有变量恢复原值，用户修改值保留；Coop PATH 项消失，用户 PATH 项及原有项保留；journal 的 `environment_reverted.writes` 记录恢复动作 |
| 清理 | 新终端再次观察到上述结果；测试结束后 `Path` 和测试变量回到运行前快照，无 Coop 测试 PATH 项或变量残留 |

本轮运行的完整命令、退出码、终端输出和 journal 摘录保存在 `.local/pi/tasks/29/evidence/`（最终 head 运行）。该验证覆盖真实用户环境与新终端；未安装 Main/Extras 中同时声明环境与快捷方式的真实包。

## 隔离验证

`tests/exposure.ps1`（CTest `exposure`）在项目内隔离根目录运行真实 CLI 和真实程序：

| 场景 | 观察结果 |
| --- | --- |
| 多入口与参数转发 | `.exe`、`.bat/.cmd`、`.ps1`、`.jar` 分别用对应宿主启动，附加参数在调用者参数之前，退出码逐个核对 |
| 参数变量展开 | `bin` 与 `shortcuts` 的 `$dir`/`$original_dir`/`$persist_dir` 在预览、入口与实际转发中展开为 `current`/`persist` 路径 |
| Scoop 包装归属 | 在 Coop 入口旁放置指向本包的 `.cmd`/`.ps1`/sh 包装，预览列出它们；卸载只清这些内容匹配的包装，不删指向其他包的 `.cmd` |
| Scoop 纯包装安装 | 只有 `.cmd`/sh 包装、无 `.exe`/`.shim` 的 BAT 安装可直接更新到新版本并运行新入口，卸载后无残留；更新保留 `origin=scoop` |
| 目标类型选择 | GUI 启动器副本为 GUI 子系统（PE 头可读），控制台入口仍是控制台子系统；不支持的 `.sh` 目标在计划中拒绝 |
| 快捷方式 | 隔离目录中生成真实 `.lnk`，通过 Shell COM 回读目标与参数；卸载后消失；外部同名文件冲突时拒绝安装 |
| 子目录快捷方式 | `Git <tag>\Git Bash` 与 `工具 应用` 子目录名称可创建、回读、更新与卸载；测试覆盖最后一条归属快捷方式撤销后空子目录被清除 |
| 外部删除的快捷方式 | 删除已拥有的 `.lnk` 后，更新仍重建声明快捷方式并返回 `shortcuts_already_absent`；再次删除后卸载成功，事务日志记录同一观察，不再成为无法更新/卸载的死局 |
| 另一客户端重建的快捷方式 | 同目标、参数、图标但字节不同的 `.lnk`（例如 `scoop reset`）被按启动身份接受；不可读或身份不同的仍被拒绝 |
| `.bat` / `.com` | `.bat` 经 `%ComSpec%` 转发参数并返回 0；PE `.com` 目标直接运行并输出预期文本 |
| JAR 缺少运行时 | 移除子进程 `JAVA_HOME` 与 PATH 中的 Java 后，入口明确失败并输出缺少 Java 运行时的诊断 |
| 环境暴露 | 真实子进程读到 `env_set` 值、展开后的 `$persist_dir`/`$version`，PATH 含 `current\bin` 且保留原 PATH；用户环境值随安装写入、更新替换，卸载恢复原值/删除 Coop 创建的变量 |
| 占用与冲突 | 锁定的快捷方式令卸载失败并回滚，安装与入口保持；失败事务日志记录发布错误；外部修改的快捷方式被拒绝且不被覆盖 |
| 失败恢复 | 快捷方式目录不可创建时整个安装回滚，事务日志为 `rolled-back`，外部文件未被改动 |
| 接管 | 多别名带参数的 Scoop shim 与快捷方式被核对后接管；更新后参数与环境仍正确转发；卸载只删除已核对归属的入口与快捷方式 |
| 隔离边界 | 使用 `COOP_PROGRAMS_DIR` 时真实开始菜单未被写入；安装声明的用户环境值使用唯一测试名写入真实 `HKCU\Environment`，测试结束由 `finally` 恢复快照，不遗留测试 PATH 项或变量 |

`COOP_PROGRAMS_DIR` 只作为当前子进程的环境参数传入，用于把真实快捷方式写入项目内目录；它不是持久用户设置，默认行为仍是当前用户开始菜单。

未运行或未承诺：

- 系统级（`HKLM`）环境变量、需要管理员的系统级安装和广播后的 Shell/Explorer 刷新时序没有在本轮实际观察；用户级广播调用结果已记录，新 `cmd.exe` 进程读取真实用户环境块已验证。
- 用户环境与快捷方式组合的真实包安装（例如 Main/Extras 中同时声明 `env_set`、`env_add_path` 和多层快捷方式的包）仍属于后续真实样本覆盖；本轮真实验证使用边界明确的测试包和真实用户环境。
- Coop 在真实根创建**子目录**快捷方式与带参数快捷方式：本轮真机包只提供平铺/无参数声明，子目录与参数创建由 `tests/exposure.ps1` 在隔离根用真实 `.lnk` 验证；真实根只核对 Scoop 已有子目录/参数快捷方式不被误认领。
- 快捷方式图标的像素级效果、开始菜单索引刷新和 Windows Shell 缓存行为。
- `.com` 真实程序入口：本轮只有隔离 PE `.com` 证据；真实根覆盖 EXE、BAT、PS1、JAR 与 GUI。
- 脚本宿主入口仍写 `.coop-shim.json` 与 Coop 启动器；真实 Scoop `reset` 重建的原生 `.cmd`/`.ps1`/sh 包装只在 Coop 卸载时按内容归属清理。Scoop 安装的纯包装入口已可识别、更新与卸载（隔离实际执行 + 真实 `clink` 预览），但 Coop 自身尚未直接生成这些 Scoop 原生包装。
- `.py`、shell 脚本等 Scoop 会转交其他宿主的入口类型；首版明确拒绝而不是猜测。
- 依赖包自身的快捷方式/环境组合仍由本页与依赖页分别说明；`tests/dependencies.ps1` 不覆盖这些组合。
