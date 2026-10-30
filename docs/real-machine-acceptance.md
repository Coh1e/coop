# 本机安装集的逐项交替验收（R19/#40）

> **状态（2026-10-30）**：本页是历史验收快照，命令面、版本与测试数量已继续推进；当前状态与证据入口见 [README](../README.md)。

> 本页记录 2026-10-27 在本机同一真实 Scoop 根上执行的一轮验收：队列是机器当时实际安装的 15 个软件，不是挑选过的固定样本。命令、退出码、逐包事实与日志都在被忽略的 `.local/pi/tasks/40/evidence/cohort-final3/cohort-20261026-201857/` 内；本页只做汇总与索引。

## 结论

- 15 个实际安装的软件逐项记录了运行、版本、入口、环境、数据与安装状态，Coop 与 Scoop 对同一份共享状态的版本判断一致，程序本身由用户+机器 PATH 解析后真实运行。
- 交替管理不是只看查询：14 个包由 Scoop `reset` 重发入口后 Coop 重新识别并运行；10 个有本地旧版本的包由 Coop 往返切换版本并由 Scoop 重新识别；`clink` 由 Coop 真实更新 1.9.34 → 1.9.35；`git` 由 Scoop 真实更新 2.56.0.3 → 2.56.0.4 后 Coop 直接按共享事实识别（不要求接管）；`fastfetch` 由 Coop 卸载并重新安装；`clink` 由 Scoop 卸载后由 Coop 重新安装。
- 本轮发现并修复了共用入口的三个实际问题（见“本轮修复”），并为入口共存补了项目内回归用例；本轮 711 项检查 0 失败。
- `pi-coding-agent` 是正在运行本验收的执行器本身，因此只做只读事实记录，不重写其入口、不切换版本；这是执行环境约束，不是产品能力结论。其余未覆盖范围在“未运行与限制”列出。

## 环境与方法

| 项目 | 值 |
| --- | --- |
| 平台 | Microsoft Windows 11 专业工作站版 N，`10.0.26300.0`，x64 |
| Scoop | v0.6.0（2026-09-30），根 `C:\Users\Neo\scoop`，本机已注册 `main`、`nerd-fonts`，未注册 `extras` |
| 本轮 bucket 修订 | `main` = `5be7f8c702856c72800a0a4945b88fe6ea2bd52f`（运行开始时重新盘点；上一轮记录不是本轮事实） |
| Coop | 本票提交构建的 `coop.exe`，`coop 0.1.0`，SHA256 `76666fae4dad953acaf83c17f7270d3afad91dcd7a33efe5c0cab0dcc9588a79` |
| 工具 | PowerShell 7.6.5、CMake 4.4.4、Ninja 1.13.2、MSVC x64 Build Tools |
| 验收接口 | 真实 `coop.exe --root C:\Users\Neo\scoop …` 与真实 `scoop`，同一机器顺序交替；程序通过 HKCU/HKLM 的 PATH 解析（不使用当前会话继承的 PATH） |
| 脚本 | [`tests/real-scoop-cohort.ps1`](../tests/real-scoop-cohort.ps1)：每次运行写入新的 `cohort-<UTC>` 目录，逐命令记录 argv、退出码与输出 |

“运行/版本/入口/环境/数据/安装状态”的判定来源：

- 版本：`coop list --json`、`scoop list`、`apps/<包>/current/scoop-manifest.json` 与程序自身输出四处一致。
- 入口：`current` junction 指向、`shims/` 中命令入口、开始菜单快捷方式、用户+机器 PATH 的解析结果。
- 环境：`HKCU\Environment` 中声明的变量值与 PATH 条目，按真实路径（`current` junction 与版本目录等价）核对。
- 数据：声明的持久化映射（junction 指向 `persist/…` 的真实文件与 SHA256 抽样）与 `env_set` 指向的持久化目录。
- 安装状态：`current` junction、版本目录、安装记录、Coop 与 Scoop 各自的列表与诊断。

## 逐项结果

运行开始时的队列与逐项事实（`facts-all.json`）；`old=` 是运行开始时本地保留的旧版本目录，不代表 Coop 拥有其清理权。

| 包 | 版本 | 入口与运行（退出码 0） | 环境 | 数据 | 旧版本 | 本轮交替操作 |
| --- | --- | --- | --- | --- | --- | --- |
| 7zip | 26.05 | `7z i` → `7-Zip 26.05 (x64)`，2 个快捷方式 | 无声明 | `persist/7zip/{Codecs,Formats}` 两个 junction 与文件 | 26.01, 26.03 | Scoop reset；Coop 切到 26.03 再回 26.05，数据不变 |
| clink | 1.9.34 → **1.9.35** | `clink --version` → `1.9.35.fa48d0` | `CLINK_DIR` → `apps\clink\current` | 无声明持久化 | 1.9.34 | Scoop reset；**Coop 真实更新到 1.9.35**；Scoop 卸载 1.9.35 后 **Coop 重新安装**并再次通过 Scoop reset |
| cmake | 4.4.4 | `cmake --version` → `cmake version 4.4.4`，1 个快捷方式 | 无声明 | 无声明 | – | Scoop reset（无本地旧版本可切） |
| fastfetch | 2.70.0 | `fastfetch --version` → `fastfetch 2.70.0 (x86_64)` | 无声明 | 无声明 | 2.64.2, 2.68.1 | Scoop reset；Coop 切到 2.68.1 再回 2.70.0；**Coop 卸载并重新安装** |
| fd | 10.5.0 | `fd --version` → `fd 10.5.0` | 无声明 | 无声明 | 10.4.2 | Scoop reset；Coop 切到 10.4.2 再回 10.5.0 |
| fzf | 0.74.5 | `fzf --version` → `0.74.5 (c0a193e0)` | 无声明 | 无声明 | 0.73.1, 0.74.4 | Scoop reset；Coop 切到 0.74.4 再回 0.74.5 |
| gh | 2.103.2 | `gh --version` → `gh version 2.103.2` | 无声明 | 无声明 | – | Scoop reset |
| git | 2.56.0.3 → **2.56.0.4** | `git --version` → `git version 2.56.0.windows.4`，11 个命令入口、3 个快捷方式 | `GIT_INSTALL_ROOT` → `apps\git\current` | 无声明持久化 | 2.54.0, 2.55.0.5, 2.56.0.4 | Scoop reset；Coop 切到 2.56.0.4 再回 2.56.0.3；**Scoop 真实更新到 2.56.0.4 后 Coop 直接识别** |
| innounp | 2.71.2 | `innounp` → `version 2.71.2` | 无声明 | 无声明 | 2.67.9, 2.71.1 | Scoop reset；Coop 切到 2.71.1 再回 2.71.2 |
| ninja | 1.13.2 | `ninja --version` → `1.13.2` | 无声明 | 无声明 | – | Scoop reset |
| pi-coding-agent | 1.4.0 | `pi --version` → `1.4.0` | 无声明 | 无声明 | – | 仅只读（执行器正在使用，见“未运行与限制”） |
| ripgrep | 15.2.0 | `rg --version` → `ripgrep 15.2.0` | 无声明 | 无声明 | 15.1.0 | Scoop reset；Coop 切到 15.1.0 再回 15.2.0 |
| starship | 1.27.0 | `starship --version` → `starship 1.27.0`（无 shim，由用户 PATH 中的 `apps\starship\current` 解析） | PATH 条目 `apps\starship\current` | 无声明 | 1.25.1, 1.26.0 | Scoop reset；Coop 切到 1.26.0 再回 1.27.0 |
| uv | 0.13.5 | `uv --version` → `uv 0.13.5`，3 个命令入口 | 5 个 `UV_*` 变量指向 `persist/uv/…` | `persist/uv/cache` 有 7 个文件；`python`/`tools` 目录尚未创建 | 0.12.17, 0.12.9 | Scoop reset；Coop 切到 0.12.17 再回 0.13.5 |
| zoxide | 0.10.0 | `zoxide --version` → `zoxide 0.10.0` | 无 Coop 声明；用户自设 `_ZO_DATA_DIR` 在 `%LOCALAPPDATA%` 外，未被改动 | 无声明 | 0.9.9 | Scoop reset；Coop 切到 0.9.9 再回 0.10.0 |

说明：

- `cmake`、`gh`、`ninja`、`pi-coding-agent` 在运行开始时 `management=unadopted`，其余为 `managed`。是否“接管”不影响读取、运行、Scoop reset 后的重新识别或本轮 Coop 的版本切换；验收没有把接管当作前置条件。
- `scoop reset` 本身不执行 Manifest 脚本，只重写入口、快捷方式、环境与持久化链接；因此逐项执行的入口重发既真实又不引入软件自身副作用。
- Coop 版本切换只使用本地已存在的版本目录，不下载、不猜 URL；`git`/`uv` 等带环境声明的包在切换后重新核对 `HKCU\Environment` 与命令进程环境。

## 交替生命周期矩阵

| 场景 | 实际执行 | 结果 |
| --- | --- | --- |
| Scoop 改动 → Coop 识别（逐项） | 14 个包各一次 `scoop reset <包>`，此后 Coop 重新读取版本/入口/环境/数据并运行程序 | 14/14 一致；`pi-coding-agent` 排除 |
| Coop 改动 → Scoop 识别（逐项版本往返） | 10 个有本地旧版本的包：`coop reset <包>@<旧版本>` → 运行/比对 → `scoop reset` → 运行 → `coop reset <包>@<当前>` → 运行/比对 | 10/10 通过；旧版本目录在切换后保留，持久化数据抽样不变 |
| Coop 真实更新 | `coop update clink` 1.9.34 → 1.9.35（下载、校验、发布） | 退出 0；Scoop `list`/`reset` 与程序均返回 1.9.35；旧 1.9.34 保留 |
| Scoop 真实更新 | `scoop update git` 2.56.0.3 → 2.56.0.4（Scoop 自己下载并执行其脚本） | 退出 0；Coop 直接识别 2.56.0.4（无接管、无私有记录前置），`GIT_INSTALL_ROOT`、快捷方式与程序均可用 |
| Coop 卸载 → Coop 安装 | `fastfetch`：`coop uninstall` → 确认 `current` 与入口消失 → `coop install` → Scoop `reset` | 退出 0；Scoop 识别 Coop 创建的标准清单/安装记录并运行 2.70.0 |
| Scoop 卸载 Coop 发布 → Coop 重装 | `clink`：Scoop `uninstall` → 入口与 `current` 全部移除 → `coop install` → Scoop `reset` | 退出 0；Coop 清理自己遗留的过期入口元数据后重新发布，Scoop 继续识别 1.9.35 |

## 本轮修复（共用入口）

真实交替暴露了三个只在双方先后写入时出现的问题，均在 `src/execute.cpp` 修复：

1. **双方入口元数据共存被当成冲突。** `uv`/`git` 这类声明了 `env_set` 的包由 Coop 发布 `.coop-shim.json`（含宿主与环境注入），Scoop `reset` 又会写 `.shim`；第二次 Coop 操作曾以 `Command entry has conflicting Coop and Scoop metadata` 拒绝。现在只有两边的包名、目标、参数与宿主都一致时才接受共存；任一视图仍描述当前安装即可继续，真正指向别的包或参数仍然拒绝。
2. **其他客户端改动版本后，Coop 旧记录被当成永不失效的摘要。** `git` 由 Scoop 更新后，Coop 记录里的入口目标/摘要属于旧版本，曾被 `Managed command target changed` 永久拒绝。现在当共享安装的目录或清单已经变化时，记录中的入口、目标与版本指纹按“过期历史”重新从共享事实核对，不再用旧摘要拒绝；同一版本内被外部修改的文件仍会拒绝。
3. **Scoop 卸载 Coop 发布的入口时清不掉 `.exe`。** Scoop 的 `rm_shim` 只在存在 `.shim` 时删除同名 `.exe`。Coop 现在发布 `.coop-shim.json` 的同时写出内容一致的 Scoop `.shim` 视图（路径与参数），因此 Scoop 卸载会连同启动器一起清掉，Coop 重新安装时也能识别并替换遗留的 `.coop-shim.json`。

回归用例：`tests/exposure.ps1` 新增“环境声明包的两种入口视图共存 → Coop 版本往返 → 卸载清理三种文件”的固定夹具用例；`tests/real-scoop-cohort.ps1` 把上述真实交替固化为可重复脚本。

## 未运行与限制

- `pi-coding-agent` 只做只读记录：它正是本轮执行器的运行载体，重写其入口或切换版本会中断验收本身。没有据此断言或否认产品能力。
- 本轮没有为了证明独立性而卸载用户日常使用的 Git、7-Zip 或执行器自身；“无 Scoop 初始化”由 [#38](#38) 的独立初始化测试与本机 `init` 覆盖，不属于本票队列。
- 本机没有注册 `extras` bucket，因此本票不产生 Extras 覆盖面结论；Main/Extras 的完整分母、机制缺口与逐包报告见 [Main／Extras 全量兼容盘点](coverage-report.md)。
- 本轮没有执行 `coop cleanup` 删除用户保留的旧版本、没有 `--purge` 彻底删除，也没有跨包全局回滚的断言；这些由各自票与项目内测试覆盖。
- `scoop reset` 会跳过正在运行的进程（本轮的 `pi-coding-agent` 因此被排除在逐项入口重发之外），这是 Scoop 自身行为，不是本轮的额外限制。

## 证据与复现

本轮证据（项目内、被忽略）：

| 内容 | 位置 |
| --- | --- |
| 运行头、工具版本、bucket 修订、Coop 二进制摘要 | `baseline.json`、`bucket-head.txt` |
| 运行前后清单与 Scoop 视角 | `inventory-before.json`、`scoop-list-before.txt`、`post-run-list.json`、`post-run-scoop-list.log` |
| 逐包事实（15 份） | `items/<包>/facts.json`、`facts-all.json` |
| 每条命令的 argv、退出码、输出 | `commands.json`、`items/…`、`lifecycle/…` 下的 `*.log` |
| 交替生命周期与结果 | `lifecycle.json`、`summary.json` |
| 运行后复验（15 个程序、双方入口视图） | `post-run-verification.log` |

复现（先构建，再按需选择交替项）：

```powershell
./scripts/build.ps1 -Action build
pwsh -NoProfile -File tests/real-scoop-cohort.ps1 -CoopExe .local/build/coop.exe `
  -EvidenceDir .local/pi/tasks/40/evidence/cohort-final3 `
  -Lifecycle -CoopResetPackages 7zip,uv,git,innounp,fastfetch,fd,fzf,ripgrep,starship,zoxide `
  -UpdateClinkViaCoop -UpdateGitViaScoop -ReinstallPackage fastfetch -ScoopRemovePackage clink
```

真实更新只在本地 bucket 中确实存在更高版本时才有意义；重复运行前应重新盘点，并把已更新的目标版本清理或改用当时可用的更新，否则脚本会如实报告“目标版本已存在”而不是把无操作当更新。上文数字与版本只代表 2026-10-27 这一次运行。
