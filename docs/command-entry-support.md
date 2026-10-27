# 命令入口宿主扩展（.py、无扩展名、.config）

> R26 / #47。本页记录 Coop 对固定 Scoop `shim()` 中 `.py` 与 else（bash）分支的实现、宿主缺失诊断、生成的入口文件形状、计划/执行/卸载行为，以及项目内和真实共用根验证。相关缺口归因见[全量盘点缺口闭合](compatibility-gap-closure.md)，入口、快捷方式与环境的其余规则见[复杂命令入口、快捷方式与环境暴露](exposure-support.md)。

## 结论

- Coop 的命令宿主不再只有 EXE/COM、BAT/CMD、PS1、JAR：`.py` 走 python，其他未匹配后缀（无扩展名、`.config`、`.sh` 等）走固定 Scoop 的 else bash 分支。
- `.py` 与 bash 入口生成与 Scoop 同形的 `<别名>.cmd` + 无扩展名 sh 包装，不再为这两类入口复制 Coop 启动器或写 `.shim`/`.coop-shim.json`。生成的 `.cmd`、sh 内容逐行按 Scoop `core.ps1:1076-1116` 的分支构造。
- python/bash 缺失时在任何入口写入前明确失败（预览 `execution_available=false` 并列出外部依赖，实际安装非零且不留下 `shims` 或包目录）；卸载已有入口不要求宿主仍然存在。
- 全量盘点复测中 `adapter/unsupported-command-host` 诊断由 13 条降为 0，`command-entry-host` 机制缺口归零。默认环境没有 `python.exe`，因此 `main/vapoursynth`、`extras/pdd` 的 `.py` 计划仍按 `external-host:python` 环境前提阻塞并逐项列出；这不是“入口机制不支持”。
- 真机共用根实际安装并运行了 `main/neofetch`、`main/git-quick-stats`（bash）和 `main/vapoursynth`（`vsrepo.py`，python），每个都经过 Coop 预览、安装、运行、真实 `scoop reset` 后再次运行、Scoop 列表识别和 Coop 卸载。项目内隔离根另用真实 CPython 3.13.7 与 Git for Windows bash 覆盖 `.py`、无扩展名、`.config` 三类入口的实际运行、更新、卸载和缺失宿主诊断。

## Scoop 兼容基准

固定兼容库为 Scoop v0.6.0（`e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f`）。本票对应的 `shim()` 分支：

| 目标 | 生成文件 | 宿主语义 |
| --- | --- | --- |
| `.py` | `<别名>.cmd`、`<别名>`（sh） | `.cmd` 为 `@python "<target>" <args> %*`；sh 为 `python.exe "<target>" <args> "$@"` |
| 其他（无扩展名、`.config`、`.sh` 等） | `<别名>.cmd`、`<别名>`（sh） | `.cmd` 先检测 `wslpath`，有则用 `bash "$(wslpath -u ...)"`，否则用 `cygpath` 并处理参数引号；sh 按 `$WSL_INTEROP` 选择 `wslpath`/`cygpath` |
| EXE/COM | `<别名>.exe` + `<别名>.shim` | 直接启动（沿用既有实现） |
| BAT/CMD、PS1、JAR | Coop 启动器 + 元数据 | 沿用既有实现（R07/#28） |

Coop 与 Scoop 的差异只在入口目标：Scoop 写具体版本目录，Coop 写 `apps/<包>/current`，更新后同一入口继续指向新版本；两者文件类型、分支选择和参数/退出码转发的可观察行为一致。

## IR、计划与执行

- Adapter 不再把未识别后缀记为 `unsupported-command-host`。每个 `bin` 目标都有宿主：`.py` → `python`，其他 → `bash`；目标路径的相对性、组件安全与别名唯一性校验保持不变。
- 预览的 `package.commands[].launcher` 显示 `python` 或 `bash`；`external_tools` 增加 `Python (command-entry host)` / `bash (command-entry host)`，给出检测到的路径或缺失原因。`--dry-run` 只读清单与 PATH，不创建 shim、包目录或 Coop 记录。
- 实际执行 `entries` 操作时：
  - 先核对宿主存在，再写任何入口；缺失宿主在事务写入前失败。
  - `.py`/bash 入口写 Scoop 形状的 `.cmd` 与 sh 包装，并在管理记录的 `commands` 中保存 `format=scoop-wrapper`、`launcher` 及两个文件摘要；不写 `.exe`、`.shim`、`.coop-shim.json`。
  - `.cmd` 使用 CRLF，sh 使用 LF 且无尾随换行，与 Scoop 的 `Out-UTF8File` 一致。
  - 更新先按内容与命令名移除旧包装，再发布新版本包装；卸载同样只移除内容仍指向 `apps/<包>/` 的包装（包含真实 `scoop reset` 重建的包装），并保留其他包或用户文件。
- 卸载已有入口不再要求 python/bash 宿主存在；否则宿主被卸载后连合法的 Coop 卸载都会被错误拒绝。更新仍要求新入口所需宿主存在。
- 带 `env_set`/`env_add_path` 的包继续由环境操作写入当前用户环境并广播；Scoop 形状的包装不会像 Coop 启动器那样向自身子进程注入未广播的环境值。这是与 Scoop 包装一致的边界，见文末限制。

## 宿主检测与诊断

- python/bash 只按当前进程 `PATH` 中的目录查找 `<dir>\python.exe` / `<dir>\bash.exe`，并要求是普通非重解析、非零长度文件。Microsoft Store 的零长度 App Execution Alias 不会被当作可用解释器。
- 缺失时的诊断明确点名宿主和入口，例如：
  - `Python interpreter not found for the .py command entry ... install Python 3 or add python.exe to PATH ... (entry vsrepo -> vsrepo.py)`
  - `bash not found for the script command entry ... add bash.exe to PATH ... (entry plain-tool -> plain-script)`
- 预览把这些原因放进 `external_tools[].limitation` 与 `diagnostics[].message`；实际安装在任何 `shims`/`apps/<包>` 写入前退出非零。全量盘点的 `capability/execution-blocked` 中这类消息归为 `external-host:python` / `external-host:bash`，不归入 `command-entry-host`。

## 本轮验证（R26 / #47）

工具与代码：`coop 0.1.0`（本票提交构建，`coop.exe` SHA256 `fb6985a651aacb72467f325104359b86f4b031774ac7b742ea9d2712ce742714`）、Windows x64 `10.0.26300.0`、PowerShell 7.6.5、CMake 4.4.4、Ninja 1.13.2、MSVC Build Tools、Scoop v0.6.0。真实宿主为 Git for Windows 2.56.0.4 的 `usr/bin/bash.exe` 与 `cygpath.exe`，以及项目本地 `.local/tools/python/cpython-3.13-windows-x86_64-none/python.exe`（CPython 3.13.7，工程测试依赖，位于被忽略的项目目录，不是产品依赖或全局安装）。以下证据目录均在项目内、被忽略，不随仓库分发。

### 项目内真实兼容根

CTest `command_entry_host`（[`tests/command-entry-host.ps1`](../tests/command-entry-host.ps1)）在 `.local/tests/command-entry-host` 下创建真实 CLI 根；子进程 PATH 只含项目本地 Python 目录和 Git `usr/bin`，不含 Windows 系统目录，因此 bash 分支必须走 `cygpath` 而不是本机 WSL 的 `bash`/`wslpath`。

| 场景 | 真实观察 |
| --- | --- |
| `.py` 预览 | `execution_available=true`，命令 launcher 为 `python`，`external_tools` 检出 Python 路径；没有 `shims`、包目录或 Coop 记录 |
| `.py` 安装与运行 | 生成 `pyhost-tool.cmd` 与 `pyhost-tool`；逐行内容匹配 Scoop `.py` 分支；`.cmd` 与 sh 均以真实 CPython 运行出 `py-host=--default|extra` 并返回脚本退出码 6 |
| `.py` 更新/卸载 | 更新重建包装并运行新版本；宿主被移除（空 PATH）后卸载仍成功，`current` 与新版本目录、两个包装和管理记录消失 |
| 无扩展名 | 生成 Scoop bash 分支 `.cmd`/sh；真实 Git bash 运行出 `plain-host=--default extra` 并返回退出码 7；卸载后无包装残留 |
| `.config` | 同上，运行出 `config-host=extra` 并返回退出码 8；卸载后无包装残留 |
| 缺失 Python | `--dry-run` 给出 `execution_available=false` 和点名 Python 的诊断；实际安装非零，不创建 `shims` 或 `apps/<包>` |
| 缺失 bash | 空 PATH 下同样在写入前失败，诊断点名 bash，不创建入口 |

### 真实共用根

[`tests/real-scoop-command-entry.ps1`](../tests/real-scoop-command-entry.ps1) 在人类选定的共用根 `C:\Users\Neo\scoop`（Scoop v0.6.0，Main `5be7f8c702856c72800a0a4945b88fe6ea2bd52f`）逐一执行：预览无写入 → Coop 安装 → 检查生成包装并运行 → 真实 `scoop reset` → 再运行同一 `.cmd` → `scoop list` 识别 → Coop 卸载 → `scoop list` 不再列出、包装/包目录/Coop 记录消失、用户 `Path` 与前快照一致。

| 包 | 宿主 | 运行命令 | 真实结果 |
| --- | --- | --- | --- |
| `main/neofetch` 7.1.0 | bash | `neofetch --version` | 输出 `Neofetch 7.1.0`；退出码 1（脚本自身对 `--version` 的固定退出码）；`scoop reset` 重建同形 `.cmd` 后再次得到相同输出/退出码 |
| `main/git-quick-stats` 2.11.0 | bash | `git-quick-stats --help` | 退出码 0，输出包含 `git-quick-stats - Simple and efficient way to access various stats`；`scoop reset` 后相同 |
| `main/vapoursynth` 73 | python（`vsrepo.py`） | `vsrepo --help` | 退出码 0，输出包含 `A simple VapourSynth package manager`；生成 `@python "<current>\vsrepo.py"  %*` 的 `.cmd`；`scoop reset` 后相同 |

三次运行的安装都成功，journal 的 `observed_steps` 与本轮预览 `ir_operations` 逐项一致；卸载后 `scoop list` 不再列出对应包，`apps/<包>`、`shims/<别名>.cmd`、`shims/<别名>` 和 `.coop/packages/<包>.json` 均不存在。运行包装时使用子进程 PATH（Git `usr/bin`、Git `cmd`、Python 目录）与 `TERM=xterm`；这避免触发本机 WSL bash，并为 `git-quick-stats` 的 `tput` 提供终端类型。`scoop reset` 与 `scoop list` 使用正常用户 PATH。

### 全量盘点复测

同一 [`tests/real-scoop-coverage.ps1`](../tests/real-scoop-coverage.ps1) 在固定修订（Main 1701 + Extras 2448 = 4149 份）上重跑，使用正常用户 PATH（本机没有真实 `python.exe`，只有 Store 别名；该别名按零长度重解析点拒绝）：

| 指标 | R25 复测 | R26 复测 |
| --- | ---: | ---: |
| 读取通过 | 4149 | 4149 |
| 计划可执行 | 4123 | **4131** |
| 计划被阻塞 | 24 | **16** |
| `command-entry-host` | 11 | **0** |
| `adapter/unsupported-command-host` 诊断 | 13 | **0** |
| 无扩展名计划可执行 | 1 / 8 | **8 / 8** |
| `.config` 计划可执行 | 0 / 1 | **1 / 1** |
| 其余机制 | Manifest 形状 6、依赖缺失 5、arm64 产物 3 | 同左；新增 `external-host:python` 2 |

仍存在的宿主环境前提（逐项列出，未计为机制完成）：

- `main/vapoursynth`（`vsrepo.py`）与 `extras/pdd`（`pdd.py`）在默认用户 PATH 下缺少 `python.exe`，计划被 `external-host:python` 阻塞；需要可用的 Python 3 解释器后才能在该盘点环境执行。两包均未在默认 PATH 环境安装。`main/retdec` 的 `.py` 入口尚未进入宿主判定，因为该 Manifest 仍先在 R27 的 `manifest-shape`（重复派生别名）处失败。
- `main/git-filter-repo` 等无扩展名脚本的 bash 入口已可计划；脚本自身若通过 shebang 调用 `python3`，仍取决于宿主环境是否提供该名字，本票不额外伪造解释器别名。

### 证据与工具版本

| 内容 | 位置（`.local/pi/tasks/47/evidence/` 下） |
| --- | --- |
| 项目内三类入口、更新/卸载、缺失宿主（最终 head） | `entry-test-final-20261027-110332/run.log` |
| `main/neofetch` 真机顺序 | `real-neofetch-final2-20261027-110338/`（`summary.json`、`preview.log`、`install.log`、`run-before-reset.log`、`run-after-reset.log`、`scoop-reset.log`、`uninstall.log`、`scoop-list*.log`） |
| `main/git-quick-stats` 真机顺序 | `real-gitquick-final2-20261027-110355/` |
| `main/vapoursynth` 真机顺序 | `real-vapoursynth-final3-20261027-110412/` |
| 全量盘点复测 | `coverage-20261027-104804/coverage-20261027-024805/`（`summary.json`、`manifests.json`、`commands.log`、共享根前后快照） |
| 完整 CTest（44/44 通过，最终 head） | `ctest-full-final-20261027-110441/ctest-full.log` |
| 构建日志 | `build-1.log` … `build-4.log`、`cmake` 配置输出；最终二进制 SHA256 见上 |

## 未运行与限制

- 默认用户 PATH 没有 Python，因此全量盘点的 `.py` 计划仍以 `external-host:python` 环境前提报告；本票没有在共用根安装 Python 或修改用户 PATH。项目内/真机 `.py` 运行使用显式的项目本地 CPython 子进程 PATH。
- 没有真实的 `.config` Main/Extras 样本可作为可执行程序运行（`main/xtensa-esp32-elf` 的 `.config` 是工具链配置文本，不是可运行入口）；`.config` 与无扩展名共用同一 bash 分支，已由项目内真实 bash 用例覆盖生成、运行、更新和卸载。真实根覆盖了无扩展名 bash 入口。
- 未实际执行 WSL 的 `bash`/`wslpath` 路径；生成的 `.cmd`/sh 与 Scoop 一样保留该分支，但本机按项目约定不使用 WSL。真实运行使用 Git for Windows bash + `cygpath`。
- 未验证真正删除 python/bash 后再执行已发布包装的运行时失败；本票验证的是卸载入口不因宿主缺失而被拒绝，以及安装/更新在写入前给出宿主诊断。
- 入口声明仍只保留 `bin` 元组的单个参数字符串（第三个元素）；Scoop 的多参数元组由 R27 处理。环境声明与 Scoop 包装组合时，环境只通过当前用户环境广播生效，不向包装子进程注入未广播值。
- 未在 arm64 主机执行这些入口；未在本票重新运行与宿主无关的全部真实包生命周期。

## 复现

```powershell
./scripts/build.ps1 -Action build
ctest --test-dir .local/build --output-on-failure -R '^command_entry_host$'
pwsh -NoProfile -File tests/real-scoop-command-entry.ps1 -CoopExe .local/build/coop.exe `
  -EvidenceDir .local/pi/tasks/47/evidence/real-neofetch-<时间戳> `
  -Package main/neofetch -Command neofetch -CommandArguments '--version' `
  -ExpectedOutput 'Neofetch 7\.1\.0' -ExpectedExit 1 -ExpectedHost bash
pwsh -NoProfile -File tests/real-scoop-command-entry.ps1 -CoopExe .local/build/coop.exe `
  -EvidenceDir .local/pi/tasks/47/evidence/real-gitquick-<时间戳> `
  -Package main/git-quick-stats -Command git-quick-stats -CommandArguments '--help' `
  -ExpectedOutput 'git-quick-stats - Simple and efficient way to access various stats' -ExpectedHost bash
pwsh -NoProfile -File tests/real-scoop-command-entry.ps1 -CoopExe .local/build/coop.exe `
  -EvidenceDir .local/pi/tasks/47/evidence/real-vapoursynth-<时间戳> `
  -Package main/vapoursynth -Command vsrepo -CommandArguments '--help' `
  -ExpectedOutput 'A simple VapourSynth package manager' -ExpectedHost python
pwsh -NoProfile -File tests/real-scoop-coverage.ps1 -CoopExe .local/build/coop.exe `
  -EvidenceDir .local/pi/tasks/47/evidence/coverage-<时间戳> -ThrottleLimit 8
```

真实写入脚本在开始前确认目标包未安装、没有 Coop 记录，`finally` 中用 Coop 卸载失败遗留的包并恢复用户 `Path` 快照。本文数字、版本与证据路径只代表 2026-10-27 这一次运行；重跑前应重新核对 bucket 修订、已安装清单与宿主版本。
