# 固定 Extras bucket 辅助脚本

本目录保存只被 `tests/hooks.ps1` 使用的真实 bucket 脚本资源，方便在项目内运行 `notepadplusplus` 的 `post_install` Hook，而无需联网或修改真实 bucket。

| 文件 | 来源 | SHA256 |
| --- | --- | --- |
| `install-context.reg` | `https://github.com/ScoopInstaller/Extras/blob/8b42c8c3140ca34ed718704189d97e1da7b3c315/scripts/notepadplusplus/install-context.reg` | `2957865501223f2167a7da51196157a1138c8ad09819ad536beef5b97b19cf13` |
| `uninstall-context.reg` | `https://github.com/ScoopInstaller/Extras/blob/8b42c8c3140ca34ed718704189d97e1da7b3c315/scripts/notepadplusplus/uninstall-context.reg` | `601a517c9be3b341e46692035130d094ed1613f55e78cb61d86dff774947d0e0` |

固定修订与 [样本索引](../index.json) 的 Extras 修订一致。文件按真实 Manifest 的 `post_install` 读取路径放在测试 bucket 的 `extras/scripts/notepadplusplus/` 下。测试只读取并改写文件内容写入项目内隔离根目录，不执行 `reg import`，不修改注册表或真实用户环境。
