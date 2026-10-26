# 固定 Main bucket 辅助脚本

本目录保存只被 `tests/hooks.ps1` 使用的真实 bucket 脚本资源，方便在项目内运行 `git` 的 `post_install` Hook，而无需联网或修改真实 bucket。

| 文件 | 上游 blob（`main` 修订 `a97619fec75f0c74bd74e73b0e9138df08687a50`） | SHA256（本目录字节） |
| --- | --- | --- |
| `install-associations.reg` | `49cb38b5ad136dfaf30bb54dad1077ca8e48fe33` | `2dfb6affd5bb23309a19086aa7fb80d9db4549b9b567b3f93738ca1dc3cb7bc5` |
| `install-context.reg` | `deece89d4958ec2fcdc78a113ca5f5da643f95f5` | `af108def2f842c6d59247407ff216d4544988d3395bf97beb9b594f31158306d` |
| `uninstall-associations.reg` | `9ddf488fc5f829d5f5350dba46ddcb62aab9bccc` | `772965963e5a4e9c2d9de15fff03f53df036783ace98782e4828b7cabfff53b0` |
| `uninstall-context.reg` | `e22e0260ddd457066223bf742af11d2f2893cb47` | `19eafc0163fdb3a95ca6f095b5832031f22d6e9ca3846e2ec1210dc2324a80d6` |

每个 Git blob 与上游 `scripts/git/<文件>` 完全相同（LF，`.gitattributes` 标记为 `-text`，不转换换行）。文件按真实 Manifest 的 `post_install` 读取路径放在测试 bucket 的 `main/scripts/git/` 下。测试只读取并改写文件内容写入项目内隔离根目录，不执行 `reg import`，不修改注册表或真实用户环境。
