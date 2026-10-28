# 写命令验收矩阵

2026-10-28 建立。用于**复核**写命令的输出与行为：Scoop 与 Coop 的逐行对照、缓存自愈与离线复用、六类命令的可复现证据。每条结论都绑定命令、退出码与证据位置，并标明是**本轮运行**、**历史结果**还是**未运行**。

转录由 `scripts/acceptance-matrix.ps1` 生成，写入 `.local/acceptance/`（被忽略，不随仓库分发）；本文摘录关键行，读者按命令可自行重跑。

## 本轮运行环境

| 项 | 值 |
| --- | --- |
| Coop | `coop 0.1.0` |
| 机器 | `HOMELANDER / Microsoft Windows NT 10.0.26300.0` |
| 夹具 | `tidy-5.8.0-win64.zip`，1 370 807 字节 |
| 夹具 SHA256 | `ffb2f86484c66e70e6a6da369cb8f0f459ad2ffec7c7ca80d09a13445ee51a40` |
| 网络 | 无：所有 URL 均为 `file://`（第 16 项故意指向不可达主机的除外） |

## 与 Scoop 的逐行对照

Scoop 侧的原文来自 [Scoop 0.6.0 写命令输出实录](research/scoop-cli-output.md)（历史结果，本轮未重跑 Scoop）；Coop 侧为本轮运行。

| 行 | Scoop（历史） | Coop（本轮） | 对齐 |
| --- | --- | --- | --- |
| 安装开始 | `Installing 'ripgrep' (15.2.0) [64bit] from 'main' bucket` | 同形（无结尾句点） | 逐字 |
| 下载 | `Downloading <url> (<大小>)...` | 本地夹具同形（`(1.3 MB)`）；`http(s)` 目前省略括号 | 本地逐字，网络省略 |
| 校验 | `Checking hash of <文件>... ` / `OK.` | 同形，含青色 | 逐字 |
| 解压 | `Extracting <文件>... ` / `Done.` | 同形，含青色 | 逐字 |
| 链接 | `Linking <根>\apps\<包>\current => <根>\apps\<包>\<版本>` | 同形 | 逐字 |
| 入口 | `Creating shim for '<别名>'.` | 同形 | 逐字 |
| GUI 入口 | `Making <路径> a GUI binary.` | 同形（子系统翻转时） | 逐字 |
| 成功 | `'<包>' (<版本>) was installed successfully!` | 同形 | 逐字 |
| 建议 | `'<包>' suggests installing '<bucket>/<包>'.` | 同形，黄色 | 逐字 |
| 尾注 | `Notes` / `-----` 块 | 同形 | 逐字 |
| 重置 | `Resetting <包> (<版本>).`，无结尾行 | 同形 | 逐字 |
| 卸载 | `Uninstalling '<包>' (<版本>).` 两行入口 + `Unlinking` + `'<包>' was uninstalled.` | 同形 | 逐字 |
| 清理 | `Removing <包>:` / ` <版本>` / 空行 / `Everything is shiny now!` | 同形 | 逐字 |
| 更新 | `<包>: <旧> -> <新>` / `Updating one outdated app:` / 两段式 | 同形，但解压行在 `Uninstalling` **之前** | 刻意偏离，见下 |
| 缓存命中 | `Loading <文件名> from cache` | 同形（无句点） | 逐字 |
| 重复安装 | `WARN  '<包>' (<版本>) is already installed.` + `Use 'scoop update <包>' …` | 同形，退出码 0 | 逐字 |

**Coop 自有步骤**（Scoop 没有，用同句式自述）：`<包>: up-to-date`（无变更的更新）、`<包>: partial`（清理不完整）、`Persistent data retained…`（卸载保留数据）、`recover` 的逐动作行。`--timings` 的摘要只在显式请求时出现。

**刻意偏离**：更新时 Coop 先校验并解压新载荷，再卸载旧版本，所以 `Checking hash` / `Extracting` 出现在 `Uninstalling` 之前。按 Scoop 的顺序（下载 → 卸载 → 从缓存安装），解压失败会把可用版本一起弄没；Coop 的失败用例断言 `current` 仍指向旧版本（`tests/update-lines.ps1`）。

## 耗时对照

同一夹具、同一台机器，`--timings` 的记录（本轮运行）：

| 场景 | download | local | total |
| --- | --- | --- | --- |
| 冷装 | 0.006 s | 0.046 s | 0.052 s |
| 缓存命中重装 | 0.007 s | 0.054 s | 0.061 s |

与 Scoop 的比值由 `scripts/perf-compare.ps1` 单独测量，见下一节。

## 缓存自愈与离线复用（可复现步骤）

```powershell
# 1. 填缓存
coop --root <根> install test/<包> --json
coop --root <根> uninstall test/<包> --json

# 2. 破坏缓存文件的首字节
$cached = "<根>/cache/tidy-5.8.0-win64.zip"
$bytes = [IO.File]::ReadAllBytes($cached); $bytes[0] = 0x00; [IO.File]::WriteAllBytes($cached,$bytes)

# 3. 再装：应重新下载，而不是加载损坏的缓存
coop --root <根> install test/<包>
# 证据行：Downloading file:///...      （本轮 12-cache-corrupt-install，退出码 0）

# 4. 离线复用：把清单的 URL 改成不可达主机，文件名保持不变
#    证据行：Loading tidy-5.8.0-win64.zip from cache   （本轮 16-offline-install，退出码 0）
```

第 4 步是关键：URL 不可达而安装成功，证明命中缓存后没有再联网。

## 六类命令的证据

本轮全部为退出码 0（崩溃注入项除外，见下），转录在 `.local/acceptance/`：

| 命令 | 转录 | 退出码 | 关键行 |
| --- | --- | --- | --- |
| `install`（冷装） | `01-install-cold.txt` | 0 | `Checking hash of …` / `OK.` / `Extracting …` / `Done.` / `'cold' (1.0.0) was installed successfully!` |
| `install`（缓存命中） | `03-install-from-cache.txt` | 0 | `Loading tidy-5.8.0-win64.zip from cache` |
| `update` | `04-update.txt` | 0 | `cold: 1.0.0 -> 1.1.0` / `Updating one outdated app:` / `Uninstalling 'cold' (1.0.0)` / `Installing 'cold' (1.1.0) …` |
| `reset` | `05-reset.txt` | 0 | `Resetting cold (1.0.0).` 且**无结尾行** |
| `cleanup` | `06-cleanup.txt` | 0 | `Removing cold:` / ` 1.1.0` / `Everything is shiny now!` |
| `uninstall` | `07-uninstall.txt` | 0 | `Uninstalling 'cold' (1.0.0).` / `Removing shim …` / `'cold' was uninstalled.` |
| `recover`（崩溃后） | `09-recover.txt` | 0 | `crashy: install: recovered` |
| `install`（崩溃注入） | `08-install-crash.txt` | `-1073740791`（`0xC0000409`） | 进程被 `TerminateProcess` 结束，事务留待恢复 |

## 本轮运行 / 历史 / 未运行

| 类别 | 内容 |
| --- | --- |
| **本轮运行** | 上表九个场景的 Coop 输出与退出码；缓存损坏重下；离线复用；冷装与缓存命中的计时 |
| **历史结果** | Scoop 侧的全部原文（Scoop 0.6.0 实录，本次未重跑 Scoop）；`docs/cli-feedback.md` 里被撤下的旧耗时表不再引用 |
| **未运行** | 真实网络下的下载进度条（非终端不显示，源码层面已确定）；`http(s)` 下载行的大小（本地可测，网络省略） |

## 复现

```powershell
./scripts/fetch-deps.ps1 -Action fetch   # 首次：拉取锁定的夹具与测试归档
./scripts/build.ps1 -Action build
pwsh -File scripts/acceptance-matrix.ps1 -CoopExe .local/build/coop.exe
```

脚本每次从空根开始，重建 bucket 与缓存，输出 `.local/acceptance/` 下的转录与 `summary.json`。同一台机器上重跑，除计时数字外应逐字节一致。

## 与 Scoop 的本地开销对照

`scripts/perf-compare.ps1` 在同一个限速回环服务上交替运行两个客户端，各 5 次，取**本地开销**（总时长 − 下载时长）的中位数。下载时长由服务端节奏决定（8 段 × 40 ms ≈ 0.32 s），两侧相同。

本轮运行（2026-10-28，本机）：

| 客户端 | 各次本地开销（s） | 中位数 |
| --- | --- | --- |
| Coop | 0.227 / 0.117 / 0.112 / 0.102 / 0.114 | **0.114 s** |
| Scoop | 9.488 / 2.217 / 0.234 / 0.201 / 0.218 | **0.234 s** |

比值 **0.49**（阈值 1.2，判定通过）。两次首跑各自带着一次性开销（Scoop 9.8 s、Coop 0.55 s），中位数把它们摊掉。

注意：这只说明"这个小夹具上 Coop 的本地开销不高于 Scoop"，不构成对所有包型的结论；大型包、安装器格式与脚本 Hook 各有自己的路径。