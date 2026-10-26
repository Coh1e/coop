# Coop

Coop 是与 Scoop 共用安装与状态的 Windows 原生软件管理客户端。以下术语用于描述共同的安装事实与行为兼容。

## Language

**行为兼容（Behavior Compatibility）**：在约定的软件范围内，同一软件由 Coop 与 Scoop 管理时，安装、更新、卸载以及入口、环境和持久化数据的用户可观察行为保持一致。具体例外须明确约定。

**共用管理（Shared Management）**：Coop 与 Scoop 基于同一套软件安装、数据和记录先后执行管理操作，双方能继续识别对方产生的结果。共用管理不包含同时写入的承诺。

**安装事实（Installation Facts）**：软件当前版本、文件、入口、数据及安装记录所共同描述的实际状态，不因使用哪个兼容客户端而改变其管理资格。

**持久化数据（Persistent Data）**：Manifest 的 `persist` 声明、存放在版本目录之外的配置或内容。普通卸载保留这些数据；链接归属必须可验证，链接本身不是数据本体。

**依赖（Dependency）**：Manifest `depends` 明确声明的另一个软件包，可限定 bucket。安装时先解析并安装依赖，已安装依赖跳过；不从脚本、用户项目或 Coop 自身工具需求推断依赖。

**反向依赖（Reverse Dependency）**：已安装包的保存 Manifest 声明依赖目标包的关系。包括由 Scoop 安装的软件在内，已知反向依赖方会阻止普通卸载，卸载保护不使用猜测或自动连带删除。

**命令入口（Command Entry）**：软件包声明、供用户和其他程序启动该软件的命令及其参数约定，可由兼容客户端维护。

**快捷方式归属（Shortcut Ownership）**：软件包与其快捷方式的可验证对应关系，用于确定管理操作的范围并保护用户自行修改的入口。

**环境暴露（Environment Exposure）**：软件包声明的 PATH、环境变量与使用入口在用户环境中的可用性；约定范围内与 Scoop 的用户级效果一致。环境变更归属用于区分包管理器负责的值与用户后来修改的值。

**生命周期 Hook（Lifecycle Hook）**：Manifest 在安装、更新和卸载阶段声明的脚本，包括 `pre_install`、`post_install`、`pre_uninstall`、`post_uninstall`、`installer.script`、`uninstaller.script`。其阶段含义、上下文和先后关系以约定的 Scoop 兼容基准为准。

**已验证行为（Verified Behavior）**：已有可复现证据证明符合约定兼容语义的软件管理行为。它描述当前验证状态，不定义产品的目标兼容上限。
