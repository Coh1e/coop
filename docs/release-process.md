# 发布流程

本页是打 `v*` tag 的人工发布清单。发不发、发哪个版本、说明怎么写仍然由人决定；本页只固定动作与顺序，避免每次从 workflow、脚本和上一版发布记录反向重建。产品侧的发布接缝验收见 [产物发布的人工验收步骤](manual-publish-acceptance.md)。

## 前置条件

- `main` 干净，CI 绿（`gh run list -L 5`）。
- 版本号已定：0.x 阶段，新增能力用 minor，只修缺陷用 patch。
- [release-check.ps1](../scripts/release-check.ps1) 会拒绝脏树、拒绝与 `CMakeLists.txt` 不一致的版本号、拒绝已存在的 tag（除非 `-Force`）。

## 步骤

1. **改版本号并提交。** `CMakeLists.txt` 的 `project(coop VERSION <版本>)` 与 `README.md` 的当前版本两处同时改；单独提交为 `release: <版本>`，不夹带代码。
2. **过门禁。** `./scripts/release-check.ps1 -Version <版本>`：构建全部 target、跑全套 CTest、核对 `coop --version`、检查安装占用。`-SkipTests` 只用于复验已发版本，不能用于首发。
3. **打 tag 并推送。** `git tag -a v<版本> -m "coop v<版本>"`，再 `./scripts/push.ps1 origin main v<版本>`。裸 `git push` 在本机必失败，原因与替代路径见 [本机环境](agents/environment.md)。
4. **等 Release workflow。** tag 推送触发 [release.yml](../.github/workflows/release.yml)：构建、核对二进制版本、打包并解包 smoke test、创建 Release。**它不跑测试**，测试把关只来自第 2 步和 `main` 的 CI。
5. **更新 Scoop bucket。** `Coh1e/scoop-bucket` 的 `bucket/coop.json` 改三处：`version`、`architecture.64bit.url`、`architecture.64bit.hash`（资产的 SHA256）。提交 `coop: update to <版本>` 并推送。**漏掉这步时 `scoop install` 仍拿旧版本。**
6. **写发布说明。** workflow 生成的是英文提交列表；按项目习惯换成中文，先写到 `.local/release-notes-<版本>.md`（不提交），再 `gh release edit v<版本> --notes-file .local/release-notes-<版本>.md`。至少写清：本版内容、验证结果、已知未验证项、bucket 是否已同步。
7. **复核四项。** 都对上才算发完：
   - `gh release view v<版本>` 有资产且大小合理；
   - 下载资产解包后 `coop --version` 报 `coop <版本>`；
   - `git ls-remote origin refs/tags/v<版本>` 指向发布提交；
   - bucket 清单的 `hash` 等于资产 SHA256。

## 失败与回滚

- 第 2 步失败：修完重跑；tag 还没打，没有对外状态。
- tag 已推、workflow 失败：先删远端 tag（`git push origin :refs/tags/v<版本>`）再重来，不移动已发布的 tag。
- Release 已建、内容有误：说明用 `gh release edit` 改；资产要换就重建 Release，不覆盖同名资产。
- 已发布版本发现缺陷：发下一个 patch，不在原 tag 上改。

## 为什么不是一键脚本

发布链里每一步都有人类判断：发不发、版本号、说明措辞、bucket 时机。把这些合成一个 `release.ps1` 会绕开这道闸门。等步骤连续多次不再变化，再把机械部分收进脚本——先有 runbook，后有脚本。
