# 旧版本保留、回退、清理与数据彻底删除

日期：2026-10-27。状态：R15（#36）实现与运行验证记录。范围是当前用户级安装；系统级根仍不修改。持久化映射本身见[持久化数据支持](persistence-support.md)。

## 1. Scoop 语义依据

- 更新默认保留旧版本目录，Scoop 与 Coop 都从 `apps/<包>/<版本>` 的实际文件、保存的 Manifest 和安装记录识别本地版本。
- Scoop 的 `reset` 只重新发布已安装版本：切换 `current`、重新建立持久化链接、入口、快捷方式与环境，不重新下载，也不再执行安装 Hook。
- Scoop 的 `cleanup` 只删除本机保留的旧版本；卸载默认保留 `persist` 存储，彻底删除是独立请求。
- 规格 #21 明确：远端历史版本查找不在范围内；缺失版本必须失败，不猜测下载 URL；程序回退不承诺数据回退。

## 2. 本地版本证据

回退和清理都只使用本机可核对的事实：

- `apps/<包>/<版本>/scoop-manifest.json`（Scoop 安装也可能是 `manifest.json`）及其保存的版本；
- 同目录的 `scoop-install.json`（或 `install.json`）中的 bucket、架构与来源；
- 实际程序文件和声明入口目标；
- 存在时，Coop 管理记录 `.coop/packages/<包>.json` 中记录的 Manifest 摘要、安装记录摘要和目录树摘要。

没有 Coop 私有版本记录、但保存的 Manifest 与安装记录一致且实际产物可校验的本地版本仍可用于回退；这不要求先 `adopt`。没有保存 Manifest 或安装记录的目录不会被用来回退，也不会被清理删除。

## 3. 程序回退：`coop reset <包名>@<版本>`

```powershell
coop reset 7zip@26.03 --dry-run --json
coop reset 7zip@26.03 --json
```

预览与实际执行消费同一份 IR 操作序列：

1. 解除当前 `current` 发布；
2. 移除被替换版本的入口、快捷方式和仍归属该包的环境值；
3. 把 `current` 指向已存在的本地版本目录，不下载、不解压；
4. 核对并原地复用旧版本已声明的持久化链接；
5. 重建旧版本的入口、快捷方式与环境；
6. 提交安装记录，把被替换版本写为本机保留版本。

输出明确区分：

- `local_version_reference.network = "none"`、`download_url_guessed = false`；
- `lifecycle_hooks = "not-run"`、`declared_installer_program = "not-run"`；
- `reset_from` 为被替换版本，`retained_versions` 为仍保留的本机版本；
- `data_rollback = "none"`：保留旧程序不等于持久化数据回到旧状态。

拒绝条件（预览 `execution_available=false`，执行非零，当前程序不变）：

- 目标版本目录不存在、是 reparse point，或缺少保存的 Manifest/安装记录；
- 保存的 Manifest 版本与目录名不一致，或实际产物摘要不匹配；
- 存在 Coop 版本记录但 Manifest、安装记录或目录树摘要已被修改；
- 目标就是当前版本；
- 持久化映射与当前版本不同，或旧版本的已声明链接缺失、被重定向；
- 声明依赖未安装、当前安装/入口/持久化事实无法核对，或存在 pending 事务。

`reset` 不运行 `pre_install`/`post_install` 等 Hook，也不运行声明的 installer 程序；这些外部副作用在安装/更新时已经发生，回退不重放。入口和持久化链接冲突在写入前失败。

## 4. 旧版本清理：`coop cleanup [包名...]`

`coop cleanup --dry-run --json` 输出可核对的删除范围：

- `delete_scope`：每个候选版本的绝对路径、Manifest/安装记录摘要、目录树摘要和计划操作；
- `keep_scope`：当前版本和所有不满足条件的版本及原因；
- `current`：已发布当前版本；
- `scope_summary`：删除、保留和已缺失的数量；
- 每个版本仍保留完整证据字段（`status`、`reason`、`recorded`、`provenance` 等）。

实际执行先恢复中断的清理事务，再重新核对同样的证据，只移动并删除 `delete_scope` 中的目录。清理候选必须同时满足：

- 管理记录或卸载保留证据中登记过；
- Manifest、安装记录和目录树摘要未被修改；
- 不是已发布 `current`，也不是管理记录中的当前版本；
- 没有 pending 事务可能需要它；
- 目录本身不是 reparse point。

当前版本、未记录目录、缺失历史 Manifest、被用户修改的版本、被占用而无法移动的版本都会保留并报告原因，不强制结束进程。删除时遇到持久化 junction/reparse point 只解除链接，不跟随到 store 或其他外部内容。

## 5. 显式数据彻底删除：`coop uninstall <包名> --purge`

- 普通 `uninstall` 保留声明的持久化数据并保留旧版本目录。
- `--purge` 是独立请求；预览列出每个声明映射的 `source`、`target`、`store`、`link`、类型和文件身份。
- 执行前重查管理记录、链接归属和 store 身份；链接被重定向、记录变化或 store 变成链接时，在任何删除前失败。
- 删除只作用于声明的 store 目标；`persist/<包名>` 下未声明内容、store 内 junction 指向的外部内容和其他用户数据保持不变。

详细契约与 #30 真机证据见[持久化数据支持](persistence-support.md)。

## 6. 验证

本地自动化：`tests/old-versions.ps1`（CTest `old_versions`）覆盖：

- 删除 bucket Manifest 后仍可从本地版本回退，计划无 `download`/`verify`/`extract`，执行步骤与 journal 一致；
- 回退后当前程序、保留版本和查询结果正确，清理预览只列出保留版本并保护当前版本；
- 目标缺失、已是当前、目录树被修改、保存 Manifest 缺失、版本目录是 reparse point 时拒绝回退；
- 持久化 store 内容、链接目标不变；链接被重定向或缺失时拒绝回退；
- 保留版本的 `pre_install` Hook 不因回退重跑；
- 没有 Coop 版本记录但保存证据完整的本地版本可回退，清理仍保护当前版本。

真机共用根：`tests/real-scoop-old-versions.ps1` 在人工选定的本机 Scoop 根内创建临时 bucket 与测试包，顺序执行 Coop 安装 → Scoop list/reset → Coop 更新 → Scoop reset → Coop 回退 → Scoop reset → Coop cleanup → Coop `uninstall --purge`，最后清理测试对象并核对根内既有 15 个包清单不变。本轮运行的命令、退出码、`summary.json`、清理范围和执行前后清单保存在 `.local/pi/tasks/36/evidence/real-old-versions-run4/`；`summary.json` 记录 `coop_sha256`，`reset` 的 planned 与 observed 操作均为 `unlink-current,remove-entries,publish-current,persistence,entries,commit-state`，Scoop 在 Coop 回退后仍能 `reset` 并运行 v1，清理只删除保留的 v2，持久化 store 在 cleanup 后仍在、在 purge 后只删除声明的 `config`。

未运行/不在范围：

- 从远端历史查找本机从未安装的版本；
- 自动回退持久化数据内容；
- 自动连带删除旧版本或疑似无用依赖；
- 两客户端同时写入同一状态；
- 系统级安装的旧版本清理、回退与彻底删除。
