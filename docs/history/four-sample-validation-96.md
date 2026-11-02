# 四样本真实验证（#96）

2026-11-02，本轮运行。整轮未通过，执行票保持未完成。

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