# 读命令的文本输出

2026-10-29 建立。`list`、`search`、`info` 默认（不带 `--json`）的输出对齐 Scoop 0.6.0 的形状；`--json` 不变，仍是机读契约。本文件记录形状、刻意偏离与未覆盖项。

## 形状

`list`：

```
Installed apps:

Name            Version  Source Updated             Info
----            -------  ------ -------             ----
7zip            26.05    main   2026-10-28 12:22:31
```

- 列宽取表头与该列最宽单元格，列间一个空格，最后一列同样补齐。
- `Info` 只在异常时非空：`Global install`、`Held package`、`Deprecated package`、`Install failed`、非默认架构；待恢复事务不占用这一列，改为表格后的 `WARN` 行。
- `list [query]`：表头变成 `Installed apps matching '<query>':`。只有**没有任何已装软件**时才打 `WARN  There aren't any apps installed.`；查询无匹配时保留表头、不打印数据行。
- `Updated` 取 `scoop-install.json`（旧名 `install.json`）的写入时间，格式 `YYYY-MM-DD HH:MM:SS`。

`search`：

```
Results from local buckets...

Name    Version Source Binaries
----    ------- ------ --------
ripgrep 15.2.0  main   rg.exe
```

- 无匹配只打 `WARN  No matches found.`，不打印表头。
- 不带查询时列出全部本地清单。

`info`：

```
Name        : uv
Description : An extremely fast Python package installer and resolver, written in Rust.
Version     : 0.13.6
Source      : main
Website     : https://docs.astral.sh/uv
License     : Apache-2.0|MIT
Installed   : 0.13.6
Binaries    : uv.exe | uvx.exe | uvw.exe
Environment : UV_CACHE_DIR = $persist_dir\cache
              UV_PYTHON_BIN_DIR = $persist_dir\python\shims
Notes       : Scoop persists data since version 0.11.16. ...
              After : '<root>'
```

- 键列宽 = 最长键 + 1，后接 `: `；多行值续行按同一列宽缩进。
- `Version` 在已装版本与清单不同时显示 `<已装> (Update to <清单> available)`。
- `Website` 去掉 homepage 尾部 `/`。
- `Installed` 逐行列出本机版本目录。
- 非 verbose 下 `$dir`、`$original_dir`、`$persist_dir` 一律显示为 `<root>`；`Environment` 块只替换 `$dir`，`$persist_dir` 原样保留——Scoop 自己的 `installer.script` 只替换 `$dir`，照抄它的结果。

## 进入 `--json` 的字段

`management`、`scope`、`synced_at`、`status`、`last_operation`、`recovery`、`diagnostics`、`older_versions`、`validation` 只保留在 `--json`。文本不再解释"有没有 Coop 私有记录"、"bucket 上次同步时间"或"上次操作"。

## 刻意偏离

每条都要能被推翻或改成对齐，改的时候一并改这里的记录。

1. **空结果退出码 0**：`list` 空表、`search` 无匹配在 Scoop 里退出 1。Coop 保持自己的 CLI 契约（1 = 操作失败），空表不是失败。要改必须同时改 [CLI 路径、退出码与批量边界](cli-boundaries.md)。
2. **`list [query]` 用大小写不敏感子串**，Scoop 用正则 `-match`。
3. **`Updated` 的时间格式固定为 `YYYY-MM-DD HH:MM:SS`**；Scoop 走宿主区域性格式化，同一台机器上可能显示 `2026/10/28`。
4. **`search` 的匹配范围是包名 + 描述**；Scoop 匹配包名 + bin 名，且支持正则。因此 `coop search ripgrep` 会多列 `igrep`、`repgrep`。
5. **`info` 缺 `Updated at` / `Updated by`**：Scoop 从 bucket 的 git log 取 `%aI#%an`，只有非 git 树才退回文件时间 + 所有者。Coop 两条都没打印，避免给出与 Scoop 不同源的时间。
6. **`info` 缺 `-v/--verbose`** 对应的 `Manifest`、`Installed size`、`Download size`。
7. **尾随空行**：Scoop 的表格结尾多一个空行，Coop 不打。
8. **`status` 的更新判定是"清单版本 ≠ 已装版本"**，Scoop 用 `Compare-Version` 排序。Coop 的 `update` 本来以"版本不同"为触发条件，`status` 用同一谓词，避免出现 `status` 说最新而 `update` 仍然动作；代价是清单版本回退时也会列为可更新。
9. **`which` 未找到退出 1**（Scoop 退出 2），消息与 Scoop 相同。理由同偏离 1：2 在 Coop 的契约里是用法错误。
10. **`cat` 原样输出存储的清单字节**；Scoop 会 pretty-print，并因此丢失声明顺序。
11. **`status` 默认即本地**，接受 `-l`/`--local` 但不改变行为（Coop 从不在这里 fetch）。

## 检查类读命令

`status`：

```
Name  Installed Version  Latest Version  Missing Dependencies  Info
----  -----------------  --------------  --------------------  ----
demo  1.7.1              1.8.2
```

只列异常项（有更新、缺依赖、Install failed、Deprecated、Manifest removed）；全部正常时只打 `Everything is ok!`。`--json` 给同样的字段。

`prefix <包>`：打印 `<根>\apps\<包>\current`（与 Scoop 相同，不解析成版本目录）。

`cat <包>`：打印清单原文。

`which <命令>`：读 `<根>\shims\<命令>.shim` 的 `path = "..."`，打印它的目标（profile 前缀缩成 `~\`）；脚本包装没有 `.shim` 时打印包装文件本身；都没有时打 Scoop 的 WARN 并退出 1。

`home <包>`：打开清单声明的 homepage；没有 homepage 时报错而不是打开空 URL。

`depends <包>`：输出 `Source / Name` 两列，依赖在前、被请求的包自己在最后一行——与 `scoop depends` 逐行相同。`depends` 支持字符串与数组两种声明写法。

`export`：输出 scoopfile JSON，`buckets` 每项 `Name/Source/Manifests`、`apps` 每项 `Name/Version/Source/Info`，字段名与 `scoop import` 读取的一致。

`checkup`：只检查 Coop 自己的不变量——长路径开关、`main` bucket 是否存在、已注册 bucket 的目录是否存在、pending 事务、shim 指向的目标是否存在。有问题逐条 `WARN`，结尾 `Found N potential problem(s).` 或 `No problems identified!`，退出码始终 0。

`help [命令]`：命令名、用法串与摘要取自 Scoop 0.6.0 的 help 头，未实现的命令显式标注 `(not implemented yet)` 并在 `coop help <未实现命令>` 时退出 1。`coop <命令> --help` 打印同一段文本。

### 这三条的偏离

12. **`export` 不含 `Updated` 与配置项**：Scoop 会写 `Updated`（bucket 的 git 提交时间或目录时间）并可用 `-c` 导出配置。Coop 先不写这两项，`scoop import` 不读它们。
13. **`checkup` 的检查项是 Coop 的不变量**，不含 Scoop 的 Defender 排除项、7-Zip/innounp/dark helper、NTFS 卷检查。那些项目要么越过包管理器该做的事，要么与 Coop 的核心不依赖外部 helper 这一事实不符。
14. **`help` 对未实现命令返回 1**，Scoop 对所有命令都返回 0。Coop 用这个退出码表达"这个命令还不存在"。



## 证据

| 项 | 结果 | 位置 |
| --- | --- | --- |
| 真实根形状对照 | `coop list` 与 `scoop list` 在 `C:\Users\Neo\scoop` 上逐行相同（16 个包，2026-10-29 本轮运行） | 本机真实根，只读 |
| `info` 对照 | `coop info main/uv` 与 `scoop info uv` 逐行相同，仅少偏离 5 的两行 | 同上 |
| 自动测试 | `tests/query-text.ps1`（CTest `query_text`）；文件头 `# Red when:` 声明形状变化会让它红 | `ctest --test-dir .local/build -R '^query_text$'` |
| 红绿验证 | 2026-10-29 把 `Installed apps:` 改成 `Installed apps!:` 重构建后测试变红，还原后转绿 | 本轮运行，见提交前日志 |
| 裸 `search` 耗时 | 1707 份清单 0.28 s（本轮运行；`& .\.local\build\coop.exe search` 由 `Measure-Object -Line` 计时；每条命中都读一次 Manifest 取 bin 名） | 本机真实根 |

## 未覆盖

- 空表退出码与 Scoop 的差异（偏离 1）没有测试守护。
- `record_time` 转本地时间，结果随时区变化；没有跨时区证据。
- 非 ASCII 包名的列宽按码点计算，未在真实中文包名上验证。
- `info` 的 `Shortcuts`、`Path Added`、`Environment` 只在 `main/uv` 这一个真实样本上核对过。
