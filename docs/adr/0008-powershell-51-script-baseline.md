# 以 Windows PowerShell 5.1 为脚本与测试基线

测试与构建脚本长期以 PowerShell 7 为参照；[#91](https://github.com/Coh1e/coop/issues/91) 把 79 个 CTest 迁移到 Windows PowerShell 5.1。5.1 是每台受支持 Windows 自带的版本，但语义不同：原生命令写 stderr 在 `$ErrorActionPreference='Stop'` 下会成为终止错误；`-AsHashtable`、`ForEach-Object -Parallel`、`[IO.Compression.ZipArchive]`、长路径等需要额外处理。2026-10-31 人类决定“必须迁移 5.1”。

因此基线固定为：Windows PowerShell 5.1 是脚本与测试的必需运行器；CI 通过 `powershell.exe` 跑完整套件；`pwsh 7` 仍可用，但不是验收门禁。所有 `scripts/*.ps1` 与 `tests/*.ps1` 必须能在 5.1 解析并运行；只依赖 PS7/.NET Core 的手动工具（`acceptance-matrix.ps1`、`perf-compare.ps1`、部分 `real-scoop-*`）要么移植，要么在文档中明确标注“仅 pwsh 7”，且不得进入 CI 门禁。

## Rules

- 原生命令的成败只看 `$LASTEXITCODE`，不看 stderr。
- 捕获子进程的 stdout/stderr 用 `tests/invoke-coop.ps1`，不要直接 `2>&1`。
- 含非 ASCII 的 `.ps1` 用 UTF-8 BOM；5.1 会把无 BOM 的脚本按 ANSI 解析。
- 不使用三元运算符、空合并等 7-only 语法；需要程序集时显式 `Add-Type -AssemblyName`。
- 超长路径用 `\\?\` 前缀；不要依赖系统已启用 `LongPathsEnabled`。

## Consequences

- 迁移成本是 `tests/invoke-coop.ps1` 与 86 个文件的兼容改动；这些是基线成本，不是临时补丁。
- 5.1 下无法覆盖的 OS 能力缺口必须以 `SKIP: <原因>` 显式报告并记入覆盖率，不得静默跳过。
- Windows 未来版本若移除 5.1，本 ADR 需重审。
