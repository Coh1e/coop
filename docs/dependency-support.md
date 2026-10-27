# 依赖安装与反向依赖保护

本页记录 Coop 首版对 Scoop Manifest 显式 `depends` 的实际支持范围、批量结果语义和未验证项。行为依据固定提交 `e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f` 的 [`Get-Dependency`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/depends.ps1#L1-L77) 与本地真实样本，不把解析 Manifest 等同于完整兼容。

## IR 与计划权威

- Adapter 把 `depends` 的来源写法归一为 `ir::Dependency`：保留原始来源作为证据，同时分开 `name`、`bucket` 和 `version`。后续规划与执行不再重新解释字符串。
- `ir::resolve_dependencies` 在 Planner 内对归一化依赖图排序，输入是已校验的 Package IR 和共享安装事实。它负责顺序、循环、跨 bucket 歧义、来源冲突和已安装复用；不读取 Scoop JSON，也不写安装状态。
- Plan 携带完整的 `dependencies` 顺序。每个未安装依赖包含自己的 Package IR、IR 操作序列和预览可见的效果；已安装依赖标为 `satisfied`，没有安装操作。预览的 `dependency_order` 逐项给出该依赖的 `ir_operations`，请求包自己的操作仍在 `ir_operations`。
- 实际执行按同一个 Plan 的依赖顺序逐包执行；依赖包使用自己的 IR 操作序列和独立事务，随后才执行请求包。执行日志的 `observed_steps` 必须与该包预览的操作序列一致。依赖满足项只记为 `skipped/already-installed`，不会重新下载或覆盖。
- 依赖和请求包各自生成准备、发布、事务日志和恢复范围。多包操作不声称全局事务；后一个包失败不会回滚已经完成的包。

## 安装顺序与来源

- 只读取 Manifest 明确声明的 `depends`。不推断用户项目、脚本运行期或自定义命令的真实依赖，也不把 Coop 自身不依赖 Git/7-Zip 误认为软件包不需要它们。
- 依赖先于请求包安装；同一依赖只安装一次。已经安装的依赖记为 `skipped`，不会重新下载或覆盖。已安装事实来自共享 `apps/<包>/current`，不要求 Coop 私有记录。
- 依赖可写作 `name` 或 `bucket/name`。显式 bucket 必须能找到对应 Manifest；未限定 bucket 且本地多个 bucket 同名时，Coop 要求显式限定而不是静默选择第一个来源。依赖来源不需要是请求包所在的 bucket：`versions/python27` 与未限定、且只在 `versions` 中存在的 `python27` 都按同一归一化身份解析，顺序与已安装事实仍由 Planner 决定。
- 同一 Manifest 重复声明同一依赖时只保留一条相同的诊断；来源不同、被依赖方不同或循环链不同的诊断仍分别保留，不把不同问题合并成一条。
- 依赖已安装但记录的 bucket 与显式声明冲突时拒绝安装。
- 缺失依赖、循环依赖、同名跨 bucket 歧义、来源冲突和不可执行依赖都在写入前报告具体诊断。循环信息包含完整链，例如 `test/a -> test/b -> test/a`。
- 带版本的依赖写法（如 `base@1`）仍明确拒绝；首版不猜测版本约束的解析结果。
- `update` 和 `adopt` 不安装新依赖，只检查新 Manifest 或已安装 Manifest 声明的依赖确实已安装；缺失时拒绝。`adopt` 也不重新执行脚本或重新安装依赖。
- 普通卸载不删除依赖，即使它看起来已无人使用；首版没有 autoremove，也不会连带卸载反向依赖方。

## 跨 bucket 依赖来源（versions bucket）

官方 `versions` bucket 是 Main/Extras 之外的依赖来源，不是兼容分母的一部分。[`tests/coverage/dependency-sources.json`](../tests/coverage/dependency-sources.json) 固定它的来源与 40 位修订（`https://github.com/ScoopInstaller/Versions`，`8050ef41c72c2124b864692665ca62d34659b8bc`，`git ls-remote HEAD` 先核对，629 份 Manifest），并由 CTest `coverage_gaps` 守卫：名称/URL/修订/角色缺一、被移出分母说明或与缺口账本不一致都会失败。盘点脚本按该清单注册只读副本，`-SkipDependencySources` 才回到“未注册”的环境前提。

同一 Main 修订（`eebcee22…`）与 Extras 修订（`0f8f4b5f…`）下，带固定 `versions` 修订的盘点结果：

| 包 | 声明来源 | 解析结果 | 计划 |
| --- | --- | --- | --- |
| main/buck | `versions/python27` | versions/python27@2.7.18 | `execution_available=true`，依赖先于主包 |
| main/glslviewer | `versions/ffmpeg-shared-4.4.1` | versions/ffmpeg-shared-4.4.1@4.4.1 | 同上 |
| main/terraform-provider-ibm | `versions/terraform011` | versions/terraform011@0.11.15 | 同上 |
| extras/node-compiler | `versions/python27`（另有 `extras/squashfs-tools`） | versions/python27@2.7.18 → extras/squashfs-tools@43 | 同上 |
| extras/rabbitmqadmin | `python27`（未限定，只在 versions 中存在） | versions/python27@2.7.18 | 同上 |

盘点因此不再产生 `dependency-missing`：4149 份 Manifest 中计划可执行为 4141、阻塞 6（3 个 arm64-only 产物、3 个默认 PATH 无 `python.exe` 的环境前提），`dependency-missing` 为 0，与 [#49](https://github.com/Coh1e/coop/issues/49) 的验收一致。未注册 `versions` 的根仍会在写入前报 `ir/dependency-missing`（`tests/real-scoop-dependencies.ps1` 在共用根未注册 `versions` 时保留该断言）；这是环境前提，不是“不支持”。

真实共用根（`C:\Users\Neo\scoop`，Before：`main`、`nerd-fonts`，未注册 `versions`）顺序执行并全部还原：注册固定 `versions` 修订 → 5 个可用的 Main 样本 `install --dry-run` 均可执行且依赖在前 → 安装 `versions/terraform011`（真实下载、校验、ZIP 解压，`terraform --version` 输出 `Terraform v0.11.15`）→ `main/terraform-provider-ibm` 预览把该依赖标为 `installed=true`、`status=satisfied`、`ir_operations` 为空，`planned_dependencies` 只有主包 → 实际安装中依赖记为 `skipped/already-installed`、主包随后成功，事务日志 `observed_steps` 与预览 `ir_operations` 完全一致 → 卸载主包后依赖仍在且可运行（不自动连带删除）→ 卸载依赖并移除本轮注册。还原包含 Coop `bucket remove` 刻意保留的共享工作树（只用本测试克隆、先核对 origin 与 HEAD）、`.coop/buckets.json` 的逐字节还原，以及依赖安装器与 `terraform` 程序在 `%APPDATA%\terraform.d` 写入的测试新增文件；结束状态为原有 bucket 目录、注册记录、本地修改、15 个安装包和 `scoop bucket list` 与开始一致。`versions` 真实注册期间 Scoop 自身 `bucket list` 也看到了该 bucket（629 份 Manifest），不属于 Coop 私有记录。

回归用例 `tests/versions-bucket.ps1`（CTest `versions_bucket`）用项目内隔离根复现同一组身份形状：`versions/python27`、`versions/ffmpeg-shared-4.4.1`、`versions/terraform011`、未限定的 `python27`、跨 bucket 传递链、已安装依赖复用（`installed/satisfied`、记录不被重写、入口可运行）、另一 bucket 已安装同名依赖时的 `dependency-bucket-conflict`，以及缺少 `versions` 时的 `dependency-missing` 去重。真实共用根的一次性操作由 `tests/real-scoop-versions.ps1` 执行，它记录初始状态、命令与退出码，并在失败路径同样还原。

## 计划与执行结果

预览计划中的 `dependency_order` 按执行顺序列出依赖和请求包，`installed` 表示该依赖已满足，`status` 为 `satisfied` 或 `planned`；未安装项的 `ir_operations` 是该依赖自己的操作序列，已满足项为空。安装前仍会重查 Manifest 摘要与本地前置条件。

- 每个包使用独立的准备、发布、事务日志和恢复范围。多包操作不声称全局事务；后一个包失败不会回滚已经完成的包。
- 单包安装没有依赖时保持原有结果对象。单包安装带依赖时，结果为请求包的对象，并带 `packages` 数组逐包列出依赖和请求包。
- 一次传入多个包时，结果为数组，逐项给出 `package`、`action`、`status`（`success`、`skipped` 或 `failed`）、`reason` 和该包的 `result` 或 `plan`。成功项带 `transaction_scope: per-package`。
- 批量部分失败时，已完成项保留，总体退出码非零；预览中的 `blocked` 项也令总体退出码非零。
- 旧版本保留和持久化数据保留规则仍由各包自己的事务负责，批量结果不会把它们混为一次整体回滚。

## 反向依赖删除保护

- 卸载前读取所有已安装包保存的 Manifest，而不只是 Coop 已接管的包。保存的 Manifest 通过 IR Adapter 读取，依赖名称使用与正向规划相同的归一化身份；未接管安装同样参与保护。
- 管理记录也保存安装时的 `depends`，作为保存 Manifest 不可读时的后备证据。两者都不可读时，Coop 将依赖证据标为不完整并拒绝卸载；缺失证据不证明不存在依赖。
- 显式提供 `--global-root` 时，系统级安装的已知依赖也参与用户级卸载保护；系统级路径仍只读。
- 预览列出 `blocking_dependents` 与 `unverified_dependents`；实际卸载在写入前被阻止、返回非零，并在错误文本中说明第一个依赖方或无法读取证据的安装。
- 已知依赖方不会被自动卸载；移除依赖方后，目标包仍需用户显式卸载。只有普通卸载目标被删除，声明持久化数据和旧版本继续按各自规则保留。

## 验证边界

`tests/dependencies.ps1`（CTest `dependencies`）在项目内隔离根目录运行真实 CLI：

| 场景 | 观察结果 |
| --- | --- |
| 真实 Main/wget | 从真实 Manifest 读取 `depends: cacert`，预览按 cacert、wget 排序并分别给出 IR 操作序列，不写产品状态 |
| 依赖链安装 | 依赖先安装，请求包后安装；真实入口程序可运行；管理记录保存声明依赖；两个包的预览 `ir_operations` 与实际事务日志 `observed_steps` 一致 |
| 已安装依赖 | 预览标为 `installed/satisfied` 且无安装操作；执行标为 `skipped/already-installed`，命令入口保持可用 |
| 批量安装 | 逐包返回 success/failed；后续失败不删除先前成功安装的包；整体非零 |
| 缺失/循环/歧义/带版本依赖 | 写入前失败，并给出对应诊断与依赖链或来源 |
| 跨 bucket versions 来源 | 5 个真实包形状（含版本化名字与未限定 `python27`）解析为 versions 依赖、依赖先于主包；已安装依赖复用；同名异 bucket 冲突；缺 bucket 时去重诊断 |
| 更新前检查 | 依赖缺失时更新预览失败；恢复后依赖显示为已满足 |
| 反向依赖 | 已接管、未接管依赖方均阻止卸载；证据不可读也阻止卸载 |
| 无 autoremove | 卸载依赖方后共享依赖仍安装且可运行，直到显式卸载 |
| 批量卸载 | 成功项保留、失败项独立报告，整体非零 |

`tests/real-scoop-dependencies.ps1` 在同一本机真实 Scoop 根顺序运行：

| 场景 | 本轮观察结果 |
| --- | --- |
| 真实依赖复用 | 真实 Main/git-tfs 声明 `depends: git`；预览把已安装 git 标为 `satisfied` 且无安装操作，git-tfs 标为 `planned`；实际安装只新增 git-tfs，git 记为 `skipped/already-installed`，git-tfs 程序可运行，Coop 记录保存 `git` |
| 反向依赖保护 | Coop 安装的 git-tfs 使 `uninstall git` 在预览和实际执行中都被拒绝并列出 git-tfs；git 仍可运行，git-tfs 未被自动删除 |
| 不连带清理 | 显式卸载 git-tfs 后 git 仍保持安装且可运行，列表仍识别；不会因为看起来无人使用而自动删除依赖 |
| 真实缺失依赖 | 未注册 `versions` 的根上，Main/terraform-provider-ibm 的 `versions/terraform011` 在写入前报告 `dependency-missing` |
| 跨 bucket 依赖真实操作 | 本轮在共用根注册固定 `versions` 修订：`versions/terraform011` 真实安装并可运行，`main/terraform-provider-ibm` 复用该依赖（`installed=true`、`skipped/already-installed`）后安装成功，日志与预览一致；卸载主动、还原注册与用户目录新增文件 |

证据：项目内盘点结果在 `.local/pi/tasks/49/evidence/coverage-versions-final/coverage-20261027-054326/`（`summary.json`、`cross-bucket-dependencies.json`、`manifests.json`、`shared-root-before/after.txt`，退出 0）；真实共用根为 `.local/pi/tasks/49/evidence/real-root-20261027-final/real-scoop-versions-evidence.json`（退出 0），逐条命令日志与 `%APPDATA%` 清理记录同目录，被忽略、不随仓库分发。本轮代码提交 `ce49eff`，`coop.exe` SHA256 `20e8fdb…`。

证据只覆盖本轮实际执行的真机样本；完整 Main/Extras 覆盖仍由后续盘点与交付票跟踪。

未运行或未承诺：

- 依赖包自身的脚本、安装器和特殊归档组合（由脚本与安装器能力票覆盖）；快捷方式与环境声明已由 [复杂命令入口、快捷方式与环境暴露](exposure-support.md) 覆盖，依赖测试不重复这些场景。
- 带版本约束的依赖、远端历史版本和依赖升级策略；`update` 不会隐式更新依赖。
- 真实网络生命周期中的 Main/wget 安装；其脚本与远端产物仍受当前能力限制。
- 依赖方使用自定义脚本、动态运行期依赖或未写入 Manifest 的关系；Coop 不推断这些关系。
- 两个客户端同时写入同一状态；本项目只承诺先后交替使用。
