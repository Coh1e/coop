# 全量覆盖盘点基线

`baseline.json` 由 [`tests/real-scoop-coverage.ps1`](../real-scoop-coverage.ps1) 生成，记录一次 Main／Extras 全量盘点的紧凑投影：固定 bucket 修订、完整分母、读取/规划/真机验证总数、逐机制状态、缺口包名、产物与摘要算法计数。完整逐包记录（4149 条 Manifest 状态与 68 个 `info`/`plan` 原文）保存在被忽略的 `.local/pi/tasks/<任务>/evidence/` 内，不提交。

- 这不是“已通过”的包名单。读取或规划成功不等于生命周期验证；只有 `verified` 数组中的包在同一修订上有真机运行事实。`verified_version`/`run_exit`/`run_source`/`run_log` 指向与分母 Manifest 版本一致的运行；`facts_version` 只表示 #40 快照当时的版本。
- `verified` 中的 `.local/pi/tasks/40/...` 是本机被忽略的真机证据路径，不随仓库分发；它说明验证来源，不代表新环境能直接读取该文件。
- `project_head` 是生成该投影时的代码提交。bucket 修订、分母和缺口随后续轮次变化；必须用脚本重新生成，不能手工编辑或把历史数字当作当前事实。
- 文件内的 `.local/coverage/root/...` 是该次运行的盘点根；`mechanisms`/`gaps` 中的包名用于定位证据，不代表这些包已修复或已验证。
- `gaps.json` 是 `gaps` 的逐项闭合账本：每个阻塞包的机制、诊断码、根因、处置（子票 #46–#49 或人类批准的 arm64 例外）、闭合状态与证据；`closure` 块记录当前 head、二进制 SHA256、盘点修订、49/55 已解决与 6 行剩余（3 个 Python 宿主前提 + 3 个 ARM64 未运行例外）。CTest `coverage_gaps` 用它与 `baseline.json` 对账，把剩余项标成已解决、删条、改投或删验收条件都会失败。
- `dependency-sources.json` 记录盘点用的官方跨 bucket 依赖来源（当前为 `versions`）的 URL、40 位修订、角色与被依赖的 5 个包；这些 bucket 只用于解析 `versions/*` 依赖，**不进入分母**。守卫会拒绝缺修订、被改写成分母成员或与缺口账本不一致的条目；修改修订必须同时更新依赖证据。
- 生成方式与解释见[Main／Extras 全量兼容盘点](../../docs/coverage-report.md)，缺口处置见[全量盘点缺口闭合与子票](../../docs/compatibility-gap-closure.md)。
