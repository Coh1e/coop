# Scoop 的 Git 调用清单与 Coop 最小能力边界

研究日期：2026-10-25。本文是静态源码调查，不是兼容性或性能测试结果。

## 范围与版本

- 官方仓库：`ScoopInstaller/Scoop`，`master` 在本轮读取时指向 [`e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f`](https://github.com/ScoopInstaller/Scoop/commit/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f)，发布提交为 0.6.0，作者时间 2026-09-30。
- 通过 GitHub connector 获取该提交的递归 tree（`truncated=false`），读取 tree 中 83 个 `.ps1`、`.psm1`、`.yml`、`.cmd`、`.bat` 文件，排除 `test/fixtures`。83 次读取均返回成功。搜索 `git`、`Invoke-Git`，再阅读命中位置的调用上下文，并补查维护脚本的 `hub` 调用。
- 未执行上述脚本；未安装、更新、删除任何软件、bucket 或用户状态；未读取个人 Scoop/Git 配置。未测量命令耗时。
- 没有穷举 Main、Extras 或第三方 bucket 的 Manifest 脚本；它们可以执行任意外部程序，因而本清单不能证明所有软件包都不依赖 Git。
- `bin/install.ps1` 只是获取并执行 `https://get.scoop.sh`，远程安装器位于本轮固定提交范围之外，未据此对首次安装流程作完整结论。[源码](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/bin/install.ps1#L1-L2)

## 结论

**Coop 可以把“用户必须安装 git.exe”从包管理器核心要求中移除；这不等于能够无损省去 Scoop 的所有 Git 语义。** 核心需求应按行为拆分：bucket 获取与刷新、来源与修订识别、变更列表、可选历史 Manifest 读取。普通用户无需承担提交、推送、合并冲突处理和 Scoop 源码自更新的实现成本。

goop 的已有无 Git 路径、快照方案与候选设计对照见 [无 Git bucket 方案](git-free-buckets.md)。本文只负责固定版本 Scoop 调用审计。

需要特别保留的兼容性问题是 **`package@version` 的历史 Manifest 查找**：Scoop 0.6.0 的历史 Git 查询默认开启，会查提交历史及父提交，不能将所有 `log/show` 都归为装饰性输出。[源码](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/manifest.ps1#L210-L274)

“最小子集”建议指 Coop 内部的最小仓库能力接口，**不建议首先实现一个兼容 Git 命令行的微型 git.exe**。后者会把无关的参数、输出及仓库格式兼容承诺带入产品。

## 调用包装器

`Invoke-Git` 通过 `Get-HelperPath Git` 找 Scoop 管理的 Git（优先查 `mingw64/bin/git.exe`、`mingw32/bin/git.exe`），否则查 PATH 中的 Git；指定工作目录时前置 `-C <path>`。有 Scoop 代理配置时，`clone/checkout/pull/fetch/ls-remote` 通过 PowerShell job 调用，并在该 job 设置 HTTP(S) 代理。这是运行方式，不是额外 Git 子命令。[包装器](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/core.ps1#L237-L278)、[工具发现](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/core.ps1#L472-L496)

## 普通 bucket 与查询功能

下表中的参数省略变量名及通用 `-C`，保留影响行为的选项。

| Scoop 使用处 | 实际 Git 命令/参数 | 目的 | Coop 最小行为 |
|---|---|---|---|
| `bucket add` | `config --get remote.origin.url`；`ls-remote <repo>`；`clone <repo> <dir> -q` | 检查重复来源、检查远端、取得 bucket（未加 shallow/depth 参数） | 识别来源，解析目标分支/修订，获取一致的文件树；无需向用户暴露 Git |
| `bucket list` | `config remote.origin.url`；`log --format=%aI -n 1` | 显示来源和最后提交时间 | 来源与同步修订属于有用元数据；提交时间不能和本地同步时间混用 |
| 安装错误提示 | `config --get remote.origin.url` | 为自定义 bucket 生成上游 Issue 链接 | 从 Coop 的来源记录生成；不必运行 Git |
| bucket 更新 | `rev-parse HEAD`；`pull -q` | 记住旧修订、更新工作树 | 获取新修订和文件树，安全替换/提交；若拒绝本地修改与分歧须明确报错 |
| bucket 更新日志 | `--no-pager log --color --no-decorate --grep=^(chore) --invert-grep --abbrev=12 --format=... <old>..HEAD` | 显示提交摘要，过滤 chore | 可后置；不等同于包版本更新列表 |
| bucket SQLite 缓存增量更新 | `diff --name-status <old>` | 收集新增、修改、重命名、删除文件，再更新 Manifest 缓存 | 对两份受控文件树/索引计算变更即可，不必兼容 Git diff 文本 |
| `status` 的远端检查 | `fetch -q origin`；`branch --show-current`；`log HEAD..origin/<branch> --oneline` | 判断 Scoop/bucket 是否有上游提交 | 取得远端修订，和已同步修订比较；若仅比较“不相等”，与“是否存在上游新增提交”不是完全相同语义 |
| `info` | `log -1 -s --format=%aI#%an <manifest-file>` | 显示该 Manifest 最后修改时间与作者 | 可作为可选详情；无历史时应明确缺失，不把同步时间/文件所有者伪称为上游作者信息 |
| `--version` | `--no-pager log HEAD -1 --oneline`（非 master Scoop 分支、各本地 Git bucket） | 显示源码/bucket 提交摘要 | Coop 版本直接内置；bucket 修订从来源记录读取 |

依据：[bucket add/list/错误来源](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/buckets.ps1#L104-L216)、[bucket 同步与缓存](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/libexec/scoop-update.ps1#L155-L258)、[日志格式](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/core.ps1#L281-L298)、[status](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/libexec/scoop-status.ps1#L11-L44)、[info](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/libexec/scoop-info.ps1#L123-L133)、[version](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/bin/scoop.ps1#L21-L39)。

注意：`status --local` 会禁止远端检查；Git 不可用时也退回本地模式。`info` 在没有可用 Git 信息时使用文件最后写入时间和 ACL 所有者。`bucket list` 同样有本地文件目录回退。因此这些查询的全部功能不应被概括成“都必须 Git”。[status 回退](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/libexec/scoop-status.ps1#L11-L17)、[info 回退](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/libexec/scoop-info.ps1#L123-L133)、[bucket list 回退](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/buckets.ps1#L104-L120)

`scoop reset` 是重建某个软件的 current、shim、快捷方式、环境和持久化链接，**不是 `git reset`**；该命令文件没有 Git 调用。[源码](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/libexec/scoop-reset.ps1#L65-L91)

## 历史版本安装

`Find-HistoricalManifestInGit` 的 Git 调用为：

1. `show HEAD:<manifest-path>`：当前 HEAD 已包含指定版本时直接返回。
2. `log --follow -n 1 --format=%H -G <version-regex> -- <manifest-path>`：查该版本相关的最新文件历史提交，带重命名跟踪。
3. 上一步无结果时，`log --follow -n 1 --format=%H -S <version-literal> -- <manifest-path>`。
4. 依次 `show <commit>^:<manifest-path>`、`show <commit>:<manifest-path>`，解析 JSON 并严格核对 `version`。

历史查找编排先尝试已启用的 SQLite 缓存，再尝试默认开启的 Git 历史。此能力需要旧 Manifest 的真实内容，只有最新工作树快照不能完整替代。[历史 Git 实现](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/manifest.ps1#L210-L274)、[编排](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib/manifest.ps1#L277-L300)

Coop 可分别承诺：使用已安装版本中保存的 Manifest、使用已经缓存的精确历史 Manifest、访问远端/现有 Git 对象中的历史 Manifest。这三者覆盖范围不同。若第一版不实现第三项，必须明确拒绝无法取得精确历史 Manifest 的版本请求，不能把替换 URL 中版本字符串视为完全等价。

## Scoop 自更新专用调用

这些调用更新的是 Scoop 自身的 PowerShell 源码；Coop 不需要以同样方式分发自身，因此不应直接纳入 Coop bucket 最小子集。

| 情况 | 命令 |
|---|---|
| 将非 Git Scoop 转成 Git 安装 | `clone -q <repo> --branch <branch> --single-branch <newdir>` |
| 检查当前身份/分支/修改 | `rev-parse HEAD`；`config remote.origin.url`；`branch`；`diff HEAD --name-only` |
| 配置允许自动暂存本地修改 | `stash push -m <message> -u -q` |
| 修改自更新来源 | `config remote.origin.url <repo>` |
| 修改来源/分支时重建追踪 | `config remote.origin.fetch +refs/heads/*:refs/remotes/origin/*`；`fetch --force origin refs/heads/<branch>:refs/remotes/origin/<branch> -q`；`checkout -B <branch> -t origin/<branch> -q`；`reset --hard origin/<branch> -q` |
| 来源/分支未变的正常自更新 | `pull --tags --force -q` |
| 更新后摘要 | 上述 `Invoke-GitLog` |

依据：[Sync-Scoop](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/libexec/scoop-update.ps1#L64-L153)。不带软件名的 `scoop update` 会依次执行 Scoop 自更新和 bucket 同步；带软件名的路径在显式选择 Scoop 或 `is_scoop_outdated` 成立时也会先同步。这是命令编排的一部分，不能只看单包下载路径来断言其绝不会运行 Git。[入口编排](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/libexec/scoop-update.ps1#L397-L425)

## 维护、贡献与发布

- `bin/auto-pr.ps1` 使用 **hub**，不是直接写 `git`：包含 `checkout`（普通、`-b`、`-f`）、`rev-parse --verify`、`add`、`commit`、`push`、`reset`（普通、`--hard`）、`pull`（普通、`--rebase --autostash`）、`diff --name-only`、`status --porcelain -uno`、失败时 `rebase --abort`，以及 GitHub 专用 `pull-request`。这些属于维护 bucket/提交更新工作流，首版普通包管理器无需复制。[准备与提交](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/bin/auto-pr.ps1#L94-L163)、[同步与推送](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/bin/auto-pr.ps1#L167-L225)
- 发布 workflow 使用 `git log -1 --format=%cs <previous-tag>` 和 `git log -1 --format=%cs HEAD` 构造发布日期区间，属于 Scoop 自身发布，不是终端用户的 bucket 更新要求。[release workflow](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/.github/workflows/release.yml#L35-L46)
- 动态执行的 Manifest hook 或远程脚本可能额外调用 Git；本调查没有承诺该集合是封闭的。Coop 对明确声明的软件依赖与运行期 Git 需求仍须分别处理。

## 建议的最小内部接口（设计提案，未实现）

1. **读取来源**：bucket 名称、地址、分支/引用、已同步修订、来源类型。迁移时识别既有来源，不借机覆写或清理旧 `.git`。
2. **检查远端修订**：不修改本地安装状态，区分未变化、变化、远端不可达。
3. **取得指定修订的文件树**：保留整个 bucket 必需文件，而不只下载 JSON；bucket 中被 hook 引用的脚本/资源需要另行调查。
4. **提交新快照与列出文件变化**：准备成功才切换生效，生成新增/修改/删除集合供索引更新；保留原快照直到提交成功。
5. **读取精确历史 Manifest（可后置，但必须明确兼容边界）**：给定包与版本，返回来源修订、路径、原文，或明确“不支持/未找到”。

若底层继续采用 Git 仓库，前四项接近“读取配置/ref/object、远端引用发现、fetch/clone、受控工作树更新、树差异”的语义子集；日常 bucket 路径无需提供 Git add/commit/push/stash，也不必实现交互式 merge/rebase。若采用托管平台快照/API，同一接口可以保持，但历史查询、非托管平台来源、私有认证、带本地修改的 bucket 都是需要显式设计的兼容差异。

不要将原地 `pull` 替换成无条件覆盖工作树：Scoop 的 `pull` 使用实际仓库配置与 Git 行为，本地提交、未提交修改、来源/分支变更、远端重写都可能影响结果。Coop 第一版可以选择对这些情形停止刷新并说明原因；这比默默丢弃本地修改更符合已确认的接管目标。

## 验收建议与未运行项

后续实现需要在独立测试目录验证，当前均 **未运行**：

- 干净既有 Scoop bucket 来源识别；默认分支不是 master/main；新增/修改/删除 Manifest 与辅助脚本。
- 未变化 bucket 不下载或不重建无关索引；断网/下载中断/归档损坏后旧 bucket 仍可查询。
- 本地改过的 JSON、未跟踪辅助文件、本地提交、远端分支切换/强制更新不被静默丢弃。
- 未安装 Git 的环境中，search/list/info、bucket 获取/刷新、普通软件生命周期实际运行。
- `package@version` 从 HEAD、已缓存原文、历史原文三个来源取得正确 Manifest；不可取得时明确失败。
- Manifest 或辅助脚本显式/动态调用 Git 时不误报为“无需 Git 即完全兼容”。

本轮证据：GitHub connector 的 tree 与 83 个固定提交文件读取；报告写入后仅检查 Markdown 内容和来源行号。没有本地 Scoop 命令退出码、端到端迁移证据或性能数据可报告。
