# CLI 反馈与下载缓存

2026-10-28 建立。写命令在文本模式下逐步报告进度，下载产物落到与 Scoop 共用的 `<根>/cache`。术语见 [GLOSSARY.md](../GLOSSARY.md) 的「进度反馈」「下载缓存」。

## 文本模式的输出契约

写命令（`install`、`update`、`uninstall`、`reset`、`cleanup`）在执行期间逐行报告阶段；`--json` 不输出任何进度，只保留原有的结果对象。

```
Installing 'pi-coding-agent' (1.4.0) [64bit] from 'main' bucket.
Downloading https://github.com/earendil-works/pi/releases/download/v1.4.0/pi-windows-x64.zip
Checking hash of pi-windows-x64.zip... OK.
Extracting pi-windows-x64.zip... Done.
Linking C:\Users\Neo\scoop\apps\pi-coding-agent\current => C:\Users\Neo\scoop\apps\pi-coding-agent\1.4.0
Creating shim for 'pi'.
pi-coding-agent: success
```

规则：

- 阶段行在阶段**开始或完成时**打印，不攒到结束；批量命令每个包完成即打印一行，最后再给总体计数。
- 下载在终端上显示行内进度 `42.7 / 43.0 MB`，非终端（管道、CI）只保留阶段行。
- 失败在出错的那一步立刻出现：`<包>: partial` 或 `coop: <原因>`，随后以退出码 1 结束。
- 措辞与顺序对齐固定 Scoop 修订的关键行；Coop 特有步骤（入口发布、用户环境）用同样句式自述，不承诺逐字节一致。

## 下载缓存

- 产物校验通过后写入 `<根>/cache/<声明文件名>`，布局与 Scoop 相同，两个客户端共用同一份文件。
- 命中前按 Manifest 声明的算法与摘要重新校验；摘要不符或文件损坏视为未命中并重新下载，缓存内容不被信任。
- 命中时打印 `Loading <文件名> from cache.`，随后仍执行同一套校验与解压步骤。

实测（本机，`pi-coding-agent` 1.4.0，43 MB 下载 / 113 MB 解压 / 213 个文件）：

| 场景 | 改前 | 改后 |
| --- | --- | --- |
| 冷装 | 31.4 s，期间无输出 | 40.0 s（网络波动），7 行阶段输出 |
| 再装（缓存命中） | 20.5 s，实际重新下载 | **1.2 s** |
| Scoop 对照 | 冷 26.9 s / 命中 1.9 s | — |

## 尚未完成

- 解压仍对每个文件 `FlushFileBuffers`；每个 IR 步骤仍单独 fsync；每个 exe 入口仍复制 4.2 MB 启动器。前两项与启动器共享分别由 #52、#53 跟踪。
- 依赖安装路径的逐包输出与批量命令共用同一格式，但尚未单独验收（#54）。
