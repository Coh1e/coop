# 没有 Scoop 时的独立初始化与使用（#38 / R17）

本文件记录 R17 建立的独立初始化路径：在一台没有 Scoop 的机器（本机以全新空根模拟）上，由 Coop 建立 Scoop 兼容的标准布局，完成真实安装与管理；之后用户再安装 Scoop，同一 root 仍能被 Scoop 识别和继续管理。正式规格见 [Issue #21](https://github.com/Coh1e/coop/issues/21)，共用状态决策见[共用 Scoop 状态的决定](adr/0002-share-scoop-state.md)。

## 命令契约

`coop init [--dry-run] [--json]` 在选中的 root 内建立双方共用的标准目录，只创建缺失项：

| 标准目录 | 用途 |
| --- | --- |
| `apps` | 版本目录、`current` 链接、标准安装记录 |
| `buckets` | Scoop 兼容的 bucket 工作树与本地 bucket |
| `cache` | Scoop 约定的下载缓存位置 |
| `persist` | Manifest `persist` 声明数据的存放根 |
| `shims` | 命令入口与 Scoop shim 元数据 |

- 已存在同名目录时保留原内容、不重写、不删除；重复执行是幂等的。已存在同名普通文件或 root 本身是文件时，在写入任何目录前以非零退出并给出具体路径。
- `--dry-run` 只报告 `created`/`existing`/`scoop_installation`，不创建 root 或任何目录；`--json` 输出 `root`、`dry_run`、`directories`（固定顺序）、`created`、`existing`、`scoop_installation.present`。
- `init` 只建立布局：不写 Coop 私有记录、不注册 bucket、不下载、不执行脚本、不修改用户 PATH 或环境变量，也不启动任何子进程。包安装后由 `install` 正常写入 `apps/<包>/...` 的 Scoop 标准安装记录（`scoop-manifest.json`、`scoop-install.json`、`current`、`.shim`），Scoop 依此识别；用户级 PATH/环境注册属于 [R08](exposure-support.md#用户环境真机验证r08-29) 的独立行为，不由 `init` 静默完成。
- 根内已有 `apps/scoop/current` 时，`init` 在 `scoop_installation.present` 中报告“已有 Scoop 安装”，仍只补建缺失的标准目录。

## 独立性依据

`init` 与后续安装路径不要求机器预装 Scoop、Git 或 7-Zip：

- 目录创建、下载、校验和解压都是 Coop 自身实现；bucket 使用内嵌 libgit2，归档使用内嵌 libarchive/zlib/lzma/zstd/bzip2，普通 ZIP/7z/tar 不需要外部 `7z.exe`。固定版本和许可见 [THIRD_PARTY.md](../THIRD_PARTY.md)。
- 需要脚本语义时才启动真实 PowerShell，并使用固定的 Scoop 兼容库（版本、许可和逐文件来源同样记录在 `THIRD_PARTY.md`）；R17 使用的 `jq` 不声明脚本，安装阶段没有脚本子进程。
- 验证没有卸载用户已有的 Scoop/Git/7-Zip 来制造“无依赖”条件，而是在受控子进程树中把 `PATH` 指向一个空目录，使 `git`、`7z`、`scoop` 无法解析，再执行 `init`、bucket 克隆、安装和运行；`process_guard` 同时观察完整进程树。

## 真机验证（本机共用环境的受控新根）

`tests/real-scoop-initialization.ps1` 在项目内 `.local/tests` 下创建运行专用的全新 root，按顺序执行并在每步记录退出码、stdout/stderr 与证据文件：

| 步骤 | 观察结果 |
| --- | --- |
| 全新 root | 不存在、无 `apps/scoop`、无 bucket、无 7-Zip；不是由 Scoop 创建的状态 |
| 受限 `PATH` | `Get-Command git/7z/scoop` 均为 `absent`，直接执行 `git --version` 报“not recognized”；用户机器上的工具仍在原位（`C:\Users\Neo\scoop\shims\git.exe`、`7z.exe`、`scoop.ps1`） |
| 未初始化对照 | 真实 Scoop 指向未初始化目录执行 `list jq` 退出 1（缺少 shims 等布局），且未创建 root |
| `init --dry-run` | 退出 0，列出 5 个待建目录，root 仍未创建 |
| `init --json`（进程观测） | 退出 0；`process_guard` 观察到 1 个工作进程（无子进程）；创建 `apps,buckets,cache,persist,shims`，无 `.coop`，JSON 报告无 Scoop 安装 |
| 重复 `init` | 退出 0，`created` 为空、`existing` 为 5 项，原内容不变（隔离测试另核对指纹一致） |
| `bucket add main file:///C:/Users/Neo/scoop/buckets/main` | 退出 0，用内嵌 Git 库克隆出 `buckets/main/.git`，修订 `a97619fec75f0c74bd74e73b0e9138df08687a50` 与真实 `main` 当前 HEAD 一致 |
| `install jq --json`（进程观测） | 退出 0，下载/校验/解压全程 1 个工作进程、无子进程；版本 1.8.2 |
| 运行程序 | `shims/jq.exe --version` 退出 0，输出 `jq-1.8.2` |
| `coop list --json` | 退出 0，`jq 1.8.2`、bucket `main`；标准记录 `apps/jq/current/scoop-manifest.json`、`scoop-install.json`、`.shim` 与启动器均存在 |
| 之后再安装 Scoop | 复用本机真实 Scoop 程序树（v0.6.0，`apps/scoop/current` 181 个文件、18,784,907 字节，MIT `LICENSE` SHA256 `a3f4c7bfdb45275a4d48aed48594249b071f7fd80d024b91ae814de6b522b42a`）复制到同一 root，并复制 `shims/scoop*` 入口；不联网、不重新下载 |
| 再执行 `init` | `created` 为空，`scoop_installation.present=true`，未改动已有 Scoop 程序 |
| Scoop `list jq` | 退出 0，显示 `1.8.2`、来源 `main` |
| Scoop `reset jq` | 退出 0；用真实 Scoop kiennq shim（SHA256 `140e3801d8adeda639a21b14e62b93a4c7d26b7a758421f43c82be59753be49b`）替换 Coop 启动器并重建 `.shim`；复位后程序仍输出 `jq-1.8.2` |
| Coop 重新识别 | 退出 0，`coop list` 仍显示 `1.8.2`、`management=managed`，不要求重新接管 |
| Scoop `uninstall jq` | 退出 0；`apps/jq/current` 与入口消失，`coop list` 不再列出该包 |
| Coop 重装 → Scoop 识别 → Coop 卸载 | 三步退出均为 0；Scoop `list` 能识别 Coop 重装的 1.8.2，Coop 卸载后入口与 `current` 清理干净，Scoop 不再列出 |

Scoop 的 `reset` 会按自身语义把新 root 的 `shims` 加入当前用户 PATH（输出 `Adding … to your path`）。测试在运行前读取 `HKCU\Environment\Path` 的原值和类型，结束后恢复并核对完全一致；证据 JSON 记录 Scoop 实际新增的项、恢复前后的值和 `user_path_restored=true`，未留下测试 root 的 PATH 项。其余步骤没有用户环境写入。

## 隔离回归

`tests/initialization.ps1`（CTest `initialization`）使用项目内隔离 root 覆盖：预览不创建、初始化只建 5 个标准目录且不建 `.coop`、重复执行不改变已有内容、同名文件冲突时在任何写入前失败且保留原文件、root 为文件时拒绝、未知参数被拒绝、已有部分 Scoop 布局只补建缺失目录并在 `scoop_installation.present` 如实报告。CTest `init_no_children` 用 `process_guard` 证明 `init` 不启动子进程。

## 复现

```powershell
./scripts/build.ps1
ctest --test-dir .local/build --output-on-failure -R '^(initialization|init_no_children|cli)$'
pwsh -NoProfile -File tests/real-scoop-initialization.ps1 `
  -CoopExe .local/build/coop.exe `
  -EvidenceDir .local/pi/tasks/38/evidence/real-scoop-initialization-run6 `
  -TestRoot '.local/tests/real-scoop-initialization'
```

本页记录的是本轮可复现结果；bucket 修订、Scoop 版本和包版本以运行时重新盘点为准。

## 未覆盖与边界

- “没有 Scoop”是受控执行条件：本机仍保留用户日常使用的 Scoop/Git/7-Zip，只让测试进程树无法解析它们。没有在真正未安装这些工具的独立机器上重跑，也没有卸载本机真实工具来制造条件。
- `init` 不负责用户 PATH 注册、快捷方式目录或持久化根以外的用户环境；这些行为由 R08 及入口/持久化任务分别验证，不能据此认为新机器首次使用时无需任何环境步骤。
- 本轮真实样本是 Main 的 `jq`（ZIP、单文件入口、无脚本）。脚本包、安装器包、依赖和持久化在独立 root 中的组合仍由各自机制任务覆盖；`init` 本身不改变这些机制的兼容范围。
