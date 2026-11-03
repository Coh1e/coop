# 逐命令输出对照

本轮按 2026-11-02 确认的范围执行：对齐 Scoop 的输出内容、结构与用法说明，保留 Coop 已有行为和机器契约。命令名称、明确的空状态、完整路径、额外成功提示，以及说明实际能力的文字可以不同。

## 重跑

使用 Windows PowerShell 5.1。先构建，再运行对照；不要在测试期间重新链接同一个 `coop.exe`。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1 -Action build
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/compare-command-output.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1 -Action test
```

对照脚本默认使用项目内已有的 Scoop 0.6.0 源码树 `.local/scoop-baseline/root/apps/scoop/current`。其他位置通过 `-ScoopSource <目录>` 指定；缺少源码时明确失败，不下载或改动真实安装。

每轮建立独立的 `.local/command-output/<轮次>/`，逐条保存双方的参数、退出码、stdout 与 stderr。`results.json` 是原始记录，`comparison.json` 是逐场景判定。也可用 `scripts/check-command-output.ps1 -Evidence <轮次目录>` 单独复核。

参考端运行 Scoop 原有命令代码；仅在本轮副本里把 `Get-EnvVar` / `Set-EnvVar` 的持久化边界改为子进程环境，防止 Scoop 安装时修改真实用户 PATH。清单不声明环境修改、快捷方式或 Hook。这个对照不证明用户环境写入兼容，相关行为由既有生命周期测试覆盖。bucket 表格用固定宽度捕获，避免长测试路径遮掉列。其余归一化只处理客户端名、隔离根、颜色、空白和易变时间；JSON 按字段比较，不比较键顺序。

## 命令清单

每条命令均采集详细帮助和默认入口；下表补充有数据、错误或生命周期场景。`update` 的默认入口取不存在的软件包，`status` 用 `-l`，避免自动联网；因此不把它们冒充为裸命令的远程刷新验收。

| 命令 | 补充对照 | 保留的差异与限制 |
| --- | --- | --- |
| alias | 空列表、添加、详细列表、删除 | 添加后有具名成功提示 |
| bucket | list、known、本地 Git add/update/rm | rm 保留源文件；update 是 Coop 扩展；保留 JSON 字段 |
| cache | 默认列表、包过滤、删除 | 汇总先于 Name/Version/Length 表格 |
| cat | 正常清单、不存在的包 | 保留源文件文本，不调用 bat |
| checkup | 系统设置与缺失 helper | 保留事务、损坏 shim 检查；不检查 Defender；WiX 提示明确属于 Scoop 的需求 |
| cleanup | 有旧版本、无参数 | 无参数清理全部本地软件；保留安全检查及完成摘要 |
| config | 读取、设置与删除受支持项 | Name/Value/Note 表说明忽略的设置；写入范围不扩展 |
| create | 无参数、非法 URL | Coop 输出离线骨架；Scoop 正常流程需交互选择，未自动执行 |
| depends | 正常清单、不存在的包 | 依赖顺序与字段一致 |
| download | 缓存命中 | 补齐校验结果与下载完成提示；真实网络故障由已有测试覆盖 |
| export | 空与有安装的软件列表 | Scoopfile 的安装与 bucket 字段一致；保留既有 JSON，不新增易变 Updated 字段 |
| help | 总表与各命令详细页 | 增补参数说明和例子；Coop notes 明示既有能力边界 |
| hold | 首次、重复、不存在的软件 | 不改变已有安装记录行为 |
| home | 不存在的软件、没有 homepage | 不启动真实浏览器；正常打开网页的副作用未在本对照执行 |
| import | 空 Scoopfile、文件不存在 | 缺参和缺文件诊断更简洁；不导入配置或全局安装 |
| info | 正常清单、不存在的包 | 非 Git 夹具不显示来自上层仓库的无关作者/时间 |
| install | 缓存安装、重复安装 | 校验结果同一行；不改变计划和安装机制 |
| list | 已安装、过滤无匹配 | 无匹配时保留列头，便于识别字段 |
| prefix | 已安装、不存在的软件 | 输出 current 路径 |
| reset | 未指定版本、指定当前版本 | 保留仅回退到指定本地旧版本的约定；成功回退由既有 `old_versions` 测试验证 |
| search | 本地命中、无匹配 | 所有 known buckets 在测试根注册为空，避免 GitHub 回退 |
| shim | 空列表、add/info/list/rm、不存在的 shim | 对齐来源和可见性字段；info 额外保留 Target/Arguments；alter 仍只修改参数 |
| status | 当前与过期版本 | 此历史对照使用 `-l`，只证明本地状态；裸命令现检查 Coop 与同根 Scoop 的更新，见[读命令输出](query-output.md) |
| unhold | 已安装、不存在的软件 | 保留现有行为 |
| uninstall | 正常卸载、重复卸载 | 保留持久化与安全边界 |
| update | 缓存升级、不存在的软件 | 不重复宣称读取同一缓存；不自更新；全局只读 |
| virustotal | 缺少 API key | 补齐获取 key 的地址和设置命令；真实服务查询未执行，不使用真实 key |

`init`、`recover` 是 Coop 独有命令，没有 Scoop 对应项，继续由现有 CTest 验证。

## 回归证据与边界

`tests/command-output.ps1` 覆盖默认缓存、汇总位置、缺参 Usage、bucket 文本与 JSON 分离、帮助示例，以及 helper 提示的出现、消失和计数。通过项目内临时 CTest 配置，让这条测试运行已安装的旧 `coop 0.3.1`，已复现 `cache requires show or rm` 并失败；旧程序没有被替换。更新后的程序由正常 CTest 执行。

本轮先运行的 `cache` 测试也在修改前失败，指出汇总位于表格之后。`tests/update-lines.ps1` 改为验证 `Checking hash ... OK.` 和 `Extracting ... Done.` 各占同一行；shim 测试同时验证信息字段、替代来源与实际执行目标和参数。

本对照不等同于全部软件或所有开关的兼容性验收。交互选择、真实浏览器、真实 VirusTotal、管理员 Defender 检查和公网异常并未逐项执行。运行结果与允许差异必须查看本轮 `comparison.json`，不能用“已采集”代替“已通过”。

最终构建运行 `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/compare-command-output.ps1`（脚本见上文）完成全部 28 个帮助页及 114 组双端场景对照。证据目录为 `.local/command-output/e74456dbeebf49688819ff8b31db0981/`，`environment.json` 记录程序摘要与运行器；`check-command-output.ps1` 退出码为 0。判定中逐项区分归一化相同、明确记录的输出或既有行为差异，没有将这些差异算作逐字一致。

完整套件本轮运行 `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1 -Action test`，84 项通过，日志保存在 `.local/command-output/full-ctest-before-exit-preservation.log`。随后保留了裸 `bucket` 原有的失败退出码 1，并整理源文件行尾与样式，重新构建；最终构建再运行下列 12 项检查，全部通过。缺参 `cat` 仍使用 Coop 原有退出码 2，没有改成 Scoop 的 1。

```powershell
ctest --test-dir .local/build -R '^(source_hygiene|doc_links|command_output|cache|query_text|inspect|config|tools|shim|path_batch|bucket|update_lines)$' --output-on-failure
```

原问题中的裸 `bucket`、`cache`、`cat`、`checkup` 还在真实用户 Scoop 根用双方 CLI 逐项只读复核，记录在 `.local/command-output/real-samples/`。执行方式为 `.local/build/coop.exe <命令>` 与 `scoop <命令>`。缓存统计一致；`checkup` 的系统设置和 helper 提示一致，Coop 额外保留 `git-bash` 损坏入口提示。测试产生的 PATH 项已撤销，最终核对没有遗留本对照的目录项。
