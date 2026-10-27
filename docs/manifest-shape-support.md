# Manifest 形状、相对路径与重复别名兼容（R27 / #48）

本页记录 Coop 对 Scoop 实际接受、但此前被 `adapter/manifest-shape` 硬拒绝的四类 Manifest 形状的归一化、计划/执行行为、安全边界、真机验证和仍未运行的项。缺口归因见[全量盘点缺口闭合](compatibility-gap-closure.md#manifest-形状相对路径与重复别名6--r27)，本页是该票的实现与证据入口。

## 结论

- Adapter 接受四类形状，并在计划中给出与固定 Scoop v0.6.0（`e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f`）语义逐项一致的结果：
  - 任意长度 `bin` 元组：第一个元素是目标、第二个是别名（缺省时取文件名词干）、其余元素按声明顺序用单个空格拼成参数串并交给 shim（`install.ps1:171-193` 的 `shim_def` / `create_shims`）。
  - `env_add_path` 的 `"."`、`"./"`、`"./bin/"` 和尾分隔符：每个非空元素与 `$dir` 组合后再解析为绝对路径（`install.ps1:309-318` 的 `env_add_path`）。
  - `shortcuts` 目标与图标的 `..` 相对路径：与 `$dir` 组合后按 `FileInfo` 解析，因此可以指向包目录之外（例如共用 `shims` 目录），计划与真实快捷方式都记录折叠后的路径（`shortcuts.ps1:1-22`）。
  - 重复派生别名：保持 Scoop 的发布顺序 last-wins，最终入口取最后一个声明，并在计划和 `info` 的 `warnings` 中报告，而不是静默丢弃或让整份 Manifest 失败（对照 `core.ps1:937-947` 的覆盖语义）。
- 安全边界未放宽：`bin`/`persist`/`extract_dir`/`extract_to`/installer 程序的绝对路径、盘符和 `..` 仍以稳定诊断拒绝；`shortcuts` 的目标与图标仍是相对路径（绝对路径/盘符拒绝），只是允许 Scoop 本身的 `..` 解析；没有新增包外写入路径。
- 六个原先被形状阻塞的包（`main/dcmtk`、`main/stdiscosrv`、`main/wgcf`、`main/zigup`、`main/retdec`、`extras/mqtt-spy`）在真实盘点根 `install --dry-run` 均为 `execution_available=true`，计划的 bin 参数、`env_add_path` 解析值、快捷方式目标/参数/图标与同一 Manifest 的 Scoop 函数语义逐项相等。
- 全量盘点复测的 `manifest-shape` 缺口为 **0**。`main/retdec` 的重复别名不再阻塞解析，但它的 `.py` 入口在默认用户 PATH 下缺少 `python.exe`，因此计入 `external-host:python` 环境前提，而不是形状或宿主机制缺口。

## IR、计划与执行

- `src/ir_adapter.cpp` 的路径归一化新增两个显式开关：`root_allowed`（允许 `.` 指向版本目录本身）和 `parent_allowed`（只对快捷方式目标/图标允许 `..`）。重复分隔符和空组件按 Windows 语义折叠；绝对路径、根名（盘符）和根目录仍在任何字段上拒绝。
- `bin` 元组不再受 3 元素上限约束。别名去重按大小写不敏感比较（Scoop 的 shim 名小写），命中时用后一个声明替换前一个并生成 `adapter/duplicate-command-alias` 警告。
- 警告是 IR 的独立通道（`ir::Warning` / 旧记录 `Package::warnings`），不是诊断：它出现在 `install|update|uninstall --dry-run --json` 的顶层 `warnings`、`info --json` 的 `validation.warnings`，文本模式下打印到 stderr；它不影响 `diagnostics`、退出码或 `execution_available`，因此不会把可执行包误报为 blocked。
- 执行阶段创建快捷方式前先把 `apps/<包>/current/<声明>` 折叠为最终路径，与计划、管理记录和 Scoop 的 `FileInfo.FullName` 使用同一文本；卸载按同一路径核对归属并撤销。
- 多个 `bin` 声明只剩最后一个同名入口；Coop 不会仿造 Scoop 在“同名但宿主不同”时留下的旧格式 shim 文件（例如先 `.exe` 后 `.cmd` 时 Scoop 会留下旧 `.exe`）。因此 Coop 卸载只需要清理它实际发布的唯一入口；这一差异在下方“未运行与限制”如实记录。

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

工具与代码：`coop 0.1.0`（本票提交构建，`coop.exe` SHA256 `1fcae67f51fbd3b6c592c0eae1766a3abb5aa930f09dcfceff24803df19cd16c`）、Windows 11 x64 `10.0.26300.0`、PowerShell 7.6.5、CMake 4.4.4、Ninja 1.13.2、MSVC Build Tools、Scoop v0.6.0。真实盘点根为项目内 `.local/coverage/root`；真实共用根为 `C:\Users\Neo\scoop`。以下目录均在项目内、被忽略、不随仓库分发；每个 run 使用独立子目录，不覆盖此前 coder/verifier 证据。以下三组最终证据都绑定同一二进制 SHA256。

### 项目内隔离回归

CTest `manifest_shape`（[`tests/manifest-shape.ps1`](../tests/manifest-shape.ps1)，测试根 `.local/tests/manifest-shape`）在真实 CLI 上执行 75 项断言：

- 5 元素 `bin` 元组：计划参数、`.shim` 的 `args =` 行、真实 shim 运行的声明参数与调用方参数、卸载清理。
- `env_add_path` 的 `./bin/`、`sub\`、`.`、`./`：4 个声明分别解析，`.`/`./` 都指向版本目录本身。
- `..\..\..\shims\self.cmd` 目标与 `..\..\..\shims\self.ico` 图标：计划路径、真实 `.lnk` 的 TargetPath/IconLocation/Arguments、卸载撤销。
- 重复派生别名：只保留最后一个声明（`.py`）并发布 python 包装，不留下旧 `.exe`；计划与 `info` 均给出 `duplicate-command-alias` 警告；真实运行 python 入口并卸载。
- 上表 8 类越界/绝对路径声明全部仍被拒绝且无写入。
- `env_add_path` 的 "." 与尾分隔符在计划中保留声明顺序；Scoop `Add-Path` 对重复值不做去重，Coop 计划也按声明逐项报告。

证据：`.local/pi/tasks/48/evidence/final-shape/manifest-shape.log`（上一版代码的失败先例见 `red-1/manifest-shape-red.log`）。

### 真实盘点根的六包逐项对照

[`tests/real-scoop-manifest-shape.ps1`](../tests/real-scoop-manifest-shape.ps1) 在 `.local/coverage/root` 上对六个包执行 `install --dry-run --json`，并在同一 PowerShell 进程内按固定 Scoop 源码语义独立计算期望值逐项比较：

| 包 | 计划可执行 | bin 入口 | PATH 项 | 快捷方式 | 形状警告 |
| --- | --- | ---: | ---: | ---: | ---: |
| `main/dcmtk` | 是 | 0 | 1（`current/bin`） | 0 | 0 |
| `main/stdiscosrv` | 是 | 1（5 元素元组） | 0 | 0 | 0 |
| `main/wgcf` | 是 | 1（4 元素元组） | 0 | 0 | 0 |
| `main/zigup` | 是 | 1（4 元素元组） | 1（`current`） | 0 | 0 |
| `main/retdec` | 是 | 31（2 个重复别名 last-wins） | 0 | 0 | 2 |
| `extras/mqtt-spy` | 是 | 1（JAR） | 0 | 1（`shims/mqtt-spy.cmd`） | 0 |

逐项比较的字段：`bin` 的 target/别名/参数串/宿主、`env_add_path` 解析后的绝对路径（忽略尾分隔符差异）、快捷方式的名称/目标/参数/图标。`main/retdec` 需要真实 Python 3 宿主在子进程 PATH 中（`.local/tools/python/cpython-3.13-windows-x86_64-none/python.exe`，项目内测试依赖）；这是环境前提，不是产品能力声明。

证据：`.local/pi/tasks/48/evidence/final-real/inventory-parity.json`、`shape-plan-*.log`、`versions-and-commands.txt`、`summary.json`。

### 真实共用根的顺序交替管理

同一脚本在 `C:\Users\Neo\scoop` 上顺序执行，先记录包是否存在、`coop list`、`scoop export` 与原始用户 `Path`，结束后逐项恢复并核对：

| 包 / 版本 | 操作 | 真实观察 |
| --- | --- | --- |
| `main/wgcf` 2.3.1 | Coop 安装 → `wgcf --help`（多参数 shim） → 真实 `scoop reset wgcf` → 再运行 → Coop 卸载 | Coop 与 Scoop reset 写出的 `.shim` `args =` 完全一致（`--config "<root>\persist\wgcf\wgcf-account.toml"`）；两次运行退出码 0；卸载后 `shims/wgcf.*`、`apps/wgcf/current`、管理记录消失，声明持久化文件按普通卸载保留 |
| `main/zigup` 2025_05_24 | `scoop install zigup` → `zigup --help` → `scoop uninstall zigup` → Coop 安装 → `zigup --help` → Coop 卸载 | Scoop 与 Coop 的 `.shim` `args =` 完全一致（`--path-link "<root>\persist\zigup\zig\zig.exe"`）；`env_add_path: "."` 在 Coop 安装后把 `apps\zigup\current` 写入用户 `Path`，两次运行退出码 0；Coop 卸载后原始 `Path` 逐字符恢复，shim/包目录/记录消失 |
| `main/lessmsi` 2.12.9 | Coop 安装 → 读取快捷方式 → `lessmsi l -t File <msi>` → Coop 卸载 | 快捷方式 `Less MSIérables.lnk` 的 TargetPath 为 `apps/lessmsi/current/lessmsi-gui.exe`、工作目录为 `current`，与 Scoop 公式一致；入口运行退出码 0 并列出 MSI 文件表；卸载撤销快捷方式与入口 |

真实 Scoop 客户端在本次受权操作中自行把共用 `main` bucket 从 `5be7f8c702856c72800a0a4945b88fe6ea2bd52f` 前进到 `eebcee222adc3c30dc8f724c231626f6bf72959d`（git reflog 为 Scoop 的 `pull -q` 快进）。这不是 Coop 的写入，也没有为了“恢复原状”而回滚用户的 bucket；全量盘点因此改用当前实际检出的 `eebcee22`（Extras 仍固定在 `0f8f4b5f…`）。用户 `Path`、`coop list`、`scoop export` 的应用清单在测试前后一致。

证据：`.local/pi/tasks/48/evidence/final-real/`（`summary.json`、每个命令的 `*.log`、`commands.json`、`work/sample.msi`）；更早两次因命令参数/工作目录写错而中止的尝试保留在 `real-2/`、`real-3/`，均通过 `finally` 清理了本轮安装，未覆盖。

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

证据：`.local/pi/tasks/48/evidence/final-coverage/coverage-20261027-040734/`（`summary.json`、`manifests.json`、共享根前后快照、`shared-main-manifest-verification.json`）、`final-coverage/coverage-run.log`、`coverage-1/inventory-clone-update.log`。

## 已知差异与未运行

- **同名不同宿主的旧 shim 残留**：Scoop 的 `create_shims` 对同名别名先后写 `.exe` 与 `.cmd` 时不会删除先前的另一种格式文件；Coop 只发布最后一个声明并给出警告，因此卸载后不会留下 Scoop 会留下的旧 `.exe`。这是有意的单入口归属选择，未声称与 Scoop 的残留文件逐字节一致；`main/retdec` 的真实安装未运行（需要 Python 宿主且下载/安装体积较大），其 last-wins 结果由计划、警告和项目内真实 python 入口用例验证。
- **`extras/mqtt-spy` 真实安装未运行**：它的快捷方式目标显式指向 `shims\mqtt-spy.cmd`，而 Coop 对 JAR 入口发布的是自己的启动器 `shims\mqtt-spy.exe`（R07/#28 的既定行为），因此该目标在 Coop 安装中不存在。计划、快捷方式目标与 Scoop 一致，形状解析已完成；真实安装/卸载未在本票运行，也未标记为通过。该项留给后续跨机制兼容工作。
- **`main/retdec` 的 `.py` 入口**：默认 PATH 无 Python 时计划以 `external-host:python` 阻塞（与 R26 的 `vapoursynth`/`pdd` 同类），本票在盘点根用项目内 Python 证明可执行；未在共用根真实安装 retdec。
- 32bit/arm64 生命周期、其余 4000+ 分母包的真实安装仍为未运行；本票只关闭 Manifest 形状缺口。
