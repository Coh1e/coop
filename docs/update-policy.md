# 软件更新判定

任务 [#105](https://github.com/Coh1e/coop/issues/105)，父规格 [#102](https://github.com/Coh1e/coop/issues/102)。status、更新预览和实际更新共用 `decide_update`；执行计划保存判定，执行器不再另算版本或摘要条件。

| 判定 | 普通 update | update --force |
|---|---|---|
| update-available：目标更高 | 更新 | 更新 |
| current：同版且清单未变 | 无需操作 | 同版重装 |
| manifest-changed：同版清单改变 | 提示使用 --force，无需操作 | 同版重装 |
| downgrade-blocked：目标更低 | 阻断 | 阻断 |
| version-incomparable：无法可靠比较 | 报告无法判断并阻断 | 同样阻断 |
| held-package：共享安装记录已 hold | 阻断，须先 unhold | 同样阻断 |

无需操作退出 0，不替换软件文件、current、入口或安装记录；现有写命令运行记录机制不因此改变。更新阻断退出 1。预览 JSON 的 `update_decision` 提供 state、changes_installation、blocked、message；文本预览也显示原因。旧 status JSON 保留软件数组和原字段；最新版本列只把可升级的目标列为更新，其余情况在 Info 中提示。status JSON v2 提供结构化判定，不把版本不同等同于可升级。

版本比较接受数字分段（如 1、1.10、2026.11.03），可选小写 v 前缀；数字按数值比较而非字典序，末尾缺省分段视为 0。比较不转换为固定宽度整数，因此长数字不溢出。带预发布或 build metadata 的版本使用标准 SemVer 三段核心，核心和纯数字预发布标识不接受多位前导零。稳定版高于同核心版本的预发布版，预发布数字按数值、其他标识按 ASCII 字典序，build metadata 不参与顺序。无后缀的数字段允许前导零，以支持日期等常见版本。

不同的非上述版本写法保守报告无法比较，例如 nightly 与 latest、1.0a 与 1.0b；不会猜测日期后缀或厂商命名顺序。完全相同的非空版本字符串可识别为同版；空版本无法判断。清单是否改变按实际已装保存清单与目标清单的 SHA256 判断，不依赖 Coop 私有记录。

本判定只限制普通 update；install 与本地 reset/回退保留各自既有语义。来源刷新、客户端更新、完整远端 status 和 update JSON v2 由其他任务交付，本任务不提前实现。

验证：CTest `update_policy_module` 覆盖数字边界、预发布、无法比较和 force/hold；`update_policy` 在隔离根执行真实安装、预览、更新与程序启动，验证普通同版不重装、强制同版重装、降级/无法比较/hold 不写软件、较高版本真实替换以及 install 不被误约束。既有 reset、force 恢复和更新输入变化测试继续约束原有保护。
