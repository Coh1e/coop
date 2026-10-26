# 真实 Scoop 安装基线（#22）

> 2026-10-26 后续：R02/#23 已在授权范围内原地刷新真实共用 `main` bucket（`dfc3b581…` → `5cb1b7b9…`）。本页记录的修订与只读结果保留为 R01 当时的事实，不是当前 bucket 修订；刷新证据见[共用 bucket 的直接刷新](shared-bucket-support.md)。

本文件记录 2026-10-26 对本机真实 Scoop 共用环境的只读盘点与查询/预览结果，作为后续任务的对照基线。除只读查询与预览外，本轮未下载、未执行脚本、未安装或卸载任何软件；执行写入的工作由后续任务在其票内授权。

## 环境

| 项目 | 值 |
| --- | --- |
| 平台 | Windows x64，`Microsoft Windows NT 10.0.26300.0` |
| Scoop | v0.6.0（2026-09-30），入口 `C:\Users\Neo\scoop\shims\scoop.ps1` |
| Scoop 根 | `C:\Users\Neo\scoop` |
| bucket | `main`（分支 `master`，`dfc3b581001b2afb4242acabeec4ccde6528ed6d`）、`nerd-fonts`（`2bcffab43a8f736a9410fcd96d32de448eb71090`）；本机未注册 `extras` |
| Coop | 本票提交构建的 `coop.exe`（`coop 0.1.0`） |
| 构建工具 | CMake 4.4.4、Ninja 1.13.2、MSVC x64 Build Tools、Windows SDK；PowerShell 7.6.5 用于运行测试脚本 |
| 证据目录 | `.local/pi/tasks/22/evidence/real-scoop/`（项目内，被忽略） |

## 已安装清单（15 个包，`coop list --json`）

| 包 | 版本 | bucket | 架构 | 本地旧版本 | 声明的持久化映射 |
| --- | --- | --- | --- | --- | --- |
| 7zip | 26.05 | main | 64bit | 26.01, 26.03 | 2 |
| clink | 1.9.34 | main | 64bit | – | 0 |
| cmake | 4.4.4 | main | 64bit | – | 0 |
| fastfetch | 2.70.0 | main | 64bit | 2.64.2, 2.68.1 | 0 |
| fd | 10.5.0 | main | 64bit | 10.4.2 | 0 |
| fzf | 0.74.5 | main | 64bit | 0.73.1, 0.74.4 | 0 |
| gh | 2.103.2 | main | 64bit | – | 0 |
| git | 2.56.0.3 | main | 64bit | 2.54.0, 2.55.0.5 | 0 |
| innounp | 2.71.2 | main | 64bit | 2.67.9, 2.71.1 | 0 |
| ninja | 1.13.2 | main | 64bit | – | 0 |
| pi-coding-agent | 1.4.0 | main | 64bit | – | 0 |
| ripgrep | 15.2.0 | main | 64bit | 15.1.0 | 0 |
| starship | 1.27.0 | main | 64bit | 1.25.1, 1.26.0 | 0 |
| uv | 0.13.5 | main | 64bit | 0.12.17, 0.12.9 | 0 |
| zoxide | 0.10.0 | main | 64bit | 0.9.9 | 0 |

说明：

- 本清单不含 Scoop 自身的 `apps/scoop` 目录，与原查询路径一致。
- 旧版本目录存在并不代表 Coop 拥有其管理权：`old_versions` 逐项标记 `no-coop-version-record`，本轮不删除任何旧版本。
- 未注册 `extras` bucket 是本机事实，不是对 Extras 支持范围的结论；Main/Extras 完整分母由后续盘点任务给出。

## 本轮执行的命令与结果

| 命令 | 退出码 | 结论 |
| --- | --- | --- |
| `coop --root C:\Users\Neo\scoop list --json` | 0 | 15 个安装；无诊断；`management` 均为 `unadopted` |
| `coop --root C:\Users\Neo\scoop info main/7zip --json` | 0 | Manifest 摘要绑定成功；IR 校验 0 条诊断；能力：`windows-installer` 不可用，原生下载/生命周期 Hook/命令入口/快捷方式可用 |
| `coop --root C:\Users\Neo\scoop update 7zip --dry-run --json` | 0 | 预览失败于执行能力（`execution-blocked`：`post_install` 脚本超出已验证子集）；`execution_available=false`；操作序列与 IR 操作序列一一对应 |
| `coop --root C:\Users\Neo\scoop uninstall 7zip --dry-run --json` | 0 | 预览列出卸载入口、命令、快捷方式、持久化解除与版本删除的操作与效果 |
| `process_guard coop --root C:\Users\Neo\scoop list --json` | 0 | 查询未启动任何子进程（无 PowerShell/外部工具） |
| `pwsh -File tests/real-scoop-readonly.ps1 -CoopExe .local/build/coop.exe -EvidenceDir .local/pi/tasks/22/evidence/real-scoop` | 0 | 15 个包盘点 + 查询 + `info` + 更新/卸载预览；根内文件 0 个变化；未创建 `.coop` |

只读证据方法：命令前后对 Scoop 根递归记录每个文件的路径、大小与 `LastWriteTimeUtc` 并比对（0 差异），并检查根下不存在 `.coop`。项目内测试根的查询/预览另外用文件 SHA256 快照与 `process_guard` 核对。

## 观测到的能力缺口（不作为完成证明）

- `7zip` 的更新在 R01 当时被 `post_install` 脚本（Scoop 上下文中的 `$` 表达式）与 MSI 机制阻塞；脚本兼容由 #31 交付、MSI 管理镜像提取由 #33 交付（见[Installer/Uninstaller 与特殊安装机制](installer-support.md)），本节的阻塞分类保留为 R01 当时的盘点。
- 旧版本目录来自 Scoop 常规更新，Coop 尚未记录其归属；本轮只列出，不清理。
- 预览只读是已证明的结果；实际写入、双向交替与真实环境效果尚未在本轮验证。

## 复现

```powershell
./scripts/build.ps1                    # 或本文件记录的等价配置/构建命令
ctest --test-dir .local/build --output-on-failure -R '^ir_pipeline$'
pwsh -NoProfile -File tests/real-scoop-readonly.ps1 -CoopExe .local/build/coop.exe `
  -EvidenceDir .local/pi/tasks/22/evidence/real-scoop
```

执行前应重新盘点并报告变化；本文件中的版本与修订只代表本次记录。
