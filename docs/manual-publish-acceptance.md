# 产物发布的人工验收步骤

2026-10-28 建立。用于**人**手工核对产物发布接缝：一份归档产物只写一遍、三条契约真的生效、失败后还能恢复。自动化判据在 `tests/publish-*.ps1`，本文是它们的对照物——手测能看到的和看不到的，都写在下面。

术语见 [GLOSSARY.md](../GLOSSARY.md) 的「产物发布」，技术行为见 [普通归档的原生生命周期覆盖](archive-support.md)。

## 前置

```powershell
cd D:\Projects\coop
./scripts/build.ps1 -Action build
./scripts/install-hooks.ps1     # 每个克隆一次
```

所有测试根都在 `.local\manual\` 下，属于项目内、可随时删除。

## 1. 正常安装

```powershell
$root = "D:\Projects\coop\.local\manual\root"
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$root/buckets/test/bucket" | Out-Null

$zip  = "D:\Projects\coop\.local\deps\test-archives\tidy-5.8.0-win64.zip"
@{ version='5.8.0'; url=([uri]$zip).AbsoluteUri
   hash=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
   extract_dir='tidy-5.8.0-win64\bin'; bin='tidy.exe' } |
  ConvertTo-Json | Set-Content "$root/buckets/test/bucket/tidy.json" -Encoding utf8

$exe = "D:\Projects\coop\.local\build\coop.exe"
& $exe --root $root install test/tidy
"exit=$LASTEXITCODE"
```

该看到：退出码 **0**；`apps\tidy\current` 存在；`& "$root\apps\tidy\current\tidy.exe" --version` 能跑。

## 2. 只写一遍

眼睛盯事务目录不可靠——临时树存在的时间很短。用两条可复核的事实：

```powershell
# 安装一个更大的包，同时在另一个窗口每 100ms 采样
Get-ChildItem "$root\.coop\transactions" -Recurse -Directory |
  Where-Object Name -like 'extract-*'
```

窗口里**应当始终为空**。

```powershell
# 每个相对路径只出现一次
$v = "$root\apps\tidy\current"
Get-ChildItem $v -Recurse -File |
  Group-Object { $_.FullName.Substring($v.Length) } | Where-Object Count -gt 1
```

真正的判据是 `ctest -R publish_write_once`：它在安装**期间**用文件系统监视器记录事务目录下创建的每一条路径，并断言从未出现 `extract-<n>` 树；同时要求监视器确实看到过 staging，避免"什么都没看到"式空断言。

## 3. 空的 `extract_dir` 必须失败

关键是**不声明 `bin`** 也要失败——否则失败来自下游的入口检查，解压契约本身没被验证。

```powershell
@{ version='1.0.0'; url=([uri]$zip).AbsoluteUri
   hash=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
   extract_dir='missing-dir' } |
  ConvertTo-Json | Set-Content "$root/buckets/test/bucket/empty.json" -Encoding utf8
& $exe --root $root install test/empty --json 2>&1 | Out-String
"exit=$LASTEXITCODE"                    # 必须是 1
Test-Path "$root\apps\empty\current"    # 必须是 False
```

错误信息里必须出现 `extract_dir` 与 `missing-dir`。

## 4. 条目碰撞必须失败

```powershell
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$c = "$root\collision.zip"
$z = [IO.Compression.ZipFile]::Open($c,'Create')
foreach ($n in 'd/a.txt','d/A.TXT') { $s=[IO.StreamWriter]::new($z.CreateEntry($n).Open()); $s.Write($n); $s.Dispose() }
$z.Dispose()
@{ version='1.0.0'; url=([uri]$c).AbsoluteUri; hash=(Get-FileHash $c -Algorithm SHA256).Hash.ToLower()
   extract_dir='d'; bin='a.txt' } |
  ConvertTo-Json | Set-Content "$root/buckets/test/bucket/collide.json" -Encoding utf8
& $exe --root $root install test/collide --json 2>&1 | Out-String
"exit=$LASTEXITCODE"                    # 必须是 1，且错误里带 collide 与碰撞路径
```

## 5. 多产物：第二个失败不能牵动第一个

```powershell
$lua = "D:\Projects\coop\.local\deps\test-archives\luajit-2.1.1791988261-1-any.pkg.tar.zst"
$b = [IO.File]::ReadAllBytes($lua); $t = "$root\truncated.tar.zst"
[IO.File]::WriteAllBytes($t, $b[0..([int]($b.Length*0.6))])   # 能打开、解到一半失败
@{ version='1.0.0'
   url=@(([uri]$zip).AbsoluteUri, ([uri]$t).AbsoluteUri)
   hash=@((Get-FileHash $zip -Algorithm SHA256).Hash.ToLower(), (Get-FileHash $t -Algorithm SHA256).Hash.ToLower())
   extract_dir=@('tidy-5.8.0-win64\bin','mingw64'); bin='tidy.exe' } |
  ConvertTo-Json -Depth 8 | Set-Content "$root/buckets/test/bucket/multi.json" -Encoding utf8
& $exe --root $root install test/multi --json 2>&1 | Out-String
"exit=$LASTEXITCODE"                    # 必须是 1，且不发布 current
Get-ChildItem "$root\.coop\transactions\*\payload" -Filter tidy.exe -Recurse | Select-Object FullName
```

最后那条是关键：第一个产物的 `tidy.exe` 必须还在 staging 里。它证明"失败只撤自己写入的范围"。

## 6. 恢复

```powershell
& $exe --root $root recover
Get-ChildItem "$root\.coop\transactions\*\journal.json" | ForEach-Object { Select-String -Path $_ -Pattern '"state"' }
```

## 7. 回归

```powershell
ctest --test-dir .local/build -R '^publish_' --output-on-failure   # 基线 / 契约 / 只写一遍
ctest --test-dir .local/build --output-on-failure                  # 全套
```

## 手测覆盖不到的

| 项 | 原因 | 由谁覆盖 |
| --- | --- | --- |
| 只写一遍的"没有第二棵树" | 采样会漏、偶发通过 | `publish_write_once` 的监视器 |
| 解压失败时的清理边界 | 失败后整体回滚，肉眼分不出删多删少 | 构造保证 + 审查 |
| 冷装耗时与本地开销 | 没有可归因的测量方法 | 待建（性能归因） |
| 输出与 Scoop 是否逐字一致 | 输出对齐尚未实现 | 待建 |

## 与自动化测试的对应

| 本文步骤 | 自动化 |
| --- | --- |
| 1 正常安装 | `tests/publish-baseline.ps1`（10 份快照逐字节比对） |
| 2 只写一遍 | `tests/publish-write-once.ps1` |
| 3–5 三条契约 | `tests/publish-contracts.ps1` |
| 6 恢复 | `tests/recovery-matrix.ps1` |
| 7 回归 | 全套 CTest |
