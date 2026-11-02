# 四样本可重复验收

对应规格 [#96](https://github.com/Coh1e/coop/issues/96) 与执行票 #97–#101。
实际运行结果与边界见[四样本真实验证](history/four-sample-validation-96.md)。本文件定义验收入口与流程，
任务状态以 GitHub 规格及执行票为准。

## 本地准备与授权边界

入口为 [verify-four-samples.ps1](../scripts/verify-four-samples.ps1)。不带 `-RunLifecycle`
时只校验项目内来源文件、产物摘要、Manifest 绑定和 Python 文件，不解析或调用 Scoop，
不读取日常安装根、不安装依赖、不联网下载，也不运行提供的可执行文件。

```powershell
powershell.exe -NoProfile -File scripts/verify-four-samples.ps1 -SourceFile .local/four-samples/sources.json
```

真实运行需要另行明确授权，并显式传入 `-RunLifecycle -ScoopRoot <日常共用根>`。
它会修改该根、执行真实安装脚本与用户环境变更；不是普通 CTest 的一部分。
取得目标根的生命周期操作授权后才能执行该模式。现有历史脚本只作为参考，不直接重跑。

## 来源文件

`sources.json` 留在项目内，不提交包含本机路径或环境的数据。所有文件使用绝对项目内路径，
不得通过 junction 或符号链接越出项目。先从官方来源取得并审阅材料，再填写真实摘要；
脚本检查摘要绑定，不代替对来源真实性的人工审阅。

顶层字段：

| 字段 | 内容 |
| --- | --- |
| `sources` | 下述来源对象数组 |
| `python_exe` / `python_exe_sha256` | 项目内解释器及其 SHA256 |
| `python_modules` | 项目内包含 `dateutil` 和 `six` 的目录 |
| `scoop_removal_audit` | 审阅当前 Scoop 模块卸载实现后的记录，见下文 |

每个来源必须提供 `id`、`version`、`source_url`、`artifact_url`、`artifact`、
`artifact_sha256`。URL 必须为 HTTPS，摘要必须为完整 SHA256。
固定来源 ID 为 `jq-old`、`jq`、`wgcf`、`pdd`、`posh-git`、`python`、
`python-dateutil`、`six`，不得重复或省略。

软件包来源另须提供 `bucket`、`revision`（官方 bucket 的完整 Git 修订）、
`manifest`、`manifest_sha256`。jq-old/jq/wgcf 属于 main，pdd/posh-git 属于 extras。
Manifest 的版本、64bit 单产物 URL 和 SHA256 必须与记录一致。
`jq-old` 必须是独立目录内名为 `jq.json` 的官方历史副本；新旧版本必须不同。
Python 与模块记录分别绑定运行时发行归档和下载的 wheel；运行时另检查导入版本及模块路径。

`scoop_removal_audit` 包含：

- `scope`：审阅人确认的 junction 解析、模块删除与环境变更范围，以及相关源码依据。
- `files`：实际影响卸载行为的源码文件数组，每项含相对 Scoop 根的 `relative_path`
  和审阅时的 `sha256`。至少覆盖 uninstall 入口及其模块删除辅助函数。

执行模块卸载前必须重新核对这些摘要与实际 junction。没有审阅记录、摘要变化或目标不符
都会停止，不能仅凭脚本名或历史审阅结果推断安全。Scoop 自行更新后可能需要重新审阅。

## 场景与断言

- jq：Scoop 装旧版→Coop 预览/更新→双方识别；重新建立旧版→Coop reset→Scoop
  强制重新解析 bucket 后真实更新→Coop 识别。两方向断言真实版本、标准 Manifest、
  scoop-install.json、current 目标、双方列表、JSON 计算及旧版保留，再检查 cleanup 与双向卸载。
  旧版安装只读引用 Scoop 既有的 `workspace/jq.json`，使用前与项目内官方历史 Manifest
  完整比对并保存双方摘要，缺失或内容不同即停止。该来源使 Scoop 的 `-f` 版本固定解除机制
  能重新选择 main 最新版；普通任意路径的本地 Manifest 更新仍跟随原文件，不能用于证明版本更新。
- wgcf：安装→reset→Scoop 卸载→Scoop 重装→Coop 卸载。断言帮助内容、shim 目标及
  带引号的配置参数；只写无账户信息的测试配置，逐阶段校验摘要，不注册账户或运行 VPN。
- pdd：限制测试进程 PATH 验证缺宿主预览，再使用项目内 Python/dateutil/six 完成上述
  生命周期。固定日期计算须同时输出 `0y 0m 10d` 与 `10d`，导入路径须落在项目依赖目录。
- posh-git：同样的生命周期，每次在新 PowerShell 5.1 进程导入并精确检查版本和 ModuleBase；
  检查 junction 与卸载源码审阅绑定。其他模块内容进入前后快照。

每次预览独立保存前后快照并比较。保护范围包括目标包完整物理目录、持久化目录、
所有 shims、模块内容与用户环境；不递归穿越目录中的链接。其他应用仅记录顶层身份，
不据此宣称它们逐文件未变。缓存、bucket 刷新和事务记录允许保留，不回退用户 bucket。
根路径没有空格时，仅能证明该根上的配置参数，不能宣称空格根生命周期通过。
标准记录优先读取 `scoop-manifest.json` / `scoop-install.json`，兼容旧文件名。
Scoop 从 URL 保存 Manifest 时可能重新编码，因此逐字段比较全部 JSON 内容，保留来源与
安装副本各自的字节摘要；属性顺序和空白不构成差异，数组顺序及字段值必须一致。
当前 bucket 的 Manifest 也按完整 JSON 内容比较：允许 LF/CRLF、缩进和对象属性顺序差异，
逐字段检查名称、值、类型与数组顺序，不通过有深度截断的序列化结果判断相等。
每次比较在场景证据中保存来源预期摘要、来源实际摘要、bucket 实际摘要及字节/内容比较结果；
来源副本摘要变化、内容漂移、无效 UTF-8 或无法解析为 JSON 对象时拒绝继续。

## 报告与收尾

每次运行创建唯一目录，包含 `sources.json`、`build.json`、`report.json`、`report.md`、
逐命令日志和分场景快照。命令记录参数、退出码和输出文件；场景预先登记为 `not-run`，
运行后更新为 `pass`、`fail` 或 `blocked`，失败后的场景保持未运行。
每次命令前核对二进制摘要；每次引用当前 bucket 时记录实际 Git HEAD 并核对 Manifest。

退出时保存四包实际快照，包括失败后的残留。失败不自动卸载或递归删除；恢复失败须显式报告，
留下对象等待按归属处理。成功路径只删除本轮创建且内容摘要仍匹配的 wgcf 测试配置；
只在用户模块路径仍为本轮预期值时恢复它。并发变更不覆盖。
完整快照可能含本机环境信息，应留在 `.local/`，对外摘录前须脱敏。

`lifecycle-pass-repository-checks-pending` 只表示本脚本生命周期场景通过，不代表 #101 完成。
最终还须附同一代码状态的格式、构建、完整 CTest、差异检查结果，核对全部残留与未运行项。
ARM64、全量兼容、性能与故障注入始终单列未运行。

本地证据辅助函数的回归测试为 CTest `four_sample_evidence`，只操作项目内夹具，
不调用任何真实生命周期命令。该测试不替代四包真实验收。
