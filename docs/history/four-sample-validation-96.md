# 四样本真实验证（#96）

2026-11-02。前文保留早期未通过轮次；文末「新基线最终复验」记录最新通过结果。任务收尾以 GitHub 规格 #96 及 #97–#101 的记录为准。

## 基线与检查

代码提交 `42aaebc`，Windows PowerShell 5.1；同一 Coop 二进制 SHA256 为 `07B8E09A2D60A36FE78EB92041C6BB35F66878FE77B2EAF4B70D06C99895AD0E`。没有修改产品代码。

`powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1 -Action all`：构建及 82/82 CTest 通过，471.40 秒；日志 `.local/verification-96/build-all-elevated.log`。首次受限运行中止，不计通过。构建脚本聚合输出，结束前没有即时输出不代表卡死。

全部下载、探索脚本、摘要及运行日志保存在项目内 `.local/verification-96/`，不提交用户环境数据和下载产物。

## 场景结果

| 样本 | 本轮已运行证据 | 结论与限制 |
| --- | --- | --- |
| jq | 官方历史修订 `da6f69ed0016a805c16d9d3d78386068a409da3a` 的 1.7.1 与当前 1.8.2 产物 SHA256 匹配；Scoop 安装旧版→Coop 更新新版；另一次建立新旧版本后 Coop reset 旧版→Scoop update -f 更新新版；两方向真实版本均变化，旧版保留，JSON 算式输出 5 | 失败：反向更新后 Coop cleanup 因私有记录仍为 1.7.1、current 指向 1.8.2 而返回 current-mismatch。不能因程序成功运行就宣称双方管理一致 |
| wgcf | 真实安装脚本、帮助命令、Scoop reset；两端 shim 路径与 config 参数一致；普通卸载/重装后测试配置摘要保持；Scoop 卸载 Coop 安装，Coop 卸载 Scoop 安装 | 这些场景通过；未要求真实更新，未注册账户或启动 VPN。程序不支持尝试过的 --version / version，功能证据使用 --help |
| pdd | 项目内 CPython 3.13.7、python-dateutil 2.9.0.post0、six 1.17.0；真实入口计算 2024-01-01 至 2024-01-11，输出 10d；Scoop reset 后及 Scoop 重装后重复；双向卸载；限制子进程 PATH 后预览报告 Python 缺失 | 这些场景通过；依赖仅设置在测试子进程，不宣称默认用户环境具备 Python |
| posh-git | 官方 NuGet 产物，真实安装脚本；新 Windows PowerShell 5.1 进程导入 1.1.0；Scoop reset 后再导入；核对 junction 和当前 Scoop 卸载实现后双向卸载/重装 | 这些场景通过；最终模块清单及用户环境比较一致，不据此推断全部其他模块的逐文件内容均已验证 |

## 最终复验索引

- jq：`.local/verification-96/final-20261102-022843/jq/`；若目录时间需复核，以其中包含 `cleanup-old-reverse.log`、状态 `current-mismatch` 的运行目录为准。`jq-final/` 另保存此前两个真实更新方向的运行。
- 其余三包：`.local/verification-96/final-20261102-022945/`，每个样本独立子目录，`process.json` 退出码均为 0；`run.ps1` 为实际执行脚本，命令索引和逐命令日志在同目录。
- 最终三包运行的 `before-files.json` / `after-files.json` 对比为空，`before-env.json` / `after-env.json` 对比为空。文件快照仅覆盖 apps/shims/persist/modules 顶层对象、长度、时间和链接；不是全根逐文件摘要审计。空的文件和环境差异分别在 `files-diff.txt` / `env-diff.txt`。
- Manifest 摘要、下载摘要和生命周期脚本退出码还可从每个 install 日志的 journal 路径追溯到 Coop 事务。首次模块安装事务为 `8252-99465609`，其中记录原用户 PSModulePath 不存在。

## 偏差、收尾与未完成项

探索阶段出现过验收脚本错误：历史文件名导致安装成 jq-old、reset 未带版本、模块 Version 对象的序列化断言、wgcf 不支持的版本参数。均不能当作产品失败。部分探索续跑覆盖局部索引，最终复验采用独立目录；探索记录不替代最终证据。

Scoop 的历史版本安装来源指向 workspace/jq.json，普通 update 无版本变化；当前 Scoop update 实现明确支持 -f 重新解析 bucket。真正从 1.7.1 到 1.8.2 的更新才计入版本变化，already-latest 不计通过。

Coop 卸载当前版保留过本轮 jq 旧版本目录；已校验路径、产物摘要和仅有三份预期文件后清理。后续发现 cleanup 的 current-mismatch，使用 Scoop 卸载本轮 jq 的全部版本安全收尾。测试包 jq/jq-old/wgcf/pdd/posh-git 均已卸载，wgcf 测试持久化配置已删除，posh-git 模块链接已移除。共享缓存、Scoop 历史 workspace 文件、Coop 事务及项目内证据保留。Scoop 自行刷新 bucket，未回退用户工作树。

仍需补齐各预览阶段独立的无写入快照断言、完整逐场景机器可复核报告及持久化的可重复验收套件。因此 T2–T4 不因上述场景成功而直接关闭，T5 尚未满足整轮通过条件。完整 CTest 通过不替代真实兼容验收。

下一步先决定 jq 管理记录不一致是否授权诊断及修复；本轮不擅自扩展为产品修复。ARM64、全量兼容、性能和故障注入均未运行。
## jq 修复复验（同日后续）

针对上述失败，cleanup 改为从 current 所指向的本地版本目录及匹配的标准安装记录识别当前版本。过期的 Coop 私有记录不再阻止共用客户端更新后的清理；这不是改写私有记录或绕过旧版本归属校验。当前版本证据缺失或 Manifest 版本不匹配时仍保守拒绝清理。

回归测试 `old_versions` 先在修复前稳定失败（current-mismatch，约 6 秒），修复后通过；另验证无效当前版本证据阻止清理、预览不改私有记录、真实清理只删除已记录旧版。

真实复验位于 `.local/verification-96/jq-fix-final/`，两个更新方向、reset、反向更新后的 cleanup 与卸载均完成。`cleanup-old-reverse.log` 正确报告当前 1.8.2，只清理 1.7.1。二进制 SHA256 为 `E289DE10977E2AB724E8CBC8E93E48B97F401DC09FF62EAF0922D236A60855AD`。以上是修复构建的新证据，前文失败记录保留为历史，不代表仍未修复。

本项修复不自动完成 #96 的其余证据补齐与任务关闭工作。
修复后的完整构建及 82/82 CTest 通过（474.26 秒），日志为 .local/verification-96/fix-build-all.log。源码规范、文档链接与最终差异检查通过。审查按项目单代理规定在本会话分别核对 Standards 与 Spec，未发现待修项。

## 新基线最终复验（2026-11-02）

本轮四样本有界验收通过。Scoop 首次安装时自行刷新 Main、Extras，触发固定修订漂移停止；用户随后明确接受 Main `08472508c7bbe7abfa059471050e55f226ee3580`、Extras `8ecc43e85330f37380c19cd4d00f94607d875a39` 为新基线。四份 Manifest 的完整内容未变，Scoop 源码仍为 `e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f`。新来源清单为 `.local/four-samples/baseline-20261102-new/sources.json`，旧清单及失败现场记录保留。

最终命令为 Windows PowerShell 5.1 下的 `scripts/verify-four-samples.ps1 -SourceFile .local/four-samples/baseline-20261102-new/sources.json -CoopExe .local/build/coop.exe -EvidenceDir .local/four-samples -ScoopRoot C:\Users\Neo\scoop -RunLifecycle`。本轮证据位于 `.local/four-samples/run-20261102-060321-ce87aff7/`：`report.json` 保存 27 个通过阶段、106 条退出码均为 0 的命令及逐场景证据；`report.md` 为汇总，`report.lifecycle.json` 保留附入最终仓库检查前的原始结果。启动与归属核验脚本在 `.local/four-samples-final-checks/`。四包使用同一 `E289DE10977E2AB724E8CBC8E93E48B97F401DC09FF62EAF0922D236A60855AD` 二进制，代码基点为 `2a71d9f36689b4aa287d71710501fdcdbc91ea9e`，未提交的验收脚本及其摘要另存于最终证据目录的 `final-scripts/` 和 `final-script-hashes.json`。

| 样本 | 本轮结果 |
| --- | --- |
| jq | 两个客户端分别发起真实 1.7.1→1.8.2 更新；双方识别、JSON 运算、旧版保留、Coop reset、cleanup、双向卸载及重装均通过。反向更新日志为 `028-jq-scoop-update.log`，不是无操作更新 |
| wgcf | 安装脚本、带引号的配置参数、真实帮助输出、Scoop reset、测试配置跨普通卸载/重装摘要保持、双向卸载及本轮数据清理均通过；未注册账户或运行 VPN |
| pdd | 项目内 CPython 3.13.7、dateutil 2.9.0.post0、six 1.17.0；缺宿主预览拒绝，宿主齐备时入口输出固定十天日期差；reset、双向卸载/重装及环境隔离检查通过 |
| posh-git | 官方产物与真实安装脚本、新 PowerShell 5.1 进程导入 1.1.0、模块 junction 与卸载源码核验、reset、双向卸载/重装及环境恢复均通过 |

本轮仅修正验收脚本，没有修改产品代码：Manifest 比较保留双方原始摘要并按完整 JSON 判断内容；列表先解析再枚举，Scoop 的提示流与 JSON 分开；参数使用数组变量转发。普通本地旧版 Manifest 会让 Scoop 更新继续跟随该文件，不能据此验证真实更新。最终流程只读引用既有 `workspace/jq.json`，先与官方历史 Manifest 完整比对，再使用 Scoop 的 `-f` 历史版本固定解除机制；没有改写该缓存或安装记录。上述脚本问题和未发生版本变化的尝试均作为失败历史保留，不并入通过结果。

最终代码状态下运行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1 -Action all`：构建及 **83/83 CTest 通过，473.12 秒**，完整日志为 `.local/four-samples-final-checks/final-build-all.log`，退出码记录为 `final-build-result.json`。这不是引用前面修正脚本前的测试结果。源码规范、脚本解析、文档链接及最终差异另行检查；本轮脚本的列表、参数、来源绑定回归包含在该完整套件内。

验收结束及完整测试之后再次只读核对，四包的安装、入口、持久化与模块对象均不存在，受保护对象和用户环境与基线一致；结果在最终证据目录的 `post-test-state-comparison.json`，最后只读盘点为 `.local/four-samples/readonly-20261102-061512-1a48eb/`。保留共享缓存、Scoop 历史 Manifest、Coop 管理记录/事务及项目内证据，不回退用户 bucket。所有归属清理只处理本轮创建且重新核验过的对象。

边界：日常根不含空格，未实跑含空格根上的 wgcf 生命周期；本机模块目录原本为空，未实跑与其他真实模块并存的场景。外层验收及模块导入探针为 Windows PowerShell 5.1，Coop 实际生命周期 Hook 使用日志记录的 PowerShell 7 宿主，见 `hook-hosts.json`。ARM64、全量 Main/Extras 逐包兼容，以及四个真实样本的性能和故障注入专项均不在本轮通过结论内。验收阶段未发布、提交、推送或关闭任务；后续收尾按用户授权另行记录到 GitHub。
