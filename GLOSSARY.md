# Coop

Coop 是与 Scoop 共用安装与状态的 Windows 原生软件管理客户端。以下术语用于描述共同的安装事实与行为兼容。

## Language

**行为兼容（Behavior Compatibility）**：在约定的软件范围内，同一软件由 Coop 与 Scoop 管理时，安装、更新、卸载以及入口、环境和持久化数据的用户可观察行为保持一致。具体例外须明确约定。

**共用管理（Shared Management）**：Coop 与 Scoop 基于同一套软件安装、数据和记录先后执行管理操作，双方能继续识别对方产生的结果。共用管理不包含同时写入的承诺。

**兼容布局（Compatible Layout）**：双方共用的安装根目录结构，包括 `apps`、`buckets`、`cache`、`persist`、`shims` 及其中的标准安装记录、入口和数据；Coop 不为自身另建一套需要先接管或迁移的根结构。

**独立初始化（Independent Initialization）**：在没有 Scoop 的机器或全新安装根上，由 Coop 直接建立兼容布局并完成安装与管理，不要求预装 Scoop、Git 或 7-Zip，也不依赖 Scoop 先创建状态；之后安装的 Scoop 能在同一根识别并继续管理这些软件。

**安装事实（Installation Facts）**：软件当前版本、文件、入口、数据及安装记录所共同描述的实际状态，不因使用哪个兼容客户端而改变其管理资格。

**安装后占用（Installed Footprint）**：一次发布在安装根落盘的全部字节，由可执行文件与随包数据（兼容库、许可与第三方声明文本）组成。它与**下载包**（发布 zip）是两个口径：体积预算、守卫与报告按安装后占用判定，下载体积只作记录。

**持久化数据（Persistent Data）**：Manifest 的 `persist` 声明、存放在版本目录之外的配置或内容。普通卸载保留这些数据；链接归属必须可验证，链接本身不是数据本体。

**本地版本回退（Local Version Rollback）**：把 `current` 重新发布到本机已存在且证据完整的版本目录，并从该版本保存的 Manifest 重建入口、快捷方式、环境与持久化链接。它不联网、不猜测历史下载地址、不重跑安装 Hook 或安装器程序，也不承诺持久化数据回到旧状态。

**依赖（Dependency）**：Manifest `depends` 明确声明的另一个软件包，可限定 bucket。安装时先解析并安装依赖，已安装依赖跳过；不从脚本、用户项目或 Coop 自身工具需求推断依赖。

**依赖来源 bucket（Dependency Source Bucket）**：请求包所在 bucket 之外、只用于解析其声明依赖的官方 bucket（如 `versions`）。它按固定来源与 40 位修订登记，用于证明跨 bucket 依赖可解析，但不进入 Main/Extras 兼容分母，也不改变环境本身必须注册该 bucket 的前提。

**反向依赖（Reverse Dependency）**：已安装包的保存 Manifest 声明依赖目标包的关系。包括由 Scoop 安装的软件在内，已知反向依赖方会阻止普通卸载，卸载保护不使用猜测或自动连带删除。

**命令入口（Command Entry）**：软件包声明、供用户和其他程序启动该软件的命令及其参数约定，可由兼容客户端维护。

**快捷方式归属（Shortcut Ownership）**：软件包与其快捷方式的可验证对应关系，用于确定管理操作的范围并保护用户自行修改的入口。

**环境暴露（Environment Exposure）**：软件包声明的 PATH、环境变量与使用入口在用户环境中的可用性；约定范围内与 Scoop 的用户级效果一致。环境变更归属用于区分包管理器负责的值与用户后来修改的值。

**PowerShell 模块暴露（psmodule）**：Manifest `psmodule` 声明把已安装版本出版为 `<root>/modules/<name>` 目录 junction，并把 `<root>/modules` 放到当前用户 `PSModulePath`。条目按路径列表项归属：Coop 只撤销自己新增的那一条，其他条目与用户后续修改保持。

**生命周期 Hook（Lifecycle Hook）**：Manifest 在安装、更新和卸载阶段声明的脚本，包括 `pre_install`、`post_install`、`pre_uninstall`、`post_uninstall`、`installer.script`、`uninstaller.script`。其阶段含义、上下文和先后关系以约定的 Scoop 兼容基准为准。

**安装器程序（Installer Program）**：Manifest 的 `installer`/`uninstaller` 对象通过 `file`/`args`（可带 `keep`）声明的外部程序，与 `installer.script`/`uninstaller.script` 脚本区分。它由真实 PowerShell 调用固定的 Scoop `Invoke-Installer` 执行，在版本目录运行并使用 Scoop 的参数替换与删除语义；程序自身的外部副作用属于未知范围，不承诺回滚。

**MSI 镜像提取（MSI Image Extraction）**：对 Manifest 中 `.msi` 产物执行 Scoop `Expand-MsiArchive` 对应的管理镜像提取：从只读的 Windows Installer 数据库表推导目录、文件与 cabinet 布局，再用 Windows cabinet 解压 API 展开内嵌 cabinet。它不等同于运行厂商安装器，不启动 `msiexec`、不注册产品、不改写 `%WINDIR%\Installer` 机器缓存，也不需要管理员权限或重启；外部 cabinet、多段 cabinet 与厂商安装器载荷不在此能力内。

**Inno Setup 提取（Inno Setup Extraction）**：对声明 `innosetup` 的 `.exe` 产物，使用安装在选中 root 内的外部 innounp helper，按 Scoop `Expand-InnoArchive` 相同的参数与 `-c` 选择解包声明的 Inno 目录。helper 是包机制所需的外部软件依赖，不是 Coop 核心依赖：Coop 检测它、复用它，但从不下载、安装或内嵌它；缺失时预览给出具名问题（内容条件未定时不强行阻断），执行在摘要校验后、发布任何版本或共用记录前具名失败并回滚。厂商安装器本身不会运行，因此 `[Run]`、注册表、服务、快捷方式和卸载登记等安装器副作用不在此能力内。

**NSIS 安装器载荷提取（NSIS Installer Payload Extraction）**：Manifest 通过 `#/dl.7z` 之类的改名把可执行自解压器声明为归档产物时，Coop 在摘要校验后检查载荷内容；命中 NSIS FirstHeader 签名（`DE AD BE EF` + `NullsoftInst`）才使用安装在选中 root 内的外部 7-Zip helper，按 Scoop `Expand-7zipArchive` 相同的参数（`-xr!*.nsis`、`-y`，声明时追加 `-ir!<extract_dir>\*`）解包。其他载荷仍由原生解压路径处理；helper 从不下载、安装或内嵌，缺失时在摘要校验后、发布版本前具名失败并回滚。厂商 `setup.exe` 不会运行，因此其安装目录、注册表、服务、快捷方式和卸载登记等副作用不在此能力内。

**Scoop 兼容库（Scoop Compatibility Library）**：随 Coop 分发、与固定 Scoop 修订逐字节一致的 PowerShell 库副本，为生命周期 Hook 提供 Scoop 的上下文变量与辅助函数语义，而不是另建一套缩水实现。

**待恢复事务（Pending Transaction）**：Coop 写入前记录、尚未提交或回滚的包操作。异常退出后它阻止新的写入但保持查询可用，恢复只处理日志确认属于 Coop 的创建项与移动项，不把进程退出当作成功。

**所有权证据（Ownership Evidence）**：Coop 在创建文件系统对象时记入事务日志的对象身份（卷序列号与文件索引）、文件摘要或链接目标，用于在恢复前确认识别到的仍是 Coop 创建的那个对象，而不是另一客户端或用户替换、修改的结果。

**冲突诊断（Conflict Diagnosis）**：恢复发现所有权证据不符、移动端点同时存在/缺失、环境值已被用户修改等情况时，用稳定代码报告具体外部变化并保持 pending 或保留较新值，而不是删除、覆盖或宣称已完整恢复。

**已验证行为（Verified Behavior）**：已有可复现证据证明符合约定兼容语义的软件管理行为。它描述当前验证状态，不定义产品的目标兼容上限。

**下载缓存（Download Cache）**：`<根>/cache` 中由 Scoop 与 Coop 共用的下载产物。命中前必须按 Manifest 声明的算法与摘要校验；校验失败视为未命中并重新下载，缓存缺失或损坏不改变安装事实。缓存是共享基础设施的一部分，不是 Coop 私有状态。

**进度反馈（Progress Feedback）**：写命令在执行期间向终端报告当前阶段与阶段内进度（下载、校验、解压、发布入口、提交）。它只影响人类可读输出，不改变计划、执行顺序或退出码；`--json` 不含进度。

**产物发布（Artifact Publication）**：把一个已校验的下载产物按其解压与布局规则写入事务 staging 的单一操作：消费 `extract_dir` 与 `extract_to`、决定是否需要先把载荷解到自己的工作树、并产出该次发布要写进事务日志的记录。它与**发布入口**不同：产物发布处理的是归档产物落到 staging，发布入口处理的是程序命令与快捷方式落到用户可见位置。四类产物（原生归档、MSI 镜像、Inno Setup、NSIS 载荷）都是它的实现，`execute.cpp` 的执行步骤只调用它一次、不按格式分支；格式分支位于接缝内部。
