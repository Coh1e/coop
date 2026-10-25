# Coop

Coop 是设计中的 C++20 Windows 原生软件包管理器，优先接管现有用户级 Scoop 安装，复用其 bucket 与 Manifest 生态。

目前尚无可构建或运行的 Coop 实现；未执行真实迁移。开发工具与生成数据遵循项目内存放约定，仓库中的 devkit 用作场景参考，其用户级安装脚本不是本项目的环境准备入口。

- [已确认的产品范围](docs/design-scope.md)
- [首版正式规格](https://github.com/Coh1e/coop/issues/2)
- [设计背景、验收路径与下一步](docs/architecture.md)
- [Git 库选择方向](docs/adr/0001-use-embedded-git-library.md)
- [Scoop Git 调用审计](docs/research/scoop-git-command-audit.md)
- [goop 实现对照](docs/research/git-free-buckets.md)
- [GitHub 任务与规格](https://github.com/Coh1e/coop/issues)

环境准备、构建与运行说明将在可行性验证后补充；当前没有安装命令。
