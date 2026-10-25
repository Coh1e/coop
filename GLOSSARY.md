# Coop

Coop 管理 Windows 软件包，并接管已有 Scoop 安装。以下术语用于区分安装事实与管理权限。

## Language

**接管（Adoption）**：将已有软件安装纳入 Coop 管理的过程；接管完成不需要重新下载或安装该版本。

**渐进接管（Progressive Adoption）**：允许同一安装集合中，已完成检查的包进入管理，其余包保持可查看、可运行但尚未接管的状态。

**已接管包（Adopted Package）**：Coop 已确认能够管理其生命周期的软件包安装。

**未接管包（Unadopted Package）**：Coop 已识别但尚未取得生命周期管理资格的软件包安装；不能通过 Coop 更新或卸载。

**持久化数据（Persistent Data）**：Manifest 的 `persist` 声明、存放在版本目录之外的配置或内容。普通卸载保留这些数据；链接归属必须可验证，链接本身不是数据本体。

**依赖（Dependency）**：Manifest `depends` 明确声明的另一个软件包，可限定 bucket。安装时先解析并安装依赖，已安装依赖跳过；不从脚本、用户项目或 Coop 自身工具需求推断依赖。

**反向依赖（Reverse Dependency）**：已安装包的保存 Manifest 声明依赖目标包的关系。已知反向依赖方（包括未接管安装）会阻止普通卸载，卸载保护不使用猜测或自动连带删除。
