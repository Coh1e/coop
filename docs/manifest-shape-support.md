# Manifest 形状、相对路径与重复别名兼容（R27 / #48）

本页记录 Coop 对 Scoop 实际接受、但此前被 `adapter/manifest-shape` 硬拒绝的四类 Manifest 形状的归一化、计划/执行行为、安全边界、真机验证和仍未运行的项。缺口归因见[全量盘点缺口闭合](compatibility-gap-closure.md#manifest-形状相对路径与重复别名6--r27)，本页是该票的实现与证据入口。

## 结论

- Adapter 接受四类形状，并在计划中给出与固定 Scoop v0.6.0（`e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f`）语义逐项一致的结果：
  - 任意长度 `bin` 元组：第一个元素是目标、第二个是别名（缺省时取文件名词干）、其余元素按声明顺序用单个空格拼成参数串并交给 shim（`install.ps1:171-193` 的 `shim_def` / `create_shims`）。
  - `env_add_path` 的 `"."`、`"./"`、`"./bin/"` 和尾分隔符：每个非空元素与 `$dir` 组合后再解析为绝对路径（`install.ps1:309-318` 的 `env_add_path`）。
  - `shortcuts` 目标与图标的 `..` 相对路径：与 `$dir` 组合后按 `FileInfo` 解析，因此可以指向包目录之外（例如共用 `shims` 目录），计划与真实快捷方式都记录折叠后的路径（`shortcuts.ps1:1-22`）。
  - 重复派生别名：Scoop 的 `shim()` 有两个文件家族：`.exe/.com` 目标写 `<别名>.exe` + `<别名>.shim`，其余目标写 `<别名>.cmd` + 无扩展名 sh 包装（PS1 另写 `.ps1`）。同一家族内重复声明会重写同一批文件，最后一个生效；跨家族声明写入不同文件，两套都保留，Windows 按 PATHEXT 先解析 `.exe`（`core.ps1:949-1130` 的各 `shim()` 分支）。Coop 按同一结果保留同一家族的最后一个声明、跨家族同时保留，并在计划与 `info` 的 `warnings` 中说明实际后果，而不是丢入口或让整份 Manifest 失败。
- `BAT/CMD`、`PS1`、`JAR` 入口现在除 Coop 启动器外，也发布 Scoop 同形的 `.cmd`（PS1 还有 `.ps1`）与 sh 包装视图；这既是 `extras/mqtt-spy` 声明的 `shims/mqtt-spy.cmd` 快捷方式目标，也让跨家族同名别名在磁盘上与 Scoop 一致。卸载从计划列出的包装证据中撤销它们。`.ps1` 视图使用绝对 `$path`（Scoop 对同一盘的 shim 目录写 `Join-Path $PSScriptRoot` 相对形式）；两者在 root 不移动时等价，当前真实对比样本没有 `.ps1` bin 条目，因此这一分支只有夹具验证。
- 安全边界未放宽：`bin`/`persist`/`extract_dir`/`extract_to`/installer 程序的绝对路径、盘符和 `..` 仍以稳定诊断拒绝；`shortcuts` 的目标与图标仍是相对路径（绝对路径/盘符拒绝），只是允许 Scoop 本身的 `..` 解析；没有新增包外写入路径。
- 六个原先被形状阻塞的包（`main/dcmtk`、`main/stdiscosrv`、`main/wgcf`、`main/zigup`、`main/retdec`、`extras/mqtt-spy`）在真实盘点根 `install --dry-run` 均为 `execution_available=true`，计划的 bin 参数、`env_add_path` 解析值、快捷方式目标/参数/图标与同一 Manifest 的 Scoop 函数语义逐项相等。
- 全量盘点复测的 `manifest-shape` 缺口为 **0**。`main/retdec` 的重复别名不再阻塞解析，但它的 `.py` 入口在默认用户 PATH 下缺少 `python.exe`，因此计入 `external-host:python` 环境前提，而不是形状或宿主机制缺口。

## IR、计划与执行

- `src/ir_adapter.cpp` 的路径归一化新增两个显式开关：`root_allowed`（允许 `.` 指向版本目录本身）和 `parent_allowed`（只对快捷方式目标/图标允许 `..`）。重复分隔符和空组件按 Windows 语义折叠；绝对路径、根名（盘符）和根目录仍在任何字段上拒绝。
- `bin` 元组不再受 3 元素上限约束。别名去重按大小写不敏感比较（Scoop 的 shim 名小写）并区分 `.exe/.com` 与脚本家族：同家族命中时用后一个声明替换前一个；跨家族命中时两条都保留并生成 `adapter/duplicate-command-alias` 警告，说明 Scoop 会保留两套文件且 `.exe` 生效。
- 警告是 IR 的独立通道（`ir::Warning` / 旧记录 `Package::warnings`），不是诊断：它出现在 `install|update|uninstall --dry-run --json` 的顶层 `warnings`、`info --json` 的 `validation.warnings`，文本模式下打印到 stderr；它不影响 `diagnostics`、退出码或 `execution_available`，因此不会把可执行包误报为 blocked。
- 执行阶段创建快捷方式前先把 `apps/<包>/current/<声明>` 折叠为最终路径，与计划、管理记录和 Scoop 的 `FileInfo.FullName` 使用同一文本；卸载按同一路径核对归属并撤销。
- 命令发布按家族处理：直接目标写 Coop 启动器与 Scoop `.shim` 视图；`.py`/bash 写 Scoop 包装；`BAT/CMD`、`PS1`、`JAR` 在 Coop 启动器之外同时写 Scoop 包装。跨家族同名别名只由直接声明拥有 `<别名>.exe`，脚本声明只拥有包装，因此 Coop 与 Scoop 的最终文件集合一致；同一家族的重复声明只保留最后一个。卸载验证直接入口的 `.exe`/元数据，并用包装内容中的包名与目标核对脚本包装归属。

## 安全边界

`tests/manifest-shape.ps1` 逐项断言以下声明仍被拒绝（`adapter/manifest-shape`，`execution_available=false`，实际安装非零且不创建包目录/快捷方式）：

| 输入 | 仍拒绝的理由 |
| --- | --- |
| `bin` 为 `C:\Windows\notepad.exe` 或 `C:probe.exe` | 绝对路径/盘符不是包内相对目标 |
| `bin` 为 `..\probe.exe` | 命令目标不得离开包目录 |
| `persist` 为 `..\escape` | 持久化写入不得越界 |
| `extract_dir` 为 `..\escape` | 解压布局写入不得越界 |
| 快捷方式目标/图标为 `C:\Windows\...` | 绝对路径/盘符仍拒绝 |
| `env_add_path` 为 `..\outside` | PATH 写入不得越界（Scoop 会静默过滤，Coop 保留显式诊断） |

## 本轮验证（R27 / #48）

工具与代码：`coop 0.1.0`（本票提交构建，`coop.exe` SHA256 见下组证据的 `versions-and-commands.txt`）、Windows 11 x64 `10.0.26300.0`、PowerShell 7.6.5、CMake 4.4.4、Ninja 1.13.2、MSVC Build Tools、Scoop v0.6.0。真实盘点根为项目内 `.local/coverage/root`；真实共用根为 `C:\Users\Neo\scoop`。以下目录均在项目内、被忽略、不随仓库分发；每个 run 使用独立子目录，不覆盖此前 coder/verifier 证据。最终三组证据（`final2-shape`、`final2-real`、`final2-coverage`）绑定同一二进制 SHA256，并由 `head-binding.json` 把该二进制与提交后的 tree 对应。

### 项目内隔离回归

CTest `manifest_shape`（[`tests/manifest-shape.ps1`](../tests/manifest-shape.ps1)，测试根 `.local/tests/manifest-shape`）在真实 CLI 上执行 102 项断言：

- 5 元素 `bin` 元组：计划参数、`.shim` 的 `args =` 行、真实 shim 运行的声明参数与调用方参数、卸载清理。
- `env_add_path` 的 `./bin/`、`sub\`、`.`、`./`：4 个声明分别解析，`.`/`./` 都指向版本目录本身。
- `..\..\..\shims\self.cmd` 目标与 `..\..\..\shims\self.ico` 图标：计划路径、真实 `.lnk` 的 TargetPath/IconLocation/Arguments、卸载撤销。
- 跨家族重复别名（`bin\probe.exe` 与 `bin\probe.py` 同名）：计划保留两个声明并给出一个跨家族警告；真实安装后 `probe.exe`/`probe.shim`/`probe.coop-shim.json` 与 `probe.cmd`/`probe` 同时存在；`cmd /c probe --via-name` 执行 `.exe` 目标而 `probe.cmd` 执行 python 入口；卸载撤销两套文件。
- 同家族重复别名（`probe.exe` 与 `other.exe` 同名）：只保留最后一个声明，`.shim` 指向 `other.exe`，警告说明“同一批文件被重写”。
- JAR 入口 + `..\..\..\shims\mqtt-spy.cmd` 快捷方式：安装发布 `.cmd`/sh 包装与 Coop 启动器，快捷方式目标真实存在；`.cmd` 使用 Scoop 的 `java -jar` 分支；卸载撤销包装、启动器与快捷方式。
- 上表 8 类越界/绝对路径声明全部仍被拒绝且无写入。
- `env_add_path` 的 "." 与尾分隔符在计划中保留声明顺序；Scoop `Add-Path` 对重复值不做去重，Coop 计划也按声明逐项报告。

证据：`.local/pi/tasks/48/evidence/final2-shape/manifest-shape.log`（上一版代码的失败先例见 `red-1/manifest-shape-red.log`）。

### 真实盘点根的六包逐项对照

[`tests/real-scoop-manifest-shape.ps1`](../tests/real-scoop-manifest-shape.ps1) 在 `.local/coverage/root` 上对六个包执行 `install --dry-run --json`。期望值不再来自测试脚本对 Scoop 规则的重实现：脚本用 [`tests/scoop-shape-probe.ps1`](../tests/scoop-shape-probe.ps1) 在一次性 scratch root 中执行**固定的 Scoop 库本身**（`shim_def`、`create_shims`、`create_startmenu_shortcuts`、`env_add_path` 的 `Join-Path`/`Get-AbsolutePath`/`is_in_dir`），只把会写真实用户环境的 `Add-Path` 和 `startmenu_shortcut` 替换为记录桩；期望的 `.shim`/`.cmd` 内容与快捷方式参数均取自 Scoop 写出的文件。测试脚本内的 PowerShell 规则重实现只作为补充交叉检查，并须与 Scoop 产物逐个相等。

| 包 | 计划可执行 | bin 入口 | PATH 项 | 快捷方式 | 形状警告 |
| --- | --- | ---: | ---: | ---: | ---: |
| `main/dcmtk` | 是 | 0 | 1（`current/bin`） | 0 | 0 |
| `main/stdiscosrv` | 是 | 1（5 元素元组） | 0 | 0 | 0 |
| `main/wgcf` | 是 | 1（4 元素元组） | 0 | 0 | 0 |
| `main/zigup` | 是 | 1（4 元素元组） | 1（`current`） | 0 | 0 |
| `main/retdec` | 是 | 33（31 个唯一别名；`fileinfo`/`unpacker` 各自 exe+py 跨家族并存） | 0 | 0 | 2 |
| `extras/mqtt-spy` | 是 | 1（JAR） | 0 | 1（`shims/mqtt-spy.cmd`） | 0 |

逐项比较的字段：`bin` 的 target/别名/参数串/宿主、`env_add_path` 解析后的路径、快捷方式的名称/目标/参数/图标。`main/retdec` 需要真实 Python 3 宿主在子进程 PATH 中（`.local/tools/python/cpython-3.13-windows-x86_64-none/python.exe`，项目内测试依赖）；这是环境前提，不是产品能力声明。

同一脚本还对 `stdiscosrv`、`retdec`、`mqtt-spy` 在项目内 Coop scratch root 做真实安装，并把 Coop 写出的每个 Scoop 视图文件（`.exe` 只比对存在性，`.shim`/`.cmd`/`.ps1`/sh 比对归一化后的内容）与 Scoop scratch root 的同名文件逐一比较。`retdec` 随后用 `cmd /c retdec-fileinfo probe-argument` 分别在 Scoop 与 Coop 的 shims PATH 下运行：两边都输出 fixture 程序（`.exe` 家族），证明跨家族并存后 `.exe` 仍是有效命令。

证据：`.local/pi/tasks/48/evidence/final2-real/inventory-parity.json`、`shape-comparison.json`、`scoop-probe/`、`coop-scratch/`、`shape-plan-*.log`、`versions-and-commands.txt`、`summary.json`。

### 真实共用根的顺序交替管理

同一脚本在 `C:\Users\Neo\scoop` 上顺序执行，先记录包是否存在、`coop list`、`scoop export` 与原始用户 `Path`，结束后逐项恢复并核对：

| 包 / 版本 | 操作 | 真实观察 |
| --- | --- | --- |
| `main/wgcf` 2.3.1 | Coop 安装 → `wgcf --help`（多参数 shim） → 真实 `scoop reset wgcf` → 再运行 → Coop 卸载 | Coop 与 Scoop reset 写出的 `.shim` `args =` 完全一致（`--config "<root>\persist\wgcf\wgcf-account.toml"`）；两次运行退出码 0；卸载后 `shims/wgcf.*`、`apps/wgcf/current`、管理记录消失，声明持久化文件按普通卸载保留 |
| `main/zigup` 2025_05_24 | `scoop install zigup` → `zigup --help` → `scoop uninstall zigup` → Coop 安装 → `zigup --help` → Coop 卸载 | Scoop 与 Coop 的 `.shim` `args =` 完全一致（`--path-link "<root>\persist\zigup\zig\zig.exe"`）；`env_add_path: "."` 在 Coop 安装后把 `apps\zigup\current` 写入用户 `Path`，两次运行退出码 0；Coop 卸载后原始 `Path` 逐字符恢复，shim/包目录/记录消失 |
| `main/lessmsi` 2.12.9 | Coop 安装 → 读取快捷方式 → `lessmsi l -t File <msi>` → Coop 卸载 | 快捷方式 `Less MSIérables.lnk` 的 TargetPath 为 `apps/lessmsi/current/lessmsi-gui.exe`、工作目录为 `current`，与 Scoop 公式一致；入口运行退出码 0 并列出 MSI 文件表；卸载撤销快捷方式与入口 |

真实 Scoop 客户端在本次受权操作中自行把共用 `main` bucket 从 `5be7f8c702856c72800a0a4945b88fe6ea2bd52f` 前进到 `eebcee222adc3c30dc8f724c231626f6bf72959d`（git reflog 为 Scoop 的 `pull -q` 快进）。这不是 Coop 的写入，也没有为了“恢复原状”而回滚用户的 bucket；全量盘点因此改用当前实际检出的 `eebcee22`（Extras 仍固定在 `0f8f4b5f…`）。用户 `Path`、`coop list`、`scoop export` 的应用清单在测试前后一致。

证据：`.local/pi/tasks/48/evidence/final2-real/`（`summary.json`、每个命令的 `*.log`、`commands.json`、`work/sample.msi`）；更早因命令参数/工作目录写错而中止的尝试保留在 `real-2/`、`real-3/`，均通过 `finally` 清理了本轮安装，未覆盖。

### `extras/mqtt-spy` 的真实 JAR 安装

共用根没有注册 Extras（人类决定），所以用真实 Manifest（真实 URL 与 SHA256）在项目内 root 完成真实下载、安装与卸载，专门证明先前计划/执行不一致的快捷方式目标已经存在：

- `install --dry-run` 为 `execution_available=true`；真实安装退出 0。
- `apps/mqtt-spy/current/mqtt-spy.jar` 的真实 SHA256 与 Manifest 完全一致；`shims/mqtt-spy.cmd` 与无扩展名 sh 包装由 Coop 发布，内容为 Scoop 的 `java -jar` 分支。
- 隔离 `COOP_PROGRAMS_DIR` 下的 `mqtt-spy.lnk` 目标为 `shims/mqtt-spy.cmd`，目标文件真实存在。
- 卸载退出 0，包装、启动器、快捷方式、`apps/mqtt-spy/current` 均消失；JavaFX GUI 本身未启动（标记为未运行）。

证据：`final2-real/mqtt-spy-real/`、`mqtt-real-*.log`、`summary.json` 的 `mqtt_spy_real`。

### 全量盘点复测

同一 [`tests/real-scoop-coverage.ps1`](../tests/real-scoop-coverage.ps1) 在 Main `eebcee222adc3c30dc8f724c231626f6bf72959d`（1701）+ Extras `0f8f4b5fd43bedccc7b233b77f4605bddba8085b`（2448）= 4149 份 Manifest 上重跑，使用正常用户 PATH（没有真实 `python.exe`）：

| 指标 | R26 复测 | R27 复测 |
| --- | ---: | ---: |
| 读取通过 | 4149 | 4149 |
| 计划可执行 | 4131 | **4136** |
| 计划被阻塞 | 16 | **11** |
| `manifest-shape` | 6 | **0** |
| 依赖缺失 | 5 | 5 |
| arm64 产物（64bit 拒绝） | 3 | 3 |
| `external-host:python` | 2 | 3（新增 `main/retdec`） |

本轮盘点未重新运行真机生命周期，因此 `verified_real_cohort=0`、`not_run=4149`；历史 15 个包的真机事实不因本次盘点改写。

证据：`.local/pi/tasks/48/evidence/final2-coverage/<run>/`（`summary.json`、`manifests.json`、共享根前后快照、`shared-main-manifest-verification.json`）、`final2-coverage/coverage-run.log`、`coverage-1/inventory-clone-update.log`。

## 已知差异与未运行

- **同名跨家族别名**：Coop 与 Scoop 都保留 `.exe/.shim` 和 `.cmd`/sh 两套文件，`.exe` 生效；Coop 的 `.coop-shim.json` 是额外的自有元数据视图，不改变 Scoop 可见的文件集合。`main/retdec` 的真实安装未运行（约百 MB 下载且需要 Python 宿主），其跨家族结果由 Scoop 真库 scratch 产物对照、Coop scratch 真实安装、`.exe` 命令解析对照与项目内真实 python 入口用例共同证明。
- **`extras/mqtt-spy`**：形状解析、计划、真实 JAR 下载安装与快捷方式目标已在项目内 root 验证；共用根未注册 Extras，因此未在共用根交替安装，也未启动其 JavaFX GUI。
- **`main/retdec` 的 `.py` 入口**：默认 PATH 无 Python 时计划以 `external-host:python` 阻塞（与 R26 的 `vapoursynth`/`pdd` 同类），本票在盘点根用项目内 Python 证明可执行；未在共用根真实安装 retdec。
- 32bit/arm64 生命周期、其余 4000+ 分母包的真实安装仍为未运行；本票只关闭 Manifest 形状缺口。
