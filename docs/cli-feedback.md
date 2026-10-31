# CLI 反馈与下载缓存

2026-10-28 建立；同日按实测重写输出契约。写命令在文本模式下逐步报告进度，下载产物落到与 Scoop 共用的 `<根>/cache`。术语见 [GLOSSARY.md](../GLOSSARY.md) 的「进度反馈」「下载缓存」。

本文件的措辞以 [Scoop 0.6.0 写命令输出实录](research/scoop-cli-output.md) 为准。凡与实录不符的写法都是错误，不是"近似"。

## 文本模式的输出契约

写命令（`install`、`update`、`uninstall`、`reset`、`cleanup`）在执行期间逐行报告阶段；`--json` 不输出任何进度，只保留原有的结果对象。

以下为实录原文（`<ESC>` 是真实存在的控制字符，见 [颜色](#颜色)）：

```
Installing 'ripgrep' (15.2.0) [64bit] from 'main' bucket
Downloading https://.../ripgrep-15.2.0-x86_64-pc-windows-msvc.zip (1.7 MB)...
Checking hash of <ESC>[36mripgrep-15.2.0-x86_64-pc-windows-msvc.zip<ESC>[0m... 
OK.
Extracting <ESC>[36mripgrep-15.2.0-x86_64-pc-windows-msvc.zip<ESC>[0m... 
Done.
Linking <根>\apps\ripgrep\current => <根>\apps\ripgrep\15.2.0
Creating shim for 'rg'.
'ripgrep' (15.2.0) was installed successfully!
```

规则：

- **逐字**：引号、括号、句点、行尾空格、`... ` 与 `OK.` / `Done.` 分成两行，都按实录照排。
- 阶段行在阶段开始或完成时打印，不攒到结束。
- 下载在终端上显示行内进度；**非终端（管道、CI）没有进度条**——这不是 Coop 的选择，Scoop 的进度条被 `lib/download.ps1:73` 的 `isoutputredirected` 锁在 TTY 内。非终端只保留阶段行（`Installing`、`Checking hash of …`、`Extracting …` 等）与结束行；Scoop 在管道里连这些也会省略，Coop 不会——这是刻意保留的差异，便于 CI 日志定位。
- 失败在出错的那一步立刻出现，形状见实录的「失败：hash 不符」段落：`ERROR …` 加字段块和引导语，退出码 1。
- 批量：每包完整走一遍，**没有批级结尾汇总**；`update a b` 在第一个块之前打**一次**表头，只数真正过期的包（`Updating one outdated app:` 或 `Updating N outdated apps:`），已是最新的包在自己的位置报 `<包>: up-to-date`。
- 重复安装同一版本：`WARN  '<包>' (<版本>) is already installed.` 加 `Use 'coop update <包>' to install a new version.`，退出码 **0**，不下载、不读缓存、不写任何东西；批量里遇到已装的包打同一对 WARN，不报成功行。第二行是本期唯一故意偏离逐字的地方：Scoop 写 `Use 'scoop update …'`，而 Coop 不该让正在用它的用户去敲另一个客户端；凡是句子里出现客户端名字、命令提示或 issue 链接，都按当前客户端与真来源生成，阶段行仍逐字。
- 装**另一个版本**（已装 1.0，再 `install` 2.0）：按 Scoop 的语义走正常安装——新版本目录建在旧版本旁边，`current` 重新指向新版本，旧版本保留到 `cleanup` 才删除；输出与普通安装相同，`--json` 的 `retained_versions` 列出旧版本。
- 安装与更新的开始行**不带**结尾句点，卸载与重置**带**。
- 安装完成后，Manifest 的 `suggest`（每个候选都未安装的 feature 一行）与 `notes`（`Notes` / `-----` 块，原文保留换行）依次打印。

## 性能归因

每次写命令都把分阶段耗时写进 `<根>/.coop/timings/`：`steps`（每步的名字、次数、秒数）、`download_seconds`、`local_seconds`、`total_seconds`。只有 `download` 步骤算网络，其余都算本机开销。

`--timings` 在命令结束时追加三行摘要：

```
Timings
-------
download 1.234 s
local    0.456 s
total    1.690 s
```

默认不打印，因此默认输出仍与 Scoop 逐字一致。归因的意义在于**两个量可以分别比较**：一个混着网络的总时长无法与另一客户端对照，旧的那张耗时表就是因为这个被撤掉的。

与 Scoop 的比值对照见 `docs/history/acceptance-matrix.md`（本机比值 0.21，阈值 1.2，由 `scripts/perf-compare.ps1` 产生）。

## 与 Scoop 的逐字对照

| 场景 | 行 |
| --- | --- |
| 安装开始 | `Installing '<包>' (<版本>) [<架构>] from '<bucket>' bucket` |
| 下载 | `Downloading <url> (<大小>)...`（本地产物传输前测量；`http(s)` 在响应头到达时用 `Content-Length`，不额外发请求） |
| 校验 | `Checking hash of <ESC>[36m<文件名><ESC>[0m... ` 换行 `OK.` |
| 解压 | `Extracting <ESC>[36m<文件名><ESC>[0m... ` 换行 `Done.` |
| 链接 | `Linking <根>\apps\<包>\current => <根>\apps\<包>\<版本>` |
| 入口 | `Creating shim for '<别名>'.`；GUI 入口多加 `Making <路径> a GUI binary.` |
| 快捷方式 | `Creating shortcut for <相对路径> (<exe>)` |
| 缓存命中 | `Loading <文件名> from cache`（**无句点**） |
| 安装成功 | `'<包>' (<版本>) was installed successfully!` |
| 重置开始 | `Resetting <包> (<版本>).`（**包名无引号**，**无结尾行**） |
| 卸载开始 | `Uninstalling '<包>' (<版本>).` |
| 卸载入口 | 每个入口两行：`Removing shim '<别名>.shim'.` 和 `Removing shim '<别名>.exe'.` |
| 卸载成功 | `'<包>' was uninstalled.` |
| 清理 | `Removing <包>:`，版本行以空格开头，结尾固定句 `Everything is shiny now!` |
| 更新 | `<包>: <旧> -> <新>` / `Updating one outdated app:` / `Updating '<包>' (<旧> -> <新>)` / `Downloading new version` / `Uninstalling '<包>' (<旧>)` / `Installing '<包>' (<新>) [<架构>] from '<bucket>' bucket` |
| 建议 | `'<包>' suggests installing '<bucket>/<包>'.`（来自 Manifest 的 `suggest`，DarkYellow；同一 feature 有多个候选用 `' or '` 连接，只在候选全部未安装时打印） |
| 尾注 | 成功行之后按 Manifest 的 `notes` 回显 `Notes` / `-----` 块 |
| 重复安装 | `WARN  '<包>' (<版本>) is already installed.` 换行 `Use 'coop update <包>' to install a new version.`（Scoop 这里写 `scoop`，见上文的有意偏离） |

更新的一处**刻意偏离**：coop 在解链旧版本之前完成校验与解压，所以 `Checking hash` / `Extracting` 两行出现在 `Uninstalling` 之前。按 Scoop 的顺序（下载 → 卸载 → 从缓存安装），解压失败会把旧版本一起弄没；coop 的顺序保证失败时 `current` 仍指向可用版本。这一条由 `tests/update-lines.ps1` 的失败用例守着。

## 颜色

Scoop 在文件名两侧硬编码 ANSI 青色（`lib/download.ps1:735` 直接写 `[char]0x1b[36m`），与终端无关，管道里也照写。`suggests` 行用 DarkYellow。Coop 对齐就照写控制字符，不按 TTY 判断——这是"逐字对齐"的直接后果，不是疏漏。

## 下载缓存

- 产物校验通过后写入 `<根>/cache/<包>#<版本>#<sha256(url) 前 7 位><url 扩展名>`，与 Scoop `cache_path` 的现行布局相同，两个客户端共用同一份文件（实测 `probe#1.0#46ee938.zip`，与 Scoop 对同一 URL 算出的 7 位前缀一致）。旧布局 `<声明文件名>` 仍会被读取，命中后照常校验，不会被删除。
- 命中前按 Manifest 声明的算法与摘要重新校验；摘要不符或文件损坏视为未命中并重新下载，缓存内容不被信任。
- 命中时打印 `Loading <文件名> from cache`，随后仍执行同一套校验与解压步骤。
- `-k/--no-cache` 跳过命中，强制重新下载（`cleanup -k` 是另一个含义：清理缓存，见下条）。
- `cleanup -k/--cache` 删除没有对应"已装当前版本"的缓存条目：文件名里的 `<包>#<版本>#` 与安装事实不符就删除，没有这两个分隔符的旧文件不动；`--dry-run` 只列不删。
- 缓存命中的可见场景是 **update** 与**装另一个版本**：同一版本重装是 no-op（`WARN` 两行 + 退出码 0）；换成另一个版本走正常安装，命中缓存时先打 `Downloading new version` 再打 `Loading … from cache`（见下条）。

### 缓存命令

`cache show [包...]` 打印 `Name / Version / Length`，结尾 `Total: N file(s), <大小>`；`Length` 是字节数，`Total` 用 `human_bytes`。`cache rm <包...>` 按 `包#` 前缀删除并逐条打 `Removing <文件名>...`，结尾 `Deleted: N file(s), <大小>`；不带包名或 `*` 时是用法错误（退出 1），不会静默清空整个缓存。`cache rm *` 或 `-a/--all` 清空全部（含无法归属到包的旧文件）。

`download <包...>` 只写 `<根>/cache`，不写安装状态、不建入口：先打 `Downloading '<包>' (<版本>) [<架构>] from <bucket> bucket`，每个产物再走 `Downloading <url> (<大小>)...` 与 `Checking hash of <文件>... ` / `OK.`；命中时打 `Loading <文件> from cache`。`-f/--force` 忽略缓存重新下载，`-s/--skip-hash-check` 跳过校验，`-u/--no-update-scoop` 恒成立。摘要不符时删除该缓存文件并退出 1，不留半成品。

## 每个写命令的示例输出

以下为文本模式的完整形状；`--json` 对每一条都只输出结果对象，不含任何进度行与控制字符。

依赖安装：每个包各自走完整块，并在**自己完成时**报告结果，不攒到最后：

```
Installing 'dep' (1.0.0) [64bit] from 'test' bucket
...
'dep' (1.0.0) was installed successfully!
Installing 'main' (1.0.0) [64bit] from 'test' bucket
...
'main' (1.0.0) was installed successfully!
```

`update`：版本移动行、标题、两段式（见「与 Scoop 的逐字对照」）。

`reset`：`Resetting <包> (<版本>).` 加 Linking 与 shim 行，**无结尾行**。

`cleanup`：删除了什么就列什么，随后空行与固定句；没有可删的版本时只打最后一句。**失败时（退出码 1）不打固定句**——那一轮没有到达"干净"状态，最后一行是错误原因。

```
Removing old:
 2.0.0

Everything is shiny now!
```

`recover`：每个待恢复事务一行结论，随后是它实际执行的动作；没有待恢复事务时打 `No pending transactions`。

```
pkg: install: recovered
  <动作> <路径>
```

## 实测记录

2026-10-28 的旧记录（冷装 31.4 s → 40.0 s 并注明"网络波动"）**不能作为证据**：那次没有把下载时间与本地开销分开，且"再装 1.2 s 对比 Scoop 1.9 s"比的是两种不同行为（Coop 真重装、Scoop 直接拒绝）。可归因的测量方法由性能归因票建立，在此之前本文件不记录耗时数字。

## 尚未完成

- 解压已不再逐文件写穿（#52）：写穿只发生在提交点，单次安装的写穿次数记录在计时记录的 `durable_syncs` 里。启动器共享（#53）尝试后撤回——硬链接破坏逐入口的所有权证据。
- 依赖安装、批量与单包的逐包输出已由 `tests/progress-coverage.ps1` 覆盖（#54）。
- `cleanup` 的**文本**只打印被删除的版本（Scoop 也只打印这些）；保留范围在 `--json` 里完整给出（`current`、`keep_scope`、`scope_summary.keep`），所以 #54 的"保留范围"在机读输出中满足，文本模式按逐字契约刻意不打印。
- 写穿收敛（#52）：369 个文件的归档由 369 次写穿降到 23 次。时间证据来自一次手工 A/B（同一台机器、同一夹具、各 3 次，读 `--timings` 的 `local_seconds`）：把逐文件写穿临时加回后为 0.563 / 0.543 / 0.584 s，去掉后为 0.360 / 0.445 / 0.354 s，中位数 **0.563 → 0.360 s**。复现步骤是：在 `src/archive.cpp` 的 `CloseHandle(handle)` 前加一行 `durable_flush(handle)`，重新构建，对同一归档跑三次 `coop --root <新根> install <包> --timings` 并读 `.coop/timings/*.json` 的 `local_seconds`；删掉该行再跑三次。该对照没有随仓库脚本，因为脚本无法在不改源码的前提下切换两臂；`source_hygiene` 禁止在 `src/data.cpp` 之外直接调用 `FlushFileBuffers`，所以重新引入的逐文件写穿必须走 `durable_flush()`（被 `durable_syncs` 计数，`sync_points` 会红）。`src/data.cpp` 是计数所在的文件，规则对它豁免。该规则只扫 `*.cpp`。
