# status JSON v2 与共用结果模型

任务 [#104](https://github.com/Coh1e/coop/issues/104)，父规格 [#102](https://github.com/Coh1e/coop/issues/102)。本阶段交付 `coop status -l --json=2`；`--local` 与 `-l` 等价。原 `status --json` 继续返回原来的本地异常软件数组，原文本形状与退出码不变。

## 检查范围

v2 本地报告读取当前运行的 Coop、同根 Scoop、已登记或共用 bucket，以及用户级和显式系统级根中的安装事实。正常软件也列入 `apps`，系统级项带 `read_only: true`。同根作为软件包安装的 Coop 归入客户端，不重复列为普通软件。

这是只读检查：不访问远端、不 fetch、不创建索引或隔离 Git 配置、不迁移 `<root>/.coop`、不写运行或事务记录。读取已有 bucket 登记时优先使用外部状态，缺席时可只读使用遗留登记；登记损坏时报告诊断并继续发现共享 bucket。已撤销的登记不会被共享目录自动重新激活。

客户端和 bucket 的远端状态为 `not_checked`，原因 `local-only`；这不表示它们已是最新。Scoop 缺席为 `not_applicable`，原因 `not-installed`。本地 Git 修订从实际 HEAD 读取，不把登记中缓存的修订当成当前事实。非 Git 或空仓库的修订可以为 null。

软件提供已装版本、清单版本、版本是否不同、缺依赖、hold、deprecated 和清单缺失等本地事实。`version_differs` **不表示目标版本更高或允许执行更新**；统一版本比较和执行判定属于 #105，本任务不改变更新策略。

完整远端 v2 和 update v2 CLI 仍由后续任务接入，目前明确退出 1、说明能力尚未提供；不静默降格成局部成功。未知 JSON 版本或同时指定冲突格式退出 2，并在副作用前拒绝。

## 格式

stdout 是一个 JSON 对象，包含：

| 字段 | 内容 |
|---|---|
| `schema_version` | 固定为 2 |
| `command` | 当前为 status；共用模型也能表示 update |
| `scope` | 本阶段为 local |
| `request` | local_only、dry_run、targets；由同一个请求模型产生 |
| `clients`、`buckets`、`apps` | 各对象的逐项结果，空集合仍是数组 |
| `stages` | 阶段结果；本地检查阶段说明是否完成 |
| `diagnostics` | 无法归到单个对象的稳定 code/message 诊断 |
| `summary` | state、complete、对象状态计数 counts |

每项包含 `name`、`scope`、`state`、`reason`、`data`、`diagnostics`。`data` 承载该类对象的事实；诊断包含 `code`、`message`。客户端有运行/安装版本或本地 Git 信息，bucket 有路径、登记类型、实际修订与清单数，软件有版本和依赖等事实。null 表示未取得的事实，不能解释为已验证为空。

状态语义：

| 状态 | 含义 |
|---|---|
| ok | 已检查的本地事实正常 |
| attention | 检查完成，发现明确的软件问题或差异 |
| not_checked | 按当前请求范围没有执行该检查 |
| not_applicable | 对象不适用，例如同根未装 Scoop |
| failed | 读取或检查无法完成 |
| blocked、partial | 共用模型可表达的依赖阻断、部分失败；本阶段 CLI 不执行更新 |

诊断、失败对象或失败阶段使 `summary.complete` 为 false，`summary.state` 为 failed，退出 1。已知差异本身为 attention，检查完成仍退出 0；只读模式中有意未执行的远端检查不算失败。对象计数不重复计入阶段；独立对象的成功结果不会被失败阶段覆盖。无错误且无已知问题时 summary 为 ok，只代表上述本地检查完成，不能作为远端最新结论。

支持的 v2 检查把损坏资料诊断写进 JSON，不另向 stderr 拼接诊断或进度。用法错误及尚未提供的命令模式按 CLI 错误通道处理，不伪造 v2 成功文档。

## 模块与验证

[共用结果模型](../src/operation_result.hpp) 同时表达请求、对象和阶段，由一个汇总器计算总体结论与退出码；本地检查返回报告后再序列化。旧文本和旧 JSON 的异常项也从报告对象投影，保持已有机器契约，不把新字段混入旧数组。

CTest `status_v2` 使用真实 CLI、本地 Git 和监听陷阱，覆盖空根、正常项、缺席/已装客户端、损坏记录及清单、坏登记与缺失来源、系统级只读事实、无远端连接和无状态变更。CTest `operation_result` 检查同一模型表达 update 请求、阶段失败、独立对象及总体诊断；它不新增 update CLI 能力。
