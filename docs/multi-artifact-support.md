# 多产物、架构与摘要算法支持

本文件记录 #25（R04）把多下载项、`#/` 文件重命名、架构覆盖和声明摘要算法贯通到 IR、预览与实际执行的实现与真机证据。产品目标与验收边界见 [正式规格 #21](https://github.com/Coh1e/coop/issues/21)，模块边界见 [包管理 IR 与查询/预览路径](ir-pipeline.md)。

## 实现范围

- **IR 保留声明语义。** 一个包可以声明多个下载项；`url` 的 `#/name` 片段产生实际本地文件名并标记 `renamed`；每个下载项分别保存算法与摘要值；`architecture` 段按所选架构解析，缺失或假值时按 Scoop 语义回退根字段。`extract_dir`/`extract_to` 只由归档类产物按顺序消费。
- **Validator 只接受能原生验证的算法。** SHA256（64 hex）、SHA512（128）、SHA1（40）和 MD5（32）继续进入 IR；未知算法或长度不匹配仍然产生分层的 `unsupported-hash`，不会悄悄按 SHA256 处理。缺失/数量不一致仍由 `artifact-hash-count` 报告。
- **Plan 与预览保留来源。** Planner 为每个下载项生成 `download`、`verify`、必要时 `extract`；效果文本包含实际文件名、来源 URL、`#/` 改名和声明算法。预览 `artifacts[]` 同时给出 `url`、`filename`、`renamed`、`algorithm`、`digest` 和组合后的 `hash`。`sha256` 兼容键只在真实 SHA256 产物上出现，避免把 SHA512 值误标成 SHA256。
- **执行使用声明算法。** 验证从 IR 读取算法与摘要，使用 Windows CNG 原生计算 SHA512/SHA1/MD5/SHA256，不再固定按 SHA256。下载与校验发生在移除旧入口、写新版本之前；失败时当前版本、入口和管理记录保持不变。
- **事务证据保留输入。** Journal 的 `artifacts` 记录每个下载项的 URL、本地文件名、改名标志、算法和声明摘要；`downloads` 记录实际字节数与观察到的摘要，便于把预览、执行和恢复证据逐一对应。
- **共用安装的直接文件证据可覆盖多个产物。** 无 Coop 私有记录的 Scoop 安装，只要全部产物都是非归档文件，就逐个核对实际文件名与声明的算法/摘要；任一文件缺失或被修改即拒绝管理。归档安装仍是解压后的目录树，尚无内容证据，继续明确拒绝更新/卸载。

## 真机证据

2026-10-26 在本机共用根 `C:\Users\Neo\scoop` 顺序执行，Scoop v0.6.0，Main 修订 `89b4cf8078b4968bca637b2ae226b16e8d04dbce`，Windows x64，代码提交见本轮报告。每条场景都由同一 Coop 二进制完成预览、安装、程序运行、Scoop 识别和卸载，并在结束时恢复起始安装集合。

| 场景 | 覆盖点 | 实际结果 |
| --- | --- | --- |
| Main/pdfbox 3.0.8 | 2 个下载项、两项 `#/` 改名、两项 SHA512、JAR 入口 | 预览与 journal 的 `download,verify,download,verify,publish-current,entries,commit-state` 完全一致；`pdfbox version` 输出 `pdfbox version [3.0.8]`；两个实际文件 SHA512 与声明一致；`scoop list pdfbox` 识别 3.0.8 |
| Main/tcping 0.39（`--arch 32bit`） | 架构专属 URL、`#/tcping.exe` 改名、SHA512 | 实际入口 PE machine `0x014c`，Coop 与标准 `scoop-install.json` 均为 `32bit`；程序打印 tcping 用法；`scoop reset tcping` 后入口仍可运行，Coop 仍识别并可卸载 |
| Main/astyle 3.6.20（`--arch 32bit`） | 架构专属 ZIP、`extract_dir`、SHA1 | 实际 `astyle.exe` PE machine `0x014c`，`astyle --version` 输出 `Artistic Style Version 3.6.20`，Scoop 识别 32bit |
| Main/thrift 0.25.0 | `#/thrift.exe` 改名、MD5 | 实际文件 MD5 与声明一致，`thrift --version` 输出 `Thrift version 0.25.0` |
| 临时 `coop-r04-failure/pdfboxcopy` | 真实多产物安装后的真实下载/校验失败保护 | 安装 3.0.8 后，目标 3.0.9 的错误 SHA512 使更新退出 1，journal 在 `download,verify` 后回滚，当前程序仍为 3.0.8；目标 3.1.0 指向缺失文件时下载失败退出 1，当前仍为 3.0.8，目标版本目录未出现；随后正常卸载并删除临时 bucket |

完整命令、退出码和原始日志位于本轮证据目录 `.local/pi/tasks/25/evidence/real-scoop-multi/`；汇总为 `real-scoop-multi-evidence.json`。运行前后 Coop 安装清单相同，新增的五个包均已卸载，未修改原 15 个安装。

## 测试

- `tests/multi-artifact.ps1`（CTest 名称 `multi_artifact`）：项目内测试根中使用真实 `file://` 产物，验证 32bit/64bit 架构选择、3 个下载项、`#/` 改名、SHA512/SHA1/MD5、预览与 journal 对应、更新保留旧版本；把第二个 SHA1 改为零或把 URL 指向缺失文件后，更新失败且当前程序/版本不变；恢复声明后仍能正常更新。
- `tests/ir-pipeline.ps1`：SHA512 包预览可执行且保留算法/改名；未知算法仍报告 `unsupported-hash`；`verify` 操作带声明算法。
- `tests/scoop-interop.ps1`：无 Coop 私有记录的多产物直接文件安装逐个核对两个产物和两个 Scoop `.shim` 后更新、运行两个程序并卸载；单文件、Scoop reset 和外部启动器拒绝路径继续覆盖。
- `tests/real-scoop-multi.ps1`：上述真机场景的可重运行脚本。它只选择运行前未安装的包；失败时在 finally 中尽力卸载本轮安装并删除临时 bucket。

## 未完成与边界

- 本文件只证明这些真实样本与机制路径，不构成 Main/Extras 完整分母、安装器、真实脚本、用户环境或全部入口类型的完成证明。
- 无 Coop 记录的共享归档布局仍不能核对解压树，更新/卸载会明确拒绝；共享多产物直接文件已有项目内真实 Scoop 布局夹具证据，真机证据目前集中在 Coop 创建的安装和单文件共享路径。
- SHA384、BLAKE 等未实现的算法继续作为能力缺口报告，不扩大为“已支持所有 `hash` 写法”。
- 下载/校验失败只保证 Coop 管理的当前版本不被替换；脚本、安装器或外部程序已产生的副作用仍按各自文档的恢复边界处理。
