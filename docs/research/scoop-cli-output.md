# Scoop 0.6.0 写命令输出实录

2026-10-28 建立。目的：为 Coop 的输出契约提供可复核的 ground truth，取代此前根据源码推断措辞的做法。术语见 [GLOSSARY.md](../GLOSSARY.md) 的「进度反馈」。

本文件只记录**实际观察到**的输出。凡未观察到的，写在「未覆盖」里，不用记忆补足。

## 方法与限制

- Scoop 版本 v0.6.0（`scoop --version`，2026-09-30 发布），源码位置 `<SCOOP_SRC> = C:\Users\Neo\scoop\apps\scoop\current`。
- 安装根：`D:\Projects\coop\.local\scoop-capture2`（`$env:SCOOP`）。`$env:SCOOP_GLOBAL`、`$env:XDG_CONFIG_HOME` 同样指向 `.local` 下。没有写入 `C:\Users\Neo\scoop`。
- bucket：`.local\scoop-capture2\buckets\probe` 下的手写 Manifest，`url` 指向 `.local\deps\test-archives` 里的真实归档，`hash` 由 `Get-FileHash -Algorithm SHA256` 现场计算。因此**全程无网络下载**，`Downloading` 行显示 `file://` URL。
- 偏差：真实生态里 bucket 名是 `main`，这里是 `probe`；根路径在项目内。凡受此影响的行，在下面标注。
- 首次在新根上运行会出现初始化噪声（`Updating Scoop...`、`Adding ... to your path.`、`Updating Buckets...`、`INFO Converting 'main' bucket to git repo...`、`ERROR 'main' bucket not found.`）。正常根只在 `scoop update` 或首次安装时出现其中一部分。
- 首次录制用 `Tee-Object` 落盘，写出的是 UTF-16，回读为乱码；已改为 `Out-String` + UTF-8 重录。本文引用的是重录后的文本。
- PATH 影响：新根第一次安装会把 `<根>\shims` 追加到**用户 PATH**（见 `03` 之前的 `Adding ... to your path.`）。每次录制后都已把用户 PATH 恢复到录制前快照。
- 非 tar 归档需要根内有 7-Zip：`scoop install curl`（tar.xz）在未装 7zip 时以退出码 1 失败，输出 `Couldn't find manifest for '7zip'.`。因此先装了 7zip 再录 tar。

## 逐命令实录

标注：`<ESC>[36m … <ESC>[0m` 是输出里真实存在的控制字符（源码硬编码，见下），不是排版。行尾折行是控制台宽度造成的，不是 Scoop 主动换行。

### install（ZIP，无 extract_dir）

```
Installing 'ripgrep' (15.2.0) [64bit] from 'probe' bucket
Downloading file:///D:/Projects/coop/.local/deps/test-archives/ripgrep-15.2.0-x86_64-pc-windows-msvc.zip (1.7 MB)...
Checking hash of <ESC>[36mripgrep-15.2.0-x86_64-pc-windows-msvc.zip<ESC>[0m... 
OK.
Extracting <ESC>[36mripgrep-15.2.0-x86_64-pc-windows-msvc.zip<ESC>[0m... 
Done.
Linking D:\Projects\coop\.local\scoop-capture2\apps\ripgrep\current => D:\Projects\coop\.local\scoop-capture2\apps\ripgrep\15.2.0
Creating shim for 'rg'.
'ripgrep' (15.2.0) was installed successfully!
```

退出码 0。注意 `Checking hash of …... ` 与 `Extracting …... ` 两行以空格结尾，`OK.` 和 `Done.` 各自独占一行。

### install（同一包，已安装）

```
WARN  'ripgrep' (15.2.0) is already installed.
Use 'scoop update ripgrep' to install a new version.
```

退出码 **0**。Scoop 不重新安装、不读缓存、不做任何写操作。

### install（ZIP，带 extract_dir）

```
Installing 'tidy' (5.8.0) [64bit] from 'probe' bucket
Downloading file:///D:/Projects/coop/.local/deps/test-archives/tidy-5.8.0-win64.zip (1.3 MB)...
Checking hash of <ESC>[36mtidy-5.8.0-win64.zip<ESC>[0m... 
OK.
Extracting <ESC>[36mtidy-5.8.0-win64.zip<ESC>[0m... 
Done.
Linking D:\Projects\coop\.local\scoop-capture2\apps\tidy\current => D:\Projects\coop\.local\scoop-capture2\apps\tidy\5.8.0
Creating shim for 'tidy'.
'tidy' (5.8.0) was installed successfully!
```

`extract_dir` **不产生任何额外输出行**，与无 extract_dir 的包在文本上不可区分。

### install（tar.xz，带 extract_dir）

输出形状与上一节逐行相同，只有文件名、大、版本不同：

```
Installing 'curl' (8.23.0_5) [64bit] from 'probe' bucket
Downloading file:///D:/Projects/coop/.local/deps/test-archives/curl-8.23.0_5-win64-mingw.tar.xz (4.7 MB)...
Checking hash of <ESC>[36mcurl-8.23.0_5-win64-mingw.tar.xz<ESC>[0m... 
OK.
Extracting <ESC>[36mcurl-8.23.0_5-win64-mingw.tar.xz<ESC>[0m... 
Done.
Linking D:\Projects\coop\.local\scoop-capture2\apps\curl\current => D:\Projects\coop\.local\scoop-capture2\apps\curl\8.23.0_5
Creating shim for 'curl'.
'curl' (8.23.0_5) was installed successfully!
```

### install（MSI）

```
Installing '7zip' (26.05) [64bit] from 'probe' bucket
Downloading file:///D:/Projects/coop/.local/deps/test-archives/7z2605-x64.msi (1.9 MB)...
Checking hash of <ESC>[36m7z2605-x64.msi<ESC>[0m... 
OK.
Extracting <ESC>[36m7z2605-x64.msi<ESC>[0m... 
Done.
Linking D:\Projects\coop\.local\scoop-capture2\apps\7zip\current => D:\Projects\coop\.local\scoop-capture2\apps\7zip\26.05
Creating shim for '7z'.
Adding D:\Projects\coop\.local\scoop-capture2\shims to your path.
Creating shim for '7zG'.
Making D:\Projects\coop\.local\scoop-capture2\shims\7zg.exe a GUI binary.
Creating shim for '7zFM'.
Making D:\Projects\coop\.local\scoop-capture2\shims\7zfm.exe a GUI binary.
Creating shortcut for 7-Zip\7-Zip File Manager (7zFM.exe)
Creating shortcut for 7-Zip\7-Zip Help (7-zip.chm)
Persisting Codecs
Persisting Formats
Running post_install script... 
Get-ChildItem : 找不到路径"...\buckets\main\scripts\7-zip"，因为该路径不存在。
Done.
'7zip' (26.05) was installed successfully!
Notes
-----
To register the context menu entry, please execute the following command:
reg import "...\apps\7zip\current\install-context.reg"

If an error occurs while attempting to delete files during uninstallation, run the following command and then retry:
Stop-Process -Name 'explorer'
-----
```

退出码 **0**。要点：shim 与快捷方式是**逐行**输出的；GUI 入口多一行 `Making … a GUI binary.`；`post_install` 脚本的 PowerShell 错误原样打到屏幕上而安装仍然成功（错误来自我们缺 `main` bucket 的 scripts 目录，属本次录制环境缺陷）；Manifest 的 `notes` 在成功后以 `Notes` 分隔线块整体回显。

### install（批量两包）

```
Installing 'tidy' (5.8.0) [64bit] from 'probe' bucket
...（tidy 的完整 7 行，逐行同上）...
'tidy' (5.8.0) was installed successfully!
Installing 'ripgrep' ...
```

要点：批量时**每包完整走一遍**，没有批级表头，也没有结尾汇总行。

### reset

```
Resetting ripgrep (15.2.0).
Linking D:\Projects\coop\.local\scoop-capture2\apps\ripgrep\current => D:\Projects\coop\.local\scoop-capture2\apps\ripgrep\15.2.0
Creating shim for 'rg'.
```

`Resetting ripgrep (15.2.0).` 里包名**不带引号**，与 install/uninstall 的 `'ripgrep'` 不一致。没有成功结尾行。

### update（单包）

```
ripgrep: 15.2.0 -> 15.2.0_1
Updating one outdated app:
Updating 'ripgrep' (15.2.0 -> 15.2.0_1)
Downloading new version
Downloading file:///D:/Projects/coop/.local/deps/test-archives/ripgrep-15.2.0-x86_64-pc-windows-msvc.zip (1.7 MB)...
Checking hash of <ESC>[36mripgrep-15.2.0-x86_64-pc-windows-msvc.zip<ESC>[0m... 
OK.
Uninstalling 'ripgrep' (15.2.0)
Removing shim 'rg.shim'.
Removing shim 'rg.exe'.
Unlinking D:\Projects\coop\.local\scoop-capture2\apps\ripgrep\current
Installing 'ripgrep' (15.2.0_1) [64bit] from 'probe' bucket
Loading ripgrep-15.2.0-x86_64-pc-windows-msvc.zip from cache
Extracting <ESC>[36mripgrep-15.2.0-x86_64-pc-windows-msvc.zip<ESC>[0m... 
Done.
Linking D:\Projects\coop\.local\scoop-capture2\apps\ripgrep\current => D:\Projects\coop\.local\scoop-capture2\apps\ripgrep\15.2.0_1
Creating shim for 'rg'.
'ripgrep' (15.2.0_1) was installed successfully!
```

这是**唯一观察到缓存命中**的场景：`Loading <文件名> from cache`，**无句号**，位于 `Installing …` 之后、`Extracting` 之前。更新是"先卸旧、再装新"的可见过程，不是原地替换。

### uninstall

```
Uninstalling 'ripgrep' (15.2.0_1).
Removing shim 'rg.shim'.
Removing shim 'rg.exe'.
Unlinking D:\Projects\coop\.local\scoop-capture2\apps\ripgrep\current
'ripgrep' was uninstalled.
```

每个入口的 `.shim` 与 `.exe` 各占一行。

### cleanup

```
Removing ripgrep:
 15.2.0

Everything is shiny now!
```

版本号前有一个空格，块内有一行空行；结尾是固定句 `Everything is shiny now!`。

### 失败：hash 不符

```
Installing 'badhash' (1.0.0) [64bit] from 'probe' bucket
Downloading file:///.../ripgrep-15.2.0-x86_64-pc-windows-msvc.zip (1.7 MB)...
Checking hash of <ESC>[36mripgrep-15.2.0-x86_64-pc-windows-msvc.zip<ESC>[0m... 
ERROR Hash check failed!
App:           probe/badhash
URL:           file:///.../ripgrep-15.2.0-x86_64-pc-windows-msvc.zip
First bytes:   50 4B 03 04 14 00 00 00
Expected:      000000…000
Actual:        71b2fef8…afc5

Please try again or create a new issue by using the following link and paste your console output:
https://github.com/Coh1e/coop/issues/new?title=badhash%401.0.0%3a+hash+check+failed
```

退出码 1。`ERROR` 行替代了 `OK.`，随后是一个字段块和一段固定引导语。**问题链接指向 `Coh1e/coop`，不是 `ScoopInstaller/Scoop`**；在本次录制环境里它是从 bucket 的识别信息推出来的，真实根上应指向 Scoop 自己的仓库，此处未验证，见「未覆盖」。

### 失败：URL 不可达

```
Installing 'badurl' (1.0.0) [64bit] from 'probe' bucket
1u�N܏z�e�]sQ� O��Am����N����1Y%�0
ERROR URL https://example.invalid/nothing.zip is not valid
```

退出码 1。第二行是 **Scoop 自己的编码 bug**：一条本地化（中文）提示在 UTF-16/ANSI 边界上被打坏。这不是 Coop 需要复刻的行为，但说明了"逐字对齐"作为目标的边界。

## 源码依据

| 输出 | 来源 |
| --- | --- |
| `Downloading <url> (<size>)...` | `<SCOOP_SRC>\lib\download.ps1:160` |
| `Checking hash of <ESC>[36m<file><ESC>[0m... ` | `lib\download.ps1:735`（`[char]0x1b` 硬编码，颜色与终端无关） |
| `OK.` / `Done.` | `lib\download.ps1`、`lib\decompress.ps1` 后续行 |
| `Loading <file> from cache` | `lib\download.ps1:61`（无条件点） |
| `Creating shim for '<name>'.` | `lib\install.ps1:180` |
| `'<app>' (<version>) was installed successfully!` | `lib\install.ps1:79` |
| `Resetting <app> (<version>).` | `libexec\scoop-reset.ps1:65` |
| `'<app>' was uninstalled.` | `libexec\scoop-uninstall.ps1:149` |
| `Everything is shiny now!` | `libexec\scoop-cleanup.ps1:84` |
| `Updating one outdated app:` | `libexec\scoop-update.ps1:474` |
| `Downloading new version` | `libexec\scoop-update.ps1:316` |
| 进度条只在非重定向时出现 | `lib\download.ps1:73`：`[console]::isoutputredirected -eq $false` 才启用 |

`lib\download.ps1:73` 决定了**任何管道/CI 捕获都永远看不到下载进度条**。这不是录制方法的问题。

## 与 `docs/cli-feedback.md` 现有契约的分歧

| 项 | 文档写的 | 实测 |
| --- | --- | --- |
| 成功行 | `<包>: success` | `'<包>' (<版本>) was installed successfully!` |
| hash 行 | `Checking hash of x... OK.` 一行 | `Checking hash of <file>... ` 与 `OK.` 两行 |
| 缓存命中 | `Loading x from cache.` | `Loading x from cache`（无句点） |
| 重复安装 | 缓存命中、1.2 s 完成 | `WARN … is already installed.` + 提示，退出码 0，不重装 |
| 颜色 | 未提及 | 文件名带硬编码 ANSI 青色 |
| reset | 未定义 | `Resetting <包> (<版本>).`，包名无引号，无结尾行 |
| 批量 | 每包完成即打一行 + 结尾计数 | 每包完整块，无结尾计数 |
| 下载行 | 未提及大小 | 带 `(<大小>)` |
| 安装尾注 | 未提及 | `suggests installing …` / `Notes` 块 |

## 未覆盖

- **中断（Ctrl+C）**：没有录制。需要一个足够慢的下载源（本地限速 HTTP 服务）才能在包安装中途打断；`file://` 太快。
- **真实根上的首次输出**：`Updating Scoop...`、`Updating Buckets...` 在正常根上的出现条件未验证。
- **真实 HTTP 下载**：本文全部用 `file://`，`Content-Length`、分块与重试路径都没有真实网络样本。进度条本身见源码结论，不需要样本。
- **依赖安装**：没有录到 `depends` 场景（手写 Manifest 未构造依赖）。
- **`suggests installing` 的数据来源**：只观察到它出现，未确认它读自 bucket 的哪个文件。
- **hash 失败时的问题链接**：指向 `Coh1e/coop`，与真实根上的行为不同，未查明。
