# Coop

Coop 管理 Windows 软件包，并接管已有 Scoop 安装。以下术语用于区分安装事实与管理权限。

## Language

**接管（Adoption）**：将已有软件安装纳入 Coop 管理的过程；接管完成不需要重新下载或安装该版本。

**渐进接管（Progressive Adoption）**：允许同一安装集合中，已完成检查的包进入管理，其余包保持可查看、可运行但尚未接管的状态。

**已接管包（Adopted Package）**：Coop 已确认能够管理其生命周期的软件包安装。

**未接管包（Unadopted Package）**：Coop 已识别但尚未取得生命周期管理资格的软件包安装；不能通过 Coop 更新或卸载。
