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
- 下载在终端上显示行内进度；**非终端（管道、CI）没有进度条**——这不是 Coop 的选择，Scoop 的进度条被 `lib/download.ps1:73` 的 `isoutputredirected` 锁在 TTY 内。非终端只保留阶段行。
- 失败在出错的那一步立刻出现，形状见实录的「失败：hash 不符」段落：`ERROR …` 加字段块和引导语，退出码 1。
- 批量：每包完整走一遍，**没有批级表头，也没有结尾汇总**。
- 重复安装同一版本：`WARN  '<包>' (<版本>) is already installed.` 加 `Use 'scoop update <包>' to install a new version.`，退出码 **0**，不下载、不读缓存、不写任何东西。
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

与 Scoop 的比值对照见 `docs/acceptance-matrix.md`（本机比值 0.49，阈值 1.2）。

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

更新的一处**刻意偏离**：coop 在解链旧版本之前完成校验与解压，所以 `Checking hash` / `Extracting` 两行出现在 `Uninstalling` 之前。按 Scoop 的顺序（下载 → 卸载 → 从缓存安装），解压失败会把旧版本一起弄没；coop 的顺序保证失败时 `current` 仍指向可用版本。这一条由 `tests/update-lines.ps1` 的失败用例守着。

## 颜色

Scoop 在文件名两侧硬编码 ANSI 青色（`lib/download.ps1:735` 直接写 `[char]0x1b[36m`），与终端无关，管道里也照写。`suggests` 行用 DarkYellow。Coop 对齐就照写控制字符，不按 TTY 判断——这是"逐字对齐"的直接后果，不是疏漏。

## 下载缓存

- 产物校验通过后写入 `<根>/cache/<声明文件名>`，布局与 Scoop 相同，两个客户端共用同一份文件。
- 命中前按 Manifest 声明的算法与摘要重新校验；摘要不符或文件损坏视为未命中并重新下载，缓存内容不被信任。
- 命中时打印 `Loading <文件名> from cache`，随后仍执行同一套校验与解压步骤。
- 缓存命中的可见场景是 **update**：Scoop 在同一根上重装同一版本不读缓存、直接拒绝，Coop 现在同样拒绝（`WARN` 两行 + 退出码 0），见 #56。

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

`cleanup`：删除了什么就列什么，随后空行与固定句；没有可删的版本时只打最后一句。

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
- 写穿收敛（#52）：369 个文件的归档由 369 次写穿降到 23 次；同机三次对照的中位数从 **0.563 s** 降到 **0.360 s**（约 36%）。任何绕过 `durable_flush()` 的直接 `FlushFileBuffers` 会被 `source_hygiene` 拦下，所以次数统计不会因漏计而失真。
