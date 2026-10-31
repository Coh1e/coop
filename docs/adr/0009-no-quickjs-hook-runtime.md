# 不把 scoop-lib 换成 QuickJS

2026-10-31 人类要求评估用 QuickJS 替代 `assets/scoop-lib/`。它是 Scoop v0.6.0 的逐字节 PowerShell 副本（16 个文件、5,491 行、193 KiB），由生成的宿主脚本 dot-source，再执行 Manifest 里的 PowerShell Hook 文本。真实 Main/Extras 的 4,149 份 Manifest 中 1,303 份带 Hook；其中 55.9% 含 `.NET` 字面量、COM、哈希表、`$_`、反引号、控制流等必须真 PowerShell 前端的构造，24.6% 依赖管道，只有 19.6% 接近可直接翻译。QuickJS 只提供 JS 引擎，不提供文件系统、进程、HTTP、哈希、归档、注册表、快捷方式或 COM/.NET 绑定。

因此保留 `assets/scoop-lib/`，不引入 QuickJS 作为 Hook 运行时。Hook 是 PowerShell 源码，换引擎等于重写 PowerShell 语义与全部宿主绑定；这会破坏与 Scoop 的 Manifest 互操作（[ADR-0002](0002-share-scoop-state.md)），而现有方案只多 193 KiB，并复用每台 Windows 自带的 PowerShell。

## Considered Options

- **QuickJS + PowerShell 子集解释器**：需要自带解析器、参数绑定、管道、`$_`、比较运算符、反引号、`$()`、splatting、控制流，以及 `.NET`/COM 桥。真实脚本中 55.9% 需要这类前端，成本与覆盖率都不受控。
- **改写 Manifest 为 JS**：直接放弃与 Scoop 共用 Manifest 生态，违反 [ADR-0002](0002-share-scoop-state.md)。
- **保留 PowerShell，只去掉 `scoop-lib` 副本**：会跟随根内任意 Scoop 版本的 helper 语义，失去可复现基线。

## Revisit

若目标改为“去掉 Coop 自有工具层的 PowerShell”或“减少每次 Hook 的一次子进程启动”，应另立 ADR；后者需要进程内 PowerShell 宿主，而不是 QuickJS。若坚持 PS 子集解释器，验收必须按真实 Manifest 通过率给出明确覆盖目标，而不是按库文件行数。

## Consequences

- PowerShell 仍是产品运行时依赖；缺少 PowerShell 时，Coop 在执行 Hook 前诊断并以稳定原因失败。
- 运行时依赖需在 README、`THIRD_PARTY.md` 与 `docs/script-support.md` 中保持一致表述。
