# Scoop Git 使用与 goop 无 Git 路径：Coop 设计建议

调查日期：2026-10-25。关联任务：[Coh1e/coop#1](https://github.com/Coh1e/coop/issues/1)。这是源码静态调查与设计建议，不是实现或性能验证。

## 结论

**2026-10-25 后续决定**：用户明确选择直接使用 C++ 可调用的 Git 库。以下快照建议保留为调研对照，已不作为首选方案。当前首选候选为 libgit2；最小边界为打开/克隆仓库、读取来源与 ref、远端修订发现与 fetch、tree/blob 读取和 diff，历史遍历按兼容范围另行确定。尚未运行构建和性能验证。

Coop 无需强制安装 git.exe。goop 已在源码中给出 GitHub bucket 无 Git 获取路径；但它没有内嵌最小 Git 实现，而是下载仓库归档。应提炼 Coop 需要的仓库操作，而不是照搬 Git CLI 命令集合。是否引入 Git 库，仍取决于增量同步、历史查询和非 GitHub 来源的验收要求。

Scoop 的完整命令调用清单见 [审计报告](scoop-git-command-audit.md)。其中历史 Manifest 查询属于终端用户功能，不能与贡献者工具一起排除。

## 固定调查版本

- Scoop：[`e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f`](https://github.com/ScoopInstaller/Scoop/tree/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f)，master，0.6.0。
- goop：[`3f78a1377967e6f080a65a231ed0f18abad63d0e`](https://github.com/TanguyBaudoin/goop/tree/3f78a1377967e6f080a65a231ed0f18abad63d0e)，main。

## goop 实际做法

| 场景 | 已读到的代码行为 | 对 Coop 的意义 |
| --- | --- | --- |
| 首次获取 Git bucket | PATH 有 Git 时 `clone --depth 1`；没有时将 GitHub URL 转为 codeload ZIP | 无外部 Git 可行，但并非自行实现 Git |
| 后续 Git 更新 | `fetch`、`reset --hard FETCH_HEAD`、`clean -fd` | 将 bucket 当作可丢弃上游镜像，会覆盖修改并删除未跟踪内容，不适合直接处理未知迁移目录 |
| 无 Git 更新 | GitHub archive 下载到 staging，然后删除旧目录并 rename | 每次全量下载；旧目录删除后 rename 失败的恢复仍需额外设计 |
| 后来安装了 Git | 将原快照重新 shallow clone 一次 | goop 将 Git 当可选加速路径；Coop 是否采用这种环境相关行为尚未决定 |
| 迁移时识别 origin | 直接读取 `.git/config` 的 origin URL，不启动 Git | 可读取常见配置，但该代码不等同完整 Git config/worktree/include 解析 |
| 历史版本 | README 明确只解析 bucket 当前提供的版本 | 不能拿这一路径宣称完整兼容 Scoop 的历史 Manifest 查找 |

依据：goop [`bucket.go:25–54`](https://github.com/TanguyBaudoin/goop/blob/3f78a1377967e6f080a65a231ed0f18abad63d0e/internal/bucket/bucket.go#L25-L54)、[`169–192`](https://github.com/TanguyBaudoin/goop/blob/3f78a1377967e6f080a65a231ed0f18abad63d0e/internal/bucket/bucket.go#L169-L192)、[`438–540`](https://github.com/TanguyBaudoin/goop/blob/3f78a1377967e6f080a65a231ed0f18abad63d0e/internal/bucket/bucket.go#L438-L540)；[`migrate.go:371–398`](https://github.com/TanguyBaudoin/goop/blob/3f78a1377967e6f080a65a231ed0f18abad63d0e/internal/installer/migrate.go#L371-L398)；[固定版 README](https://github.com/TanguyBaudoin/goop/blob/3f78a1377967e6f080a65a231ed0f18abad63d0e/README.md) 的 “Which bucket you pin against”。README 的速度与测试数字仅为上游自述，本轮未复测。

特别注意：goop 使用 `/zip/HEAD`，只从 URL 得出 owner/repo；这不保留迁移仓库当前分支或固定 revision。Coop 接管时必须将来源、所用分支/固定 revision 与本地目录分开表示，无法确定时停止该来源的更新，而不是猜默认分支。goop 的迁移实现还采用复制到自身目录的方式，不能直接当作 Coop 已确定的原地接管方案。

## 建议的最小能力

以下为最初的快照方案提议；运输方向已由用户改为内嵌 Git 库，历史支持范围仍待确认。

1. **识别来源和 revision**：读取已有 bucket 内容；识别远端、跟踪分支或固定 commit；对复杂 `.git` 指针、include、多个 remote、detached HEAD 等无法可靠识别的情况给出明确诊断，保留只读使用能力。
2. **解析远端 revision 并检查变化**：有可靠 commit 标识时先比较；相同则无需下载、解压或重建索引。可用的 HTTP 条件请求应按实际端点验证；不假定每个归档端点都支持相同的 ETag/304 行为。
3. **获取确定 revision 的完整快照**：默认分支更新先解析为固定 commit，再获取该 commit 的归档，避免分支在多次请求间变化。GitHub 官方归档 API 支持指定 ref，省略则使用默认分支；[官方说明](https://docs.github.com/en/rest/repos/contents#download-a-repository-archive-zip)。
4. **比较与发布内容**：对新旧文件生成添加、修改、删除清单，供索引更新；这是本地内容差异，不冒充 Git commit log 或 Git 网络增量传输。完整保存 bucket 内辅助脚本和资源，不能只下载 JSON。
5. **失败恢复**：下载、解压、路径验证、索引准备在 staging 中进行；保留旧快照直至可恢复地完成切换。Windows 上多个目录与元数据的切换需要日志/恢复协议，不能将一次 rename 宣称为整个流程的原子性。

迁移的本地 bucket 可能含有已提交的本地变更和未提交内容。没有可信基线时，不能声称通过简单文件扫描证明其干净；先保留原内容和来源，停止覆盖更新，或经用户明确选择将其转换为上游镜像。不得自动 `reset --hard` / `clean`。

### Git 对应关系

| Scoop 使用的能力 | Coop 最小替代建议 |
| --- | --- |
| clone / pull / fetch / checkout 等来源更新 | revision 查询 + 确定 revision 快照获取 + 可恢复发布；需要真增量时另选 Git 库 |
| config remote URL / branch / rev-parse | 来源记录和 revision 解析；迁移复杂 Git 元数据需要专门支持或拒绝 |
| diff 更新索引 | 本地内容比较生成变化清单 |
| log / show 安装历史版本 | 单独的历史 Manifest resolver；当前快照路径无法替代 |
| Scoop 自更新的 stash / branch / reset / tags | Coop 不更新 Scoop 源码；Coop 自更新应独立设计 |
| push / add / commit / rebase 等贡献流程 | 不属于首版消费 bucket 的必要能力 |

### 需要保留的限制

- GitHub 快照方案不等于任意 Git 服务兼容；其他托管服务、私有仓库、SSH URL 需要适配或明确不支持，不把 SSH URL 静默转为匿名 HTTPS。
- 无变化时省掉归档下载，不等于有变化时增量传输。后者若是性能验收要求，应验证内嵌 Git 库而非持续堆叠 provider 特例。
- 保存当前已安装包的 Manifest 可服务这些包的管理，但不能恢复本机从未见过的历史版本；历史 Manifest 可获得也不代表历史下载链接仍有效。
- core 不依赖 Git，与某个软件包自身依赖 Git 是两件事。Manifest 的显式 `depends: git` 或脚本调用 Git 不能因 bucket 同步不再需要 Git 而静默移除。

## 若需要真 Git 增量

可评估 libgit2，将用途限制为只读远端：打开/克隆、读取配置与 ref、fetch、tree/blob 读取、revision 遍历、diff。其 [`git_remote_fetch`](https://libgit2.org/docs/reference/main/remote/git_remote_fetch.html) 提供下载对象并更新远端跟踪引用的 API，因此无需依赖外部 git.exe。但静态链接体积、许可证、Windows TLS/代理、构建依赖和错误恢复均未在本轮验证，不能现在定为技术选型。

不建议自行实现 Git wire protocol 与对象数据库。即使只做 fetch，也涉及 ref discovery、协商、packfile 等行为，见 [Git 官方 pack protocol](https://git-scm.com/docs/gitprotocol-pack)。缩小上层用途并不能免除这些底层语义。

## 建议验证顺序

1. 使用固定 Main/Extras 快照，验证无 Git 可搜索、查询与检查更新；保存辅助脚本。
2. 对同一 revision 重复刷新，观测是否零归档下载、零解压、零索引重建。
3. 比较快照和内嵌 Git 方案：首次获取、有变更、无变更，分别记录墙钟耗时、网络字节、CPU、写入量和二进制体积。
4. 演练自定义分支、来源不明、本地修改、断网、解压失败、切换失败、进程中断；旧快照应可用或可明确恢复。
5. 如历史版本入首版，加入路径更名、浅历史、重复版本、合并提交、历史产物失效等对照样本。

## 本轮证据与未运行项

- 本轮通过 GitHub connector 读取固定版源文件；只读副本保存在被忽略的 `.local/research/goop/`，未执行上游代码。
- 已读取 `internal/bucket/bucket.go`、其测试、`internal/installer/migrate.go`、`import.go`、`internal/manifest/resolve.go`、README、ARCHITECTURE、go.mod。ARCHITECTURE 中部分迁移描述与其他源码/README 有版本内差异，因此本报告具体判断以函数实现为准。
- 本轮运行 `gh issue list --repo Coh1e/coop ...`（成功，最初为空）、create 和 view；最初受限网络调用失败退出 1，获得网络执行后退出 0。
- 工具：GitHub CLI 2.103.2，Git 2.56.0.windows.3（仅查询版本，未用 Git 同步外部仓库）。
- 未运行：Scoop/goop 功能测试、迁移、安装、Git 命令替代、归档下载/解压、条件请求、性能基准、libgit2 构建。
- 未决：首版是否支持历史 Manifest 查询，快照或内嵌 Git 的运输选择，非 GitHub 来源范围。研究结论不代替这些产品决定。
