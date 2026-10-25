# 生命周期 Hook 与真实脚本兼容

本页记录 Coop 对 Manifest `pre_install`、`installer.script`、`post_install`、`pre_uninstall`、`uninstaller.script` 等生命周期 Hook 的实际支持范围、脚本上下文、执行顺序、失败语义和未验证项。行为依据固定提交 `e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f` 的 [`install_app`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/install.ps1#L8-L82)、[`Invoke-Installer`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/install.ps1#L84-L167)、[`scoop-update`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/libexec/scoop-update.ps1#L260-L395) 与 [`scoop-uninstall`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/libexec/scoop-uninstall.ps1#L46-L151)，脚本原文取自 [固定样本](../tests/corpus/index.json)，不把“能解析 Manifest”当成脚本兼容。

## 支持范围

Coop 只执行样本实际证明的脚本阶段和语句子集，且只对固定样本中出现的上下文与辅助函数负责：

| 项目 | 已启用 | 说明 |
| --- | --- | --- |
| `pre_install` | 是 | 在真实版本目录中、持久化链接建立之前运行 |
| `installer.script` | 部分 | 生命周期阶段已接入；只有落在已证明子集内的文本可执行。固定样本 Main/python 的文本依赖外部工具和子表达式，明确诊断 |
| `post_install` | 是 | 在 `current`、命令入口、快捷方式和持久化链接建立之后运行 |
| `pre_uninstall` | 是 | 在移除 `current`、入口和版本目录之前运行，`$dir` 仍指向具体版本目录 |
| `uninstaller.script` | 部分 | 生命周期阶段已接入；Main/rclone 原文可执行，Main/7zip/git/notepadplusplus/vscode 的注册表导入明确阻塞 |
| `post_uninstall` | 否 | 样本中的 `post_uninstall` 会删除 `%APPDATA%` 等用户数据，无法在项目内隔离验证 |
| `installer` / `uninstaller` 进程声明 | 否 | 进程型安装器仍单独拒绝，不与脚本子集混同；固定样本没有此类声明 |

脚本在真实 PowerShell 子进程中运行，由 Coop 提供上下文和辅助函数；Coop 不实现任意 PowerShell 解释器，也不把脚本改写成另一门语言。执行前的静态检查是兼容性门槛，不是安全沙箱：它只接受下面列出的命令、参数、变量和成员访问，并拒绝其他构造；被接受的脚本仍是受信任的包内容，与下载的软件产物同级。

## 脚本上下文

| 变量 | 值 |
| --- | --- |
| `$app` / `$bucket` / `$version` / `$architecture` | 包名、bucket 名、版本和所选架构 |
| `$fname` | 第一个产物的本地文件名 |
| `$dir` | `pre_install` 时是具体版本目录；`post_install` 时是 `apps/<包>/current` |
| `$original_dir` | 具体版本目录 |
| `$persist_dir` | `<root>/persist/<包名>` |
| `$bucketsdir` | `<root>/buckets`，用于读取 bucket 自带的脚本资源 |
| `$global` | 恒为 `$false`；Coop 首版不管理系统级安装 |
| `$cmd` | `install`、`update` 或 `uninstall`；更新旧版本时保持 `update`，与 Scoop 的 `uninstaller.script` 语义一致 |
| `$_` | 仅用于 `ForEach-Object` 的当前项 |

辅助函数只有样本证明的三个，文本前缀与固定 Scoop 的 `lib/core.ps1` 一致：

- `ensure <目录>`：目录不存在时创建，返回 `Convert-Path` 解析后的路径。
- `info <文本>`：写入子进程 stdout，文本为 `INFO  <文本>`。
- `warn <文本>`：写入子进程 stderr，文本为 `WARN  <文本>`。固定 Scoop 用彩色 `Write-Host` 输出；Coop 把警告放到 stderr，便于区分两个输出通道。

## 语句与命令子集

脚本按行/分号解析，支持注释、`if`/`elseif`/`else`、`!`/`-not`、`-and`/`-or`、`-eq`/`-ne`/`-match`/`-like` 等比较、双引号插值、单引号字面量、反引号转义、`@(...)` 与逗号数组、`| ForEach-Object { ... }`、`| Out-Null`、`$x = ...` 赋值，以及字符串的 `.Replace(a,b)`。

命令白名单：

| 命令 | 允许的用途 |
| --- | --- |
| `Test-Path` | 读取路径是否存在（`-PathType Leaf/Container`） |
| `Get-Content` | 读取 `$dir`/`$persist_dir`/`$bucketsdir` 下文件 |
| `Set-Content` | 写入 `$dir`/`$persist_dir`/`$bucketsdir` 下文件，支持 `-Encoding Ascii/Unicode/UTF8/Default` |
| `New-Item` | 创建文件或目录（`-ItemType File/Directory`） |
| `Copy-Item` | 复制文件/目录，支持 `-Force` 与 `-Recurse` |
| `Remove-Item` | 删除文件/目录，支持 `-Recurse` 与 `-Force` |
| `Join-Path` / `Split-Path` | 连接或取父路径；结果仍受根目录限制 |
| `Get-Item` | 只读取受限根下路径的元数据，支持 `.LinkType` 与 `.Length` 成员访问，供真实 rclone `uninstaller.script` 使用 |
| `Out-Null` / `ForEach-Object` | 管道消费与逐项处理 |

约束：

- 写入或读取路径必须以 `$dir`、`$original_dir`、`$persist_dir` 或 `$bucketsdir` 开头，且不能含 `..` 父目录组件；`$env:*`、用户目录、注册表和任意驱动器路径会被诊断拒绝。
- 不接受外部命令（`Invoke-WebRequest`、`Start-Process`、`reg`、`sc`、`pip`、`Expand-DarkArchive`、`Expand-MsiArchive`、`Get-EnvVar`、`Set-EnvVar` 等）、`$()` 子表达式、`.NET` 方法调用、`Set-ItemProperty`、`Get-ChildItem`、`Where-Object`、`Select-Object` 等其他构造。已知外部命令会在诊断中列出所需工具，并声明 Coop 不自动下载或安装。
- 参数名也受白名单限制，未列出的参数同样产生诊断，而不是被忽略。
- 单脚本上限 1 MiB；空脚本视为能力缺失。

- **安装器阶段**：`installer.script` 与普通 Hook 共用同一子集和失败语义，但固定样本中没有通过子集的真实 `installer.script`；Main/python 被阻塞。`uninstaller.script` 中 Main/rclone 原文已实际运行。注册表导入、环境变量写入和服务控制仍排除。

### 与固定 Scoop 的已知差异

这些差异是刻意保留的兼容边界，脚本若依赖原行为则不属于已证明子集：

- **错误偏好**：Coop 在 Hook 子进程中设置 `$ErrorActionPreference = 'Stop'`，固定 Scoop 使用调用作用域的默认 `Continue`。因此 Scoop 会容忍的非终止错误在 Coop 中会终止脚本、使操作失败并回滚；这是为了避免“脚本报错但安装被记为成功”。
- **辅助函数输出**：`info`/`warn` 保留固定 Scoop 的 `INFO  ` / `WARN  ` 文本前缀，但不使用彩色 `Write-Host`；`warn` 写入 stderr，`info` 写入 stdout。按颜色或主机流判断输出的脚本不在子集内。
- **路径限制**：固定 Scoop 允许脚本访问任意用户路径；Coop 只接受受限根下的路径并拒绝父目录组件，见下节。

### 上下文与辅助函数边界

静态检查跟踪变量赋值：由 `Join-Path`/`Split-Path` 从受限根派生的变量仍视为受限路径，`ForEach-Object` 块使用独立作用域。字符串中出现的 `$env:*` 作为路径使用时会产生“必须位于受限根”的诊断；作为普通文本（例如替换内容）不构成路径逃逸。

这一边界来自以下真实样本：`Extras/notepadplusplus` 的 `pre_install`/`post_install`、`Main/nodejs` 的 `post_install`、`Main/git` 的 `pre_uninstall`、`Main/rclone` 的 `uninstaller.script`。同一批样本中 `Main/git` 的 `pre_install`/`post_install`、`Extras/vscode`、`Extras/7zip`、`Extras/aider-desk`、`Main/azure-cli` 等脚本需要正则、`Get-ChildItem` 管道、`reg import`、外部进程或 `.NET` 调用，仍被判为不支持；它们不能因为“同一 bucket 的另一个包里可用”而被视为已兼容。

## 官方顺序与 `$dir` 语义

Coop 按固定 Scoop 顺序执行，不把所有脚本都放到 staging：

- 安装：下载/校验/解压 → 创建具体版本目录 → `pre_install`（`$dir`=版本目录）→ `installer.script`（`$dir`=版本目录，`$cmd=install`）→ 建立持久化链接 → 链接 `current`、创建命令入口/快捷方式/环境 → `post_install`（`$dir`=current）→ 提交管理记录。
- 更新：下载/校验/解压新产物 → 旧版本 `pre_uninstall`/`uninstaller.script` → 移除旧 `current`/入口/快捷方式 → 旧版本 `post_uninstall` → 新版本 `pre_install`/`installer.script` → 新 `current`/入口/快捷方式/持久化 → 新 `post_install` → 提交管理记录；旧版本默认保留。
- 卸载：`pre_uninstall`/`uninstaller.script` → 移除 `current`/入口/快捷方式 → 移除版本目录 → `post_uninstall` → 提交；普通卸载保留 `persist` 数据。

`pre_install` 直接在最终版本目录运行，避免把事务临时路径写进脚本生成的文件；`installer.script` 也在该版本目录运行并在 `current` 发布前完成；`post_install` 在 `current` 建立后运行，因此 `$dir` 与 `$persist_dir` 的语义与 Scoop 一致。更新时旧版本脚本先于新版本脚本运行，且 `$cmd` 为 `update`。

## 预览、诊断与失败

- 带脚本的预览不会启动 PowerShell：`install|update|uninstall|adopt --dry-run` 只读取 Manifest 并输出脚本原文、阶段、识别的命令/辅助函数、`compatible` 与诊断；预览的 `execution_available` 为 `false` 时表示执行会被拒绝。
- 缺少能力时在实际执行前诊断：不支持的阶段、命令、参数、变量、路径或缺少 PowerShell 运行时都会阻止下载、事务和管理记录写入。缺少 PowerShell 可执行文件或 `COOP_POWERSHELL` 指向不存在的路径时，预览与执行都会报告同一能力缺口。
- `stdout` 与 `stderr` 用两个线程并发读取，避免大量输出时子进程阻塞；每一字节都写入事务目录的 `scripts/<序号>-<阶段>.stdout.log` / `.stderr.log`，不因输出大小截断。JSON 结果与事务日志记录每流的总字节数，并保存最后约 8 KiB 的摘要尾部（无效 UTF-8 字节替换为 `?`，原始字节仍在日志中）。日志写入失败会使操作失败。
- 脚本退出码非零时整个包操作失败并按事务回滚已创建/移动的包状态；事务日志记录该 Hook 的 `status=failed`、退出码、解释器、日志路径和“外部副作用未知、未自动回滚”的声明。失败脚本不会自动重试。
- 脚本的外部副作用（例如写入受限根之外的注册表、服务或用户目录）无法从 Coop 事务中撤销；这类副作用只能在脚本子集内避免，Coop 不声称完全撤销。
- 运行时可执行文件优先 `pwsh.exe`，其次系统自带 Windows PowerShell。`COOP_POWERSHELL` 仅作为当前子进程的环境参数，用于项目内隔离测试或固定解释器；Coop 不做全局安装或系统环境修改。

## 隔离验证

`tests/hooks.ps1`（CTest `hooks`）在项目内隔离根目录运行真实 CLI、真实 PowerShell 和项目固定测试程序，Hook 原文直接来自固定样本 JSON，不手工改写：

| 场景 | 观察结果 |
| --- | --- |
| 无脚本路径 | 无 Hook 的安装不启动任何 PowerShell 子进程（`process_guard` 只观察到 coop 自身） |
| 预览 | 带 Hook 的预览不启动 PowerShell、不写安装状态，列出两条脚本操作与兼容性 |
| 真实安装 Hook | `Extras/notepadplusplus` 的 `pre_install`/`post_install` 原文运行：pre 阶段在真实版本目录生成配置、post 阶段读取 bucket `.reg` 资源并替换 `$dir`、复制插件；`$npp` 替换结果、用户注册表作用域和命令入口均核对 |
| 真实更新 Hook | 同一包升级后持久化数据保留、旧版本保留、新版本入口运行，新的 `post_install` 在持久化链接后执行 |
| 真实卸载 Hook | 另装一个带 `Main/git` `pre_uninstall` 原文的包并直接 `uninstall`：Hook 以 `command=uninstall` 在版本目录运行，把 `etc/gitconfig` 保存到 `$persist_dir`；卸载后 shim、current、版本目录与管理记录被移除，`data_retained=true`，事务日志记录该 Hook |
| 卸载预览 | `uninstall --dry-run` 在 `process_guard` 下只观察主进程，不执行 Hook、不创建事务或修改安装 |
| 跨阶段顺序 | 旧版本 `pre_uninstall` 的真实产物被新版本 `pre_install` 读取；新版本 `post_install` 读取 `$persist_dir`；事务日志顺序为 `pre_uninstall→pre_install→post_install` |
| 失败传播 | 运行期失败的受支持脚本只执行一次，退出码 1 传播，安装回滚，日志记录失败与 stderr |
| 并发输出 | 约 400 KiB stdout 与约 136 KiB stderr 同时输出时安装成功，完整日志字节数和最后一行尾部均核对 |
| 能力诊断 | 真实 `post_uninstall`、`Main/azure-cli` `pre_uninstall`、父目录路径、`$env:*` 路径与缺少 PowerShell 运行时都在执行前诊断，不启动 PowerShell、不写事务 |
| 接管资格 | 带 Hook 的已安装包仍为 `untested`，不写管理记录；接管该类需要后续真实包证据 |

真实软件产物未在本轮下载或运行：测试用项目固定程序代替包产物，Hook 文本、bucket 脚本资源和生命周期顺序是真实样本。真实 `notepadplusplus`/`nodejs`/`git` 包的下载、安装、更新与卸载不在本轮证据内。

`tests/installers.ps1`（CTest `installers`）补充安装器阶段：MSI 只做预览/隔离限制拒绝，真实 7z 产物和 rclone `uninstaller.script` 原文见 [Installer/Uninstaller 与特殊安装机制](installer-support.md)；该测试用测试脚本验证通用 installer 阶段的顺序、上下文、退出码和失败传播，不声称 Main/python 的 installer.script 已兼容。

## 未运行或未承诺

- 真实包产物的完整下载、安装、更新、卸载（网络与真实程序行为）；本轮只对固定 MSI/7z/rclone 脚本做隔离证据。
- 任意 `installer`/`uninstaller` 进程声明、`post_uninstall`。
- `installer.script` 的固定样本正向覆盖：Main/python 仍被诊断；只有落在子集内的测试脚本验证了阶段语义。
- 注册表导入、用户/系统环境变量写入、服务控制、外部进程（如 `Start-Process`、`Invoke-WebRequest`、`python -m ensurepip`）。
- 正则替换、`Get-ChildItem`/`Where-Object`/`Select-Object` 管道、`.NET` 静态方法、`$()` 子表达式。
- 接管带 Hook 的现有安装并继续更新；该类保持 `untested`，不提升接管资格。
- Windows PowerShell 5.1 解释器路径只实现为回退候选，本轮未单独运行；`pwsh` 路径已实际验证。
- 卡死脚本的超时/取消；Coop 等待脚本结束，与 Scoop 一致，不做静默强杀。
- 无效 UTF-8 输出在 JSON 中的可读性只保证替换为 `?`，不保证保留原始编码语义；原始字节完整保存在日志文件（受磁盘空间限制）。
