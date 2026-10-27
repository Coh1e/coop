# CLI 路径、退出码与批量边界

本文件记录 #39（R18）完成的命令行边界：中文、空格和复杂 Windows 路径可以执行，标准输出、标准错误与退出码可区分，批量操作逐包报告结果，系统级安装根保持只读。正式产品范围见 [Issue #21](https://github.com/Coh1e/coop/issues/21)，整体模块边界见[包管理 IR 与查询/预览路径](ir-pipeline.md)。

## 1. 命令形式与退出码

`--root`、`--global-root`、`--arch` 同时接受分离形式和等号形式：

```powershell
coop --root "D:\some root" list --json
coop --root="D:\some root" list --json
coop --arch=64bit install main/ripgrep
```

退出码固定为：

| 退出码 | 含义 | 例子 |
| --- | --- | --- |
| 0 | 命令完成；批量中每个包都是 `success` 或 `skipped` | 全部成功的安装/卸载批次 |
| 1 | 操作失败，或批量中至少一个包 `failed`/`blocked`/`partial` | 未知包、校验失败、被只读系统级根拒绝 |
| 2 | 命令行用法错误，未开始包操作 | 未知命令、缺少选项值、未知选项、空根路径、无效 `--arch`、缺少包名 |

用法错误只写标准错误，不写标准输出；包操作的正常结果写标准输出，诊断写标准错误。`--json` 结果始终写标准输出。

## 2. 根路径归一化

`--root`/`--global-root` 在进入命令前被归一化：

- 相对路径按当前目录解析为绝对路径；`.`、`..`、重复分隔符和正反斜杠都折叠；
- 末尾分隔符被去掉（盘符根 `C:\` 保留）；
- 空值或纯空白被拒绝为用法错误（退出码 2）；
- 显式 `\\?\` / `\\.\` 路径原样保留，不再二次归一化；
- 绝对路径达到 240 个字符时自动转换为扩展长度形式（盘符路径加 `\\?\`，UNC 路径转 `\\?\UNC\`），使 `<根>\apps\<包>\<版本>\...`、`cache`、`shims` 和持久化目录整体避开 `MAX_PATH`。低于 240 字符的根仍使用普通形式，此时派生出的 apps/缓存路径仍可能超过 `MAX_PATH`（例如 239 字符根会先失败）；本版的自动转换阈值是根长度，而不是根据实际派生路径预算判断，这是已知边界。JSON 与诊断中的 `root`、`directory` 等字段显示实际使用的扩展形式；
- `canonical()`/`weakly_canonical()` 在长路径上会返回不带前缀的拼写。内部改用 `operating_path()` 重新加回扩展前缀，避免安装后 `current`、入口和旧版本证据在后续命令中重新遇到 `MAX_PATH`；
- 长根下的 junction 在 reparse point 内保存普通盘符/UNC 目标，NT 命名空间 `\??\` 自身不受 `MAX_PATH` 限制；把 `\\?\` 目标原样写入会生成无法解析的链接。

已知边界：扩展前缀加在**根**上，因此由根派生的长路径（包目录、缓存、入口、持久化）都得到覆盖；但一个短根下由 Manifest 声明得极深的 `extract_dir`/`extract_to` 仍可能独立超过 `MAX_PATH`，本轮没有把它冒充为已支持。UNC 源路径会按上述规则归一化，本轮没有在真实网络共享上执行安装证据。

## 3. Unicode、空格与输出编码

- 包名、bucket 名、入口名、`bin` 别名和根路径中的中文、空格及 `#`、`&`、`%`、方括号、圆括号等普通路径字符按 UTF-8/宽字符传递；不会按包名或词法改写。
- 标准输出与标准错误固定写 UTF-8。连接到真实控制台时，Coop 在进程内临时把控制台输出代码页切到 UTF-8，退出前刷新缓冲并恢复原代码页；重定向到管道或文件时字节保持 UTF-8，不随系统 ANSI 代码页变化。
- PowerShell 7 在输出被重定向时会用当前 `[Console]::OutputEncoding` 解码子进程输出。读取 Coop JSON 的脚本应显式设置 `[Console]::OutputEncoding = [Text.Encoding]::UTF8`（`tests/path-batch.ps1` 已这样做），否则系统 ANSI 代码页会把 UTF-8 字节显示成乱码；这不是 Coop 输出了另一种编码。
- 命令入口的参数转发沿用现有 Windows 命令行引用规则；本票只验证复杂路径与入口运行，不改变入口宿主语义。

## 4. 批量结果

`install|update|uninstall|reset` 一次接收多个包时，每个包独立规划、独立事务、按请求顺序执行：

- JSON 结果是数组，每项包含 `package`、`action`、`status`、`reason`（失败时）、该包的 `plan`（预览）或 `result`（执行）；执行项还带 `transaction_scope: per-package...`，不声称跨包全局事务或回滚。
- `status` 为 `success`、`skipped`（已安装依赖等明确跳过）、`failed`、`blocked`（预览无法执行）或 `partial`（如部分持久化数据删除失败）。
- 前面的包成功不会阻止后面的包继续；后面的包失败不会回滚已完成的包。任一项失败时总体退出码为 1。
- 文本模式每个包一行 `<包>: <status>`，失败原因写标准错误，最后一行给出总体计数，例如 `2 package(s): 1 succeeded, 0 skipped, 1 failed`。
- 批量 `--dry-run` 不写安装状态；某项无法规划时该项为 `blocked`，整体退出码为 1。

## 5. 系统级根只读

`--global-root`（或默认发现的系统级根）只作为安装事实来源：

- `list --json` 的系统级项带 `"scope": "global"` 与 `"read_only": true`；查询、`info` 和预览可读取它们。
- 仅存在于系统级根的包，`update`、`uninstall`、`reset` 在执行前被拒绝，错误包含稳定标记 `global-scope-readonly` 并给出该根路径；不会写入系统级根，也不会创建当前用户的 `.coop`。
- 对这类包执行当前用户级 `install` 仍是合法的用户范围写入：计划与结果带 `global_installation: {scope: global, read_only: true, directory: ...}`，安装只写当前用户根，系统级根保持逐字节不变。之后 `list` 仍同时显示两个范围，用户级卸载只影响用户级安装。
- 批量卸载同时包含用户级包与仅系统级包时，用户级项可成功、系统级项以 `global-scope-readonly` 失败，整体退出码为 1，系统级根不变。
- 没有 `--global` 写入开关；默认系统级软件管理仍不在产品范围内。

## 6. 验证

测试入口：`tests/path-batch.ps1`（CTest 名称 `path_batch`），使用真实 CLI 和项目内测试根，覆盖：

- 退出码 0/1/2、标准输出与标准错误分离；
- 中文、空格、`#`、`&`、`%`、括号路径的 `--root=` 初始化、末尾分隔符、`.`/`..`、正斜杠、相对根、显式 `\\?\` 根；
- 中文 bucket、包、可执行文件和带空格别名从安装、运行到卸载；
- 317 字符根（`init`、安装、逐文件摘要核对、入口真实运行、卸载）自动使用扩展长度路径；入口运行使用 Windows `CreateProcessW` 直接传扩展路径，因为 .NET 的进程启动在系统未启用长路径时仍拒绝该路径；
- 成功、部分失败、文本汇总、dry-run 与混合系统级项的批量结果；
- 系统级根只读拒绝、用户级并存安装，以及操作前后系统级根逐文件摘要快照一致。

本轮证据（运行时、静态检查与历史结果分开标注）：

| 项目 | 值 |
| --- | --- |
| 代码基线 | 本票提交 `HEAD`（报告与 Issue 评论记录完整 SHA） |
| 平台 | Windows 11 Pro N for Workstations 10.0.26300 build 26300，x64 |
| 工具 | Coop 0.1.0；MSVC 14.51.36231；CMake 4.4.4；Ninja；PowerShell 7.6.5（测试宿主），Windows PowerShell 5.1.26100.9711（外层） |
| 构建 | `scripts/build.ps1 -Action build`，退出码 0（本轮运行；最终代码构建见 `build-07.log`） |
| 定向测试 | `pwsh -File tests/path-batch.ps1 -CoopExe .local/build/coop.exe -TestRoot ".local/tests/path-batch 中文 space"`，退出码 0，`PASS CLI path boundaries, exit codes, long roots and per-package batch outcomes`（本轮运行；中间失败与修复见同目录编号日志） |
| 完整 CTest | `scripts/build.ps1 -Action test`，40/40 通过，`path_batch` 6.26 s（本轮运行，代码提交 6059c71；后续 `main.cpp` 控制台诊断修复由定向测试覆盖） |
| 真实 Scoop 根 | 本票未在真实 Scoop 根执行写入；只读/写入路径由项目内真实 CLI 测试与既有真实根证据覆盖（未运行项） |

证据文件（项目内、被忽略）：

- `.local/pi/tasks/39/evidence/build-07.log`：最终代码构建（此前 `build-01` 至 `build-06` 为编译失败与中间修复记录）；
- `.local/pi/tasks/39/evidence/path-batch-10.*.log`：定向测试全绿（`path-batch-01` 至 `-09` 保留每轮失败/修复证据，未覆盖改写）；
- `.local/pi/tasks/39/evidence/build-tests-02.log`：完整 CTest 40/40（代码提交 6059c71）；
- `.local/pi/tasks/39/evidence/ctest-final-302f520.log`：最终代码提交 `302f520` 上的定向 `cli` 与 `path_batch` 复测；文档提交后的同一代码复测见 `ctest-final-f59085d.log` 及报告记录的最终提交日志；
- `.local/pi/tasks/39/evidence/environment.json`：平台、工具、基线与 Coop 版本。

## 7. 未覆盖与后续

- 真实网络共享（UNC）上的安装/更新尚未执行；代码会归一化 UNC 并转换为 `\\?\UNC\`，但没有本轮运行证据。
- 短根下由 Manifest 独立声明的超长解压路径仍受 `MAX_PATH` 限制；要覆盖它需要在路径构造层统一转换，不属于本票已证明范围。
- 系统级根仍无写入或提权路径；需要系统级管理时必须另开规格与人类授权。
- 本票只调整 CLI 边界、路径转换与批量/只读报告，不改变入口宿主、脚本上下文或安装器机制；这些行为由各自既有证据覆盖。
