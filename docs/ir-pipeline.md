# 包管理 IR、校验与计划路径

本文件记录 #22（R01）建立的只读 IR 路径：查询与预览从真实 Scoop 安装事实出发，经 Adapter → Package IR → Validator → Planner 输出结果，不需要先执行接管，也不读写 Coop 私有安装记录来判定管理资格。正式行为规格见 [Issue #21](https://github.com/Coh1e/coop/issues/21)，模块边界与后续任务见 [已确认范围](design-scope.md)。

## 模块与单向依赖

| 模块 | 职责 | 不做什么 |
| --- | --- | --- |
| `src/ir.hpp` | 包管理 IR：来源、下载与摘要（含算法）、入口、快捷方式、持久化映射、用户级环境声明、生命周期阶段、安装器声明、依赖、能力、分层诊断、安装事实、计划步骤与前提 | 不含 Scoop JSON 类型、Windows API 或执行策略；后续其他 Package Adapter 可复用 |
| `src/ir_adapter.cpp` | Scoop Manifest → IR；共享安装布局（`apps/<包>/current` 与其保存的 Manifest/安装记录）→ 安装事实 | 不下载、不解压、不执行脚本、不写状态；私有记录不参与安装事实 |
| `src/ir_validate.cpp` | 归一化 IR 契约校验：身份、摘要算法支持、URL 方案、持久化映射重复、依赖版本约束、能力需求（Windows Installer、安装器进程、生命周期阶段、入口宿主、用户环境） | 不重新解释 Scoop 字段；不读取文件或安装状态 |
| `src/ir_plan.cpp` | Plan Builder：把已校验 IR 与当前安装事实变成一条带效果说明的操作序列 | 不绑定具体路径摘要（由调用方在执行前绑定并重查）；不执行 |
| `src/scoop_adapter.cpp` | IR → 现有执行后端使用的旧记录投影，并把 IR 挂在记录上供 Planner 直接消费 | 只做字段投影，不承载来源格式知识 |
| `src/query.cpp` | `list` 使用 IR 安装事实；`info` 附带 IR 校验结果与分层诊断 | 不因执行不兼容隐藏结果；私有记录只作管理元数据 |
| `src/plan.cpp` | 预览与计划文档：操作列表与 IR 操作序列来自同一次 Planner 调用 | 计划前提仍由当前状态绑定并在执行前重查 |

诊断分层固定在 IR 中：`syntax`（来源语法）、`adapter`（来源字段适配）、`ir`（归一化 IR 校验）、`environment`（当前环境前提）、`capability`（能力缺口）、`verification`（验证状态）。查询与预览同时报告各层结论，不用一层结论替代另一层。

## 本次权威边界

- 查询（`list`、`info`）与预览（`install|update|uninstall --dry-run`）的安装事实、诊断与操作序列来自 IR 路径。
- 预览文档同时给出旧 `operations`（`download`/`verify`/…，`detail` 保留来源与声明算法）与新 `ir_operations`（`operation`、`index`、`previous_package`、`effect`）。两者由同一次 Planner 结果投影，数量与顺序一一对应。`artifacts[]` 保留 URL、实际文件名、`#/` 改名标志、算法与摘要；`sha256` 兼容键只用于真实 SHA256 产物。
- R03 起，实际写入由执行器逐条消费 `plan.ir_steps`：每种 IR 操作对应执行后端中的一个处理器，日志记录 `observed_steps`，因此预览顺序、事务日志与真实改动可相互核对；空计划会在执行前被拒绝。
- 共用 Scoop 安装不再要求先执行 `adopt` 或存在 `.coop/packages` 私有记录。直接文件产物（单文件或多产物，无安装器、无归档布局）的更新/卸载直接从 `apps/<包>/current`、标准安装记录、真实 `.shim`/启动入口和实际产物核对事实：每个文件都按声明的算法与摘要验证。归档布局仍缺少解压树证据，继续明确拒绝。私有记录只在存在时作为附加事实证据，缺失或过期时重新读取共享状态。
- 执行仍保留旧 `Package` 记录作为迁移期投影，`adopt` 路径也仍然存在；移除这些旧路径属于后续任务（见 #43）。
- Scoop 状态格式知识的执行核心已不再读取 Scoop 字段；Planner 仍从安装记录读取 `bucket`/`architecture`，catalog 索引也仍读取 Manifest 字段，这两处归入后续统一（见 #43）。

## 只读保证

- 安装事实只读取 `apps/<包>/current` 的保存 Manifest 与安装记录；记录缺失、过期或损坏时仍报告已知事实，并把私有记录问题作为独立诊断。
- 查询不联网、不启动 PowerShell；`info` 的校验只读取 Manifest 字节并计算其 SHA256。
- 预览不写安装状态、不下载产物、不执行脚本。`tests/ir-pipeline.ps1` 用 `process_guard` 观测子进程，并在命令前后对测试根做文件摘要对比；`tests/real-scoop-readonly.ps1` 对本机真实 Scoop 根做同样核对。

## 能力与缺口表达

IR 的 `capabilities` 记录包所需的产品能力与当前是否可用，例如原生下载、ZIP/7z/tar 解压、Windows Installer、安装器进程、生命周期 Hook、命令入口宿主、开始菜单快捷方式、用户级环境持久化。缺失能力只作为明确的缺口报告（例如 MSI 的 `msiexec` 机器缓存、`post_uninstall` 阶段、用户级 PATH 持久化），不作为“包不存在”或“整个包无效”的理由。摘要算法由 IR Validator 按声明校验：SHA256、SHA512、SHA1 和 MD5 都有原生实现，其他算法仍是缺口。多下载项、改名、架构覆盖和失败保护的真机证据见[多产物、架构与摘要算法支持](multi-artifact-support.md)。

## 验证与证据

- `tests/ir-pipeline.ps1`（CTest 名称 `ir_pipeline`）：无私有记录的安装事实、过期/损坏私有记录、IR 操作与效果、摘要算法支持与缺口、MSI 能力缺口、查询/预览无副作用与无子进程。
- `tests/scoop-interop.ps1`（CTest 名称 `scoop_interop`）：无私有记录的单文件与多产物直接文件安装更新/卸载、Scoop reset、GUI/外来启动器判断。
- `tests/multi-artifact.ps1`（CTest 名称 `multi_artifact`）：多下载项、改名、架构选择、SHA512/SHA1/MD5、预览/日志对应与下载/校验失败保护。
- `tests/real-scoop-readonly.ps1`：对本机真实 Scoop 根执行 `list`、`info`、`update --dry-run`、`uninstall --dry-run`，核对安装清单与预览结论，并证明根内文件未改变、未创建 `.coop`。
- 本轮真实安装基线、环境与复现命令见 [真实 Scoop 安装基线](real-scoop-baseline.md)。

## 尚未完成

用户级环境与快捷方式的真实效果、真实脚本与安装器机制、Main/Extras 全量覆盖、双向交替管理的全部软件类别、共享归档布局核对、旧执行/接管路径清理与完整交付验收仍分别由后续任务跟踪。R03 已交付单文件包的真实双向交替路径，R04 已交付多产物、改名、架构与摘要算法的真实安装及失败保护；这些样本不构成整个生态的完成证明。
