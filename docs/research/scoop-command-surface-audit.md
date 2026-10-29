# Scoop 命令面与 Coop 的差距盘点

2026-10-29 建立。目的：回答"Coop 还有多少操作没对标 Scoop"，为 CLI 表面票提供完整分母。本文件只记录**命令面**——有哪些命令、接受哪些参数、退出码与错误措辞；单个命令的行为兼容另见各专项文档。术语见 [GLOSSARY.md](../../GLOSSARY.md)。

## 基准与方法

- **Scoop v0.6.0**，`<SCOOP_SRC> = C:\Users\Neo\scoop\apps\scoop\current`。命令集合取自 `libexec\scoop-*.ps1`（28 个）；用法与选项取自每个文件的 `# Usage:` 与 `#   -` 头注释；裸 `update` 的行为取自 `libexec\scoop-update.ps1:397`（无参数分支）、`:77`（`Updating Scoop...`）、`:159`（`Updating Buckets...`）。
- **Coop 0.1.0**，命令集合取自 `.local/build/coop.exe --help` 与 [src/main.cpp:115-143](../src/main.cpp)；接受参数取自 `src/*.cpp` 的 `UsageError` 全集（`plan.cpp:1023-1037`、`query.cpp:309-312`、`main.cpp:101`、`bucket.cpp:81-85`）。
- **文本形状**取自真机同根对照：`scoop list`、`scoop info ripgrep`、`scoop status -l`、`scoop search ripgrep` 对照 `coop list`、`coop info main/ripgrep`、`coop search ripgrep`。
- 全部只读：本盘点没有执行任何安装、更新或卸载，没有改任何一条用户环境值和 `~\scoop` 下的文件。

## 结论

- Scoop 28 个命令，Coop 有 **9** 个（32%），缺 **19** 个。
- Coop 另有 **2** 个 Scoop 没有的命令：`init`、`recover`；以及 3 个 Scoop 没有的全局选项：`--json`、`--dry-run`、`--timings`。
- 9 个共有命令里，**没有一个**的参数集与 Scoop 一致。

## 表 A：命令级对照

### 已覆盖（9）

| Scoop | Scoop 的子命令/参数 | Coop | 差距 |
| --- | --- | --- | --- |
| `bucket` | `add` / `list` / `known` / `rm` | `add` / `list` / `remove` / `update` | 缺 `known`、缺 `rm` 别名；**多出 `update`**（Scoop 靠裸 `update` 刷 bucket） |
| `cleanup` | `<app>`、`*`、`-a`、`-g`、`-k/--cache` | `[package...]`，不带包名即全部 | 缺 `-a`、`-k/--cache`、`-g` |
| `info` | `<app>`、`-v/--verbose` | `[bucket/]package` | 缺 `-v`；文本只输出一行表，没有描述/站点/许可/binaries |
| `install` | `<app>`、`*`?、`-g`、`-i`、`-k`、`-s`、`-u`、`-a/--arch`、`app@version`、URL/本地清单 | `<package>...`、`--arch`、`--dry-run`、`--json` | 缺 `-i`、`-k`、`-s`、`-u`、`-g`、`app@version`、URL/清单路径 |
| `list` | `[query]` | 无参数 | **缺 `[query]`**：`coop list coop` 报 `list does not accept package arguments` |
| `reset` | `<app>`、`*`、`-a` | `<package>@<version>`、`--dry-run`、`--json` | 缺 `*`/`-a`；`@version` 为 Coop 扩展语义（只用本机已有版本） |
| `search` | `[query]`（不带查询=列出全部） | `<query>`（必须正好一个） | 缺"不带查询"；匹配范围是否含 bin 名未核对 |
| `uninstall` | `<app>`、`-g`、`-p/--purge` | `<package>...`、`--purge`、`--dry-run`、`--json` | 缺 `-p` 短选项、缺 `-g`；`--purge` 只接受一个包 |
| `update` | 裸=`更新 Scoop 自身 + 全部 bucket`、`*`、`-a`、`-f`、`-g`、`-i`、`-k`、`-s`、`-q`、`app@version` | `<package>...`、`--dry-run`、`--json` | **裸命令报用法错误**（退出 2）；缺 `*`、`-a`、`-f`、`-i`、`-k`、`-s`、`-q` |

### 未覆盖（19）

| Scoop | 用途 | 归组 |
| --- | --- | --- |
| `status` | 检查已装包是否有新版本；无差异时 `Everything is ok!` | 只读 |
| `help` `<command>` | 单命令帮助（`scoop <cmd> --help` 也走这里） | 只读 |
| `prefix` `<app>` | 打印包的版本目录 | 只读 |
| `which` `<command>` | 定位 shim/可执行文件 | 只读 |
| `cat` `<app>` | 打印 Manifest 原文 | 只读 |
| `home` `<app>` | 打开 homepage | 只读 |
| `depends` `<app>` | 按安装顺序列出依赖 | 只读 |
| `checkup` | 环境体检 | 只读（诊断） |
| `export` | 导出 scoopfile.json（`-c` 含配置） | 只读（输出） |
| `cache` | `show` / `rm [app...]` | 读写共用 cache |
| `download` | 只下载到 cache 并校验（`-f`/`-s`/`-u`/`-a`） | 读写共用 cache |
| `hold` | 禁止更新（`-g`） | 写安装记录 |
| `unhold` | 解除（`-g`） | 写安装记录 |
| `shim` | `add` / `rm` / `list` / `info` / `alter`（`-g`） | 写用户级对象 |
| `alias` | `add` / `rm` / `list`，生成自定义子命令 | 写用户级对象 |
| `config` | 读写 `~/.config/scoop/config.json` | 配置文件 |
| `create` `<url>` | 从 URL 生成自定义 Manifest | 生成清单 |
| `import` | 从 scoopfile 恢复 | 导入清单 |
| `virustotal` | 查哈希/URL 信誉（需 API key） | 外部服务 |

## 表 B：全局选项、退出码与措辞

| 项 | Scoop | Coop |
| --- | --- | --- |
| 全局开关 | `-h/-v`、每命令 `-g`、`-q`、`-u/--no-update-scoop` | `--root`、`--global-root`、`--arch`、`--dry-run`、`--json`、`--timings` |
| 无参数 | 显示帮助 | 显示帮助 |
| 未知命令 | `warn "scoop: 'x' isn't a scoop command. See 'scoop help'."`，退出 1 | `coop: unknown command; use --help`，退出 2 |
| 单命令帮助 | `scoop <cmd> --help` 有 | 无（只有 `--help` 全局） |
| 系统级范围 | `-g/--global` 是一等开关 | 只读：`-g/--global` 不作为写选项；`--global-root` 只读来源 |
| 版本写法 | `app@version`（含 install/download，可回溯历史） | 仅 `reset` 的 `app@version`（只用本机已有版本） |
| 清单来源 | URL、本地 json 路径、`bucket/app` | 只有 `bucket/app` 或裸包名 |

## 归类与成本判断

按"补这个命令要不要新状态模型"分组，这决定票怎么拆：

1. **纯读本地事实（9 个）**：`status`、`help`、`prefix`、`which`、`cat`、`home`、`depends`、`checkup`、`export`。底层数据（安装事实、Manifest、依赖图、入口、bucket 同步时间）都已在 IR/Planner/查询层存在，主要工作是命令壳与输出形状。
2. **读写共用 cache（2 个）**：`cache`、`download`。下载、校验、`<根>/cache` 布局都已有，缺的是把"只下载不安装"和"列出/删除缓存"暴露出来。
3. **写安装记录或用户级对象（4 个）**：`hold`、`unhold`（`install.json` 的 hold 字段，Scoop 的 `list`/`status` 会读）、`shim`、`alias`。需要新增写路径与归属证据。
4. **配置文件（1 个）**：`config`。Coop 目前没有自己的配置文件，也没有 `~/.config/scoop/config.json` 读写。
5. **生成/导入清单（2 个）**：`create`、`import`。`import` 是 `export` 的另一半，`create` 需要模板与网络。
6. **外部服务（1 个）**：`virustotal`。需要 API key、上传/查询与配置项，不建议进首版。
7. **已有命令的参数缺口（5 类）**：`list [query]`、`search` 无查询、`update` 裸/`*`/`-f`/`-a`/`-q`/`-k`/`-s`/`-i`、`install` 的 `-i`/`-k`/`-s`/`app@version`/URL、`cleanup` 的 `-a`/`-k`/`-g`。

## 结构性发现（不是"少一个命令"）

1. **`bucket update` 是 Coop 独有命令，Scoop 没有**。它的位置正好补上 Coop 缺失的裸 `scoop update` 的 bucket 那一半。后果：Scoop 用户的手指记忆 `scoop update` 在 Coop 上是退出码 2。
2. **`info` 是唯一"名字相同、价值不同"的命令**。Scoop 输出 11 行键值：

   ```
   Name        : ripgrep
   Description : Recursively searches directories for a regex pattern.
   Version     : 15.2.0
   Source      : main
   Website     : https://github.com/BurntSushi/ripgrep
   License     : MIT
   Updated at  : 2026/7/16 0:48:52
   Updated by  : github-actions[bot]
   Installed   : 15.2.0
   Binaries    : rg.exe
   Suggestions : extras/vcredist2022
   ```

   Coop 输出一行 9 列表，其中 `Management`/`Scope`/`Synced`/`Status`/`Last operation` 恒为 `unknown`；上面 11 项里，只有 name/description/homepage/version 在 `--json` 里，文本模式一个都没有。
3. **`search` 不带查询时 Scoop 列出全部可用包**，Coop 要求正好一个参数（`query.cpp:312`）。
4. **已定的产品边界没有以用户能读的方式表达**：`-g/--global` 是设计上不做系统级写，但按 `plan.cpp:1028-1036` 的解析顺序，`--global` 会落到 `Unknown package option`，`-g` 会被当成包名（据代码推断，未实跑）。用户读到的是"Coop 不认识这个开关"，不是"这个范围只读"。
5. **Scoop 的 `install`/`update`/`download` 默认在 Scoop 自身过期时先自更新**（`-u/--no-update-scoop` 可关）。Coop 无此环节——这是产品差异不是缺陷，但需要人类明确记入范围。

## 未核对

- `scoop uninstall *`：help 未列通配，未实测。
- `coop install pkg@version` 的实际行为：`plan.cpp:325` 解析了 `@version`，但设计文档说不从远端历史找版本；未实跑。
- `scoop search` 是否匹配 bin 名：help 说匹配 "app names and binaries"，未实测。
- `bucket known` 的来源清单（远端 `buckets.json`）：未读其实现。
- `scoop import` 的实际写入范围与失败回滚：未读实现。

## 复现

```powershell
# Scoop 命令集合与每个命令的用法/选项
Get-ChildItem 'C:\Users\Neo\scoop\apps\scoop\current\libexec\scoop-*.ps1' |
  ForEach-Object { Write-Host "### $($_.BaseName -replace '^scoop-','')"; Get-Content $_.FullName -TotalCount 14 }

# Coop 命令集合与所有用法错误（即接受的参数全集）
.local\build\coop.exe --help
Select-String -Path src\*.cpp -Pattern 'UsageError\("'

# 文本形状对照（只读）
scoop list; scoop info ripgrep; scoop status -l; scoop search ripgrep
.local\build\coop.exe list; .local\build\coop.exe info main/ripgrep; .local\build\coop.exe search ripgrep
```
