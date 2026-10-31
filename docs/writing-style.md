# 写作标准

本文件规定 Coop 两类文本的写法：**机器读文本**与**人类读文本**。目标是让机器读的文本可预测、让人读的文本不产生歧义，而不是把所有文字改成同一种风格。规则参考 ASD-STE100（简化技术英语）的“一个词一个意思、一句一个指令、主动语态”，但只在适用处使用。

## 两类文本

**机器读文本**：由程序按精确内容或形状读取的文本。包括 `--json` 键与状态值、稳定 kebab-case 码、退出码、CLI 文本模式下与 Scoop 同形的行、`.coop/` 运行记录与事务日志字段、`coop <版本>` 版本行、`ir_operations` 名称、发布资产名。

**人类读文本**：README、`docs/`、`GLOSSARY.md`、源码注释、Issue 与提交说明。

## 冻结清单

以下文本是契约，不得为了“更好读”改措辞。改它们属于接口变更，必须同时改文档、测试与调用方，并按 ADR 评审。

1. CLI 文本模式的 Scoop 0.6.0 同形输出：`Installed apps:`、`Results from local buckets...`、表头与列宽、`WARN  ` 前缀、`info` 键值块、`Everything is ok!`、`Usage: coop ...`、`Command`/`Summary` 表。
2. 写命令进度行与 `OK.`/`Done.`、`Timings` 块、stall 行、`purge`/`persist`/`suggest`/`notes` 行；这些行同时是 `.coop/runs/*.json` 的 `stage` 值。
3. `--json` 键、稳定码、IR 操作名、状态值、退出码 0/1/2。
4. `.coop/` 下运行记录、计时、事务日志、包记录的字段名与值。
5. `coop <x.y.z>` 版本行、release 资产名、workflow 的 `GITHUB_OUTPUT` 键。
6. `assets/scoop-lib/**`：上游逐字节副本，任何改动都是错误。

## 新增机器读文本

- **一个概念一个词**。用下表；不要用 “add/upgrade/remove/delete” 指代 install/update/uninstall。
- **一句一个指令**，主动语态，现在时。避免 “please”、“sorry”、“note that”、“in order to”。
- **稳定码**：小写 kebab-case，发布后不复用、不改名；码说明“哪一类失败”，消息说明“这一次失败”。
- **错误消息**：先写失败对象与动作，再写稳定码，最后写可执行的下一步；不要只写“failed”。
- **可预测句式**：`<对象>: <动作/状态>`（如 `pkg: up-to-date`）；不要为同一状态写多种句子。
- **数字带单位**，时间用秒，大小用 `human_bytes` 的既有输出。
- **不要加尾随空格或额外标点**，除非冻结清单里的 Scoop 同形行本来就有。
- 新文本必须先有测试（`# Red when:`），再写措辞；没有测试的文本不算机器契约。

## 人类读文本

- 中文短句，一句一个指令；条件写在指令前（“如果 X，则做 Y”）。
- 使用 `GLOSSARY.md` 的术语；不要在同一篇里混用同义词。
- 标题用名词短语；列表项以动词或名词开头，保持平行。
- 不写没有出处的数字；数值必须给出产生它的命令与脚本路径，并注明“本轮运行”或“历史结果”。
- README 的结构固定为：一句话定位 → 安装 → 构建与测试 → 常用命令 → 能力边界 → 文档索引。细节放 `docs/` 并链接，不在 README 重复。

## 术语

| 概念 | 使用 | 不要使用 |
|---|---|---|
| 安装软件 | install | add、setup |
| 更新软件 | update | upgrade |
| 卸载软件 | uninstall | remove、delete |
| 重置到本机版本 | reset | rollback（回退另有所指） |
| 只读预览 | preview / `--dry-run` | simulate、dry run |
| 共用安装根 | root | prefix（`prefix` 是命令名） |
| 包来源 | bucket | repo、repository |
| 命令入口 | shim / command entry | link、wrapper（按语境） |
| 生命周期脚本 | Hook | script（`installer.script` 除外） |
| 持久化数据 | persist / persistent data | user data |

## 执行

- 修改冻结清单内的文本：按接口变更处理，不按文字润色处理。
- 修改人类读文本：按本文件直接改；审查只检查术语、句子长度与数字出处。
- 本文件不新增自动检查；冻结面由测试守护，写作规则由审查执行。
