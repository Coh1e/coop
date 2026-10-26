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
- 预览文档同时给出旧 `operations`（`download`/`verify-sha256`/…）与新 `ir_operations`（`operation`、`index`、`previous_package`、`effect`）。两者由同一次 Planner 结果投影，数量与顺序一一对应。
- 实际写入仍由现有执行后端完成，尚未改成逐条消费 `ir_steps`；接管（`adopt`）路径也仍然存在。移除旧执行路径、独占接管与让执行器只消费 IR 计划属于后续任务（见 #43）。
- 唯一的 Scoop 状态格式知识保留在 Adapter；核心执行代码不再读取 Scoop 字段决定行为。旧的 `Package` 记录只作为执行投影与迁移期载体。

## 只读保证

- 安装事实只读取 `apps/<包>/current` 的保存 Manifest 与安装记录；记录缺失、过期或损坏时仍报告已知事实，并把私有记录问题作为独立诊断。
- 查询不联网、不启动 PowerShell；`info` 的校验只读取 Manifest 字节并计算其 SHA256。
- 预览不写安装状态、不下载产物、不执行脚本。`tests/ir-pipeline.ps1` 用 `process_guard` 观测子进程，并在命令前后对测试根做文件摘要对比；`tests/real-scoop-readonly.ps1` 对本机真实 Scoop 根做同样核对。

## 能力与缺口表达

IR 的 `capabilities` 记录包所需的产品能力与当前是否可用，例如原生下载、ZIP/7z/tar 解压、Windows Installer、安装器进程、生命周期 Hook、命令入口宿主、开始菜单快捷方式、用户级环境持久化。缺失能力只作为明确的缺口报告（例如 MSI 的 `msiexec` 机器缓存、`post_uninstall` 阶段、用户级 PATH 持久化），不作为“包不存在”或“整个包无效”的理由。

## 验证与证据

- `tests/ir-pipeline.ps1`（CTest 名称 `ir_pipeline`）：无私有记录的安装事实、过期/损坏私有记录、IR 操作与效果、摘要算法缺口、MSI 能力缺口、查询/预览无副作用与无子进程。
- `tests/real-scoop-readonly.ps1`：对本机真实 Scoop 根执行 `list`、`info`、`update --dry-run`、`uninstall --dry-run`，核对安装清单与预览结论，并证明根内文件未改变、未创建 `.coop`。
- 本轮真实安装基线、环境与复现命令见 [真实 Scoop 安装基线](real-scoop-baseline.md)。

## 尚未完成

执行后端逐条消费 IR 计划、用户级环境与快捷方式的真实效果、真实脚本与安装器机制、Main/Extras 全量覆盖、双向交替管理与完整交付验收仍分别由后续任务跟踪；本轮只交付只读查询与预览的 IR 路径及其证据。
