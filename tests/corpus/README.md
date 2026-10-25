# 固定 Scoop Manifest 样本

此目录保存 20 份未经修改的真实 Manifest、原始 bucket 的 Unlicense、来源与 SHA256 索引，以及全量字段统计。它们不是已通过安装测试的软件名单。

`index.json` 按样本记录版本、固定修订、官方来源、文件哈希、选择理由和静态特征。初始状态为 PowerShell JSON 解析通过，Coop 计划与生命周期均 `not-run`；后续运行结果另存证据，不通过编辑原始 Manifest 来使测试变绿。T18 的逐样本计划与生命周期结果见[首版真实样本兼容与整体验收报告](../../docs/compatibility-report.md)。

研究输入全部来自公开源码，运行以下命令只下载和读取资料，不执行上游安装脚本：

```powershell
./tests/corpus/fetch-sources.ps1
./tests/corpus/analyze.ps1
```

下载源放在项目内被忽略的本地研究目录。统计只看 Manifest 根字段和架构对象，排除 checkver/autoupdate；每个字段每份 Manifest 最多计一次，覆盖全部架构而非当前平台的有效行为。`no_install_script_field` 仅说明没有选定脚本字段，不能解释为无需外部工具或能够安装。URL 原始格式与 `#/` 重命名后的本地格式分开统计。

语义依据和运行状态详见 [Scoop 行为研究](../../docs/research/scoop-behavior-and-corpus.md)。

`extras-scripts/` 保存 `Extras/notepadplusplus` 的 `post_install` 所需的两个真实 bucket 脚本资源（固定修订与哈希见该目录 README）；测试只读取并改写副本，不执行注册表导入。生命周期 Hook 的脚本原文由 `tests/hooks.ps1` 直接从本目录 Manifest 读取，不手工改写。
