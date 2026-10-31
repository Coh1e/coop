# 升级到 C++23 并显式声明 MSVC 底线

2026-10-31 人类决定把 C++ 标准从 20 升到 23。现有代码只用到 C++20 的 `starts_with`/`ends_with`（71 处）与关联容器 `.contains`（约 20 处），没有任何 C++23-only 构造；四个 fixture 目标（`fixture-1/2`、`fixture-gui`、`fixture-env`）当前没有设标准，实际按 MSVC 默认的 C++14 编译。CMake 3.25 已认识 `cxx_std_23`（3.20 起），对 MSVC 映射为 `/std:c++latest`；`/std:c++23` 不存在，`/std:c++23preview` 是未文档化开关，不采用。

因此标准固定为：所有 C++ 目标（含四个 fixture）使用 `cxx_std_23`；configure 时 `MSVC_VERSION < 1930` 直接失败；CMake 最低版本保持 3.25；接受 `/std:c++latest` 会随工具链漂移，所以 CI 必须打印 `cmake`、`cl`、`ninja` 版本。当前不要求使用 C++23 库特性，`std::expected`/`std::print` 等按实际工具链可用性选用。

## Consequences

- `/std:c++latest` 在 `/WX` 下会随新工具链引入新的弃用与诊断；升级 CI 镜像时必须读构建日志，不能只看绿。
- 底线只保证语言模式与编译开关，不保证每个 C++23 库特性；使用特定库特性的代码要在使用处说明所需工具链。
- `docs/design-scope.md` 的“保持 C++20”改为 C++23，属于人类已批准的范围变更。
