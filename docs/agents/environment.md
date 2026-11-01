# 本机环境与已知坑

本页记录这台开发机上从代码里看不出来的事实。遇到对应症状时先看这里，不要从错误信息反推。

## 推送到 GitHub

裸 `git push` 在本机必败，报 `schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS`：凭据助手是 Git Credential Manager，非交互拿不到凭据。把助手换成 `!gh auth git-credential` 会换一种失败：助手经由 `sh.exe` 启动，沙箱下报 `couldn't create signal pipe, Win32 error 5`。

可用的路径是把 `gh auth token` 作为 `http.https://github.com/.extraheader` 传进去，并用 `openssl` 后端。已经封装成 [scripts/push.ps1](../../scripts/push.ps1)，参数与 `git push` 相同：

```powershell
./scripts/push.ps1
./scripts/push.ps1 origin main v0.3.0
```

## `.git` 写入被拒绝

症状：仓库根目录可写，`.git` 下不可写；提交报 `fatal: Unable to create '.../.git/index.lock': Permission denied`。这不是残留锁，删 `index.lock` 没有用。

原因是 `.git` 生效的 ACL 里没有当前用户的条目，常见于沙箱会话或外部安全产品改过 ACL。用 `diagnose-windows-sandbox-acl` 技能修：它按路径证明问题、补回当前用户、移除外来条目，并把修复记录写到你指定的输出目录。修完直接重试提交。

修复验证通过、同一个操作仍被拒绝时，先看会话的写入模式：`workspace-write` 下构建产物目录（例如 `.local/build/Testing/Temporary`）也可能写入失败，切到完全权限（full access）后同一命令通过，才说明是沙箱限制而不是 ACL 问题。

## `gh` 的 `--jq` 与双引号

`--jq` 表达式里带双引号时，参数会被拆开，报 `accepts 1 arg(s), received 2` 或 `accepts at most 1 arg(s), received 3`。表达式里不要写双引号，或者直接用 `ConvertFrom-Json`：

```powershell
gh api repos/Coh1e/coop/commits/main | ConvertFrom-Json |
    ForEach-Object { "$($_.sha.Substring(0,7)) $($_.commit.message)" }
```

## native 命令的 stderr

`git` 的进度行（`To https://…`、`Cloning into…`）在 Windows PowerShell 5.1 下会显示成 error record，即使退出码是 0。按退出码判断，不要按输出颜色判断；这条约束的由来见 [CODING_STANDARDS](../../CODING_STANDARDS.md#L37)。
