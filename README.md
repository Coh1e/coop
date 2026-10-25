# Coop

Coop 是设计中的 C++20 Windows 原生软件包管理器，优先接管现有用户级 Scoop 安装，复用其 bucket 与 Manifest 生态。

当前已具备最小原生 CLI（版本与帮助），包管理功能正在按任务图实现，尚不能用于真实迁移。开发工具与生成数据遵循项目内存放约定，仓库中的 devkit 用作场景参考，其用户级安装脚本不是本项目的环境准备入口。

- [已确认的产品范围](docs/design-scope.md)
- [首版正式规格](https://github.com/Coh1e/coop/issues/2)
- [设计背景、验收路径与下一步](docs/architecture.md)
- [Git 库选择方向](docs/adr/0001-use-embedded-git-library.md)
- [Scoop Git 调用审计](docs/research/scoop-git-command-audit.md)
- [goop 实现对照](docs/research/git-free-buckets.md)
- [GitHub 任务与规格](https://github.com/Coh1e/coop/issues)

开发需要已有 MSVC x64 Build Tools、Windows SDK、CMake 3.25+、Ninja 和 PowerShell。运行 `./scripts/build.ps1` 配置、构建并测试，产物在被忽略的 `.local/build`，临时文件在 `.local/tmp`。脚本只在编译子进程中加载 MSVC 环境并设置临时目录，不修改用户或系统环境。

可运行 `.local/build/coop.exe --version` 或 `--help`；无效参数退出码为 2，正常命令为 0。测试通过真实 CLI 检查输出与退出码，另使用 Windows 调试事件观察版本/帮助命令没有启动子进程。当前无安装命令。
