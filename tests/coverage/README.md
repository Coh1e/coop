# 全量覆盖盘点基线

`baseline.json` 由 [`tests/real-scoop-coverage.ps1`](../real-scoop-coverage.ps1) 生成，记录一次 Main／Extras 全量盘点的紧凑投影：固定 bucket 修订、完整分母、读取/规划/真机验证总数、逐机制状态、缺口包名、产物与摘要算法计数。完整逐包记录（4149 条 Manifest 状态与 68 个 `info`/`plan` 原文）保存在被忽略的 `.local/pi/tasks/<任务>/evidence/` 内，不提交。

- 这不是“已通过”的包名单。读取或规划成功不等于生命周期验证；只有 `verified` 数组中的包在同一修订上有真机运行事实。`verified_version`/`run_exit`/`run_source`/`run_log` 指向与分母 Manifest 版本一致的运行；`facts_version` 只表示 #40 快照当时的版本。
- `verified` 中的 `.local/pi/tasks/40/...` 是本机被忽略的真机证据路径，不随仓库分发；它说明验证来源，不代表新环境能直接读取该文件。
- `project_head` 是生成该投影时的代码提交。bucket 修订、分母和缺口随后续轮次变化；必须用脚本重新生成，不能手工编辑或把历史数字当作当前事实。
- 文件内的 `.local/coverage/root/...` 是该次运行的盘点根；`mechanisms`/`gaps` 中的包名用于定位证据，不代表这些包已修复或已验证。
- 生成方式与解释见[Main／Extras 全量兼容盘点](../../docs/coverage-report.md)。
