# 包体只做构建级优化，不裁剪能力面

包体有两个口径：**下载包**（release zip）与**安装后占用**（落盘字节总和：`coop.exe` + `scoop-lib` + `licenses` + `LICENSE` + `THIRD_PARTY.md`）。2026-10-30 由人类决定以**安装后占用**为主指标，zip 只记录不设阈值。同日的实测（MSVC 工具集 14.51.36231，基线 `coop.exe` 4,732,928 B、安装占用 5,027,360 B）显示：全量 LTO（`/GL`+`/LTCG`）只省 2.0%，`/Gy` 与 `/Ob1` 在 LTO 之上无额外效果；`/O1` 省 11.2%，其中 9.5 个百分点来自 coop 自己的 C++ 编译单元。归档与编解码的裁剪不划算：抽样 Main/Extras/Versions 共 4,781 份真实 Manifest，`.zst` 7 份、`.xz` 12 份、`.lzma` 8 份、`.rar` 7 份、`.cab` 9 份、`.bz2` 0 份，而 libarchive 中当前无人使用的读取器合计只有约 65 KB（1.4%）。

因此体积策略固定为：只给 coop 自己的 C++ 编译单元加 `/O1`（Release 配置，含 `/Gy`），C 依赖（zlib、liblzma、bzip2、zstd、libarchive、libgit2）保持 `/O2` 以保住解压吞吐；不启用 LTO；不裁剪归档格式与编解码能力；不替换 libgit2 的 pcre2 正则后端；不用 UPX；保持单文件、静态 CRT、无 VC 运行时依赖。体积守卫按“安装后占用”判定，阈值取落地后 CI 实测值 × 1.1。

## Considered Options

- **全量 `/O1`**（含解压库）：比选定的方案再多省约 69 KB（合计 −11.2%），但让 zlib/liblzma 也进入低优化档，把不确定性放在用户真实等待的解压路径上。
- **裁剪归档格式**（把 `archive_read_support_format_all` 换成显式子集）：最多省约 65 KB，却会破坏 16 个真实 Manifest（rar/cab 目前是靠 `format_all` 意外支持的能力）并需要改动上游源列表。
- **换 `REGEX_BACKEND=regcomp` 去掉 pcre2**：约 118 KB，代价是 `.gitignore` 匹配语义偏离 libgit2 默认后端，属兼容性风险。
- **UPX 之类的外部压缩**：省下载体积最直接，但引入杀软误报与启动解压成本，且与“安装后占用”主指标无关。

## Consequences

- 本地构建比同源码的 CI 构建大约 72 KB（工具链差异），体积守卫必须在 CI 上取基线，不能拿本机数字写死。
- 解压吞吐仍未有实测；完整 `ctest` 在本会话只到 64/79（项目内 PowerShell 7.6.9，15 个失败是 `HKCU\Environment` 写权限与 junction 目标解析的环境问题），Windows PowerShell 5.1 下只到 21/79（套件依赖 PS 7 语义）。因此体积改动的验收仍需在 CI 上收口。
- 体积基线、归因与未测量项记录在[本地查询与刷新性能](../performance-support.md)的包体一节；改动本身由独立票 [#90](https://github.com/Coh1e/coop/issues/90) 实现。
