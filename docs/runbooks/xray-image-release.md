# Xray 镜像同步与发布操作手册

最后复核：2026-08-27 JST

## 1. 目标与边界

本仓库把 XTLS/Xray-core 官方 GitHub Releases 同步为
`taoziyoyo2566/xray-docker` 多架构镜像。活动窗口定义为：

1. GitHub Releases API 中按发布时间从新到旧的第一个非 draft stable；
2. 该 stable 之前所有更新的非 draft prerelease；
3. 不自动补建更早的历史窗口，但已经发布的不可变标签继续保留。

同步只写 Docker Hub，不部署 VPS、不修改 Ansible 镜像引用、不清理旧标签。Git 合入、
首次大批量同步和标签清理是三个独立操作。

## 2. 标签契约

| 上游状态 | 镜像标签 |
|---|---|
| stable | `vX.Y.Z` |
| GitHub prerelease | `vX.Y.Z-beta` |

- 版本标签是移动别名，始终指向该上游版本当前最好的构建；
- `latest` 只指向当前 stable；
- beta 永不指向 `latest`；
- 镜像定义变化时无需人工登记：构建输入的指纹写在镜像 label
  `io.taoziyoyo.xray.build-inputs` 里，同步时比对不上即自动重建；
- GitHub 同一 tag 的官方 asset digest 如果变化，也必须创建新 `rN`，不得覆盖旧标签；
- 运行时和发布证据使用顶层 `sha256:` digest。

## 3. 同步工作流

`Sync Xray Release Images` 仅通过以下方式触发：

- `workflow_dispatch`：人工同步；
- 每日 `04:41 UTC` 定时同步。

合并代码本身不触发 registry 写入。工作流包含三个 job：

1. `discover`：读取官方 Release、官方资产 digest 和 Docker Hub 标签，生成缺失矩阵；
2. `build-missing`：串行逐个版本（`max-parallel: 1`），按 digest 推送、双架构验证，
   再创建不可变标签；
3. `reconcile-latest`：验证当前 stable，只有 digest 不一致时才移动 `latest`。

任何缺失版本失败都会阻止 `latest` 对账。候选镜像在验证前没有公开 tag。

### 3.1 自动发现机制

同步不是读取仓库中的固定版本号，而是每次运行重新计算：

1. GitHub Actions cron 或 `workflow_dispatch` 启动默认分支上的工作流；
2. `discover-release-window.sh` 使用本次 workflow 的只读 `github.token`，分页读取
   `GET /repos/XTLS/Xray-core/releases?per_page=100&page=N`；
3. API 结果按 GitHub 返回顺序从新到旧扫描，忽略 draft，在找到第一个 non-draft
   stable 后停止翻页；
4. 取该 stable 和它前面全部 non-draft prerelease，并校验两个官方资产 digest；
5. 分页读取 Docker Hub tags API，将期望的不可变标签与现有标签做集合差；
6. 差集成为 `build-missing` 动态矩阵；差集为空时不执行构建；
7. 矩阵全部成功后，`reconcile-latest` 才验证 stable 并按需移动 `latest`。


这意味着 GitHub Release 是版本范围和资产 digest 的事实来源，Docker Hub 是“是否已发布”
的事实来源，仓库只保存镜像修订覆盖表，不缓存“当前最新版”。发现器最多读取 10 页、
每页 100 条 Release；在该范围内找不到 stable 会失败，不会用不完整数据发布。

### 3.2 推送顺序与 Docker Hub 展示顺序

Docker Hub 的标签页默认按 `last_updated` 倒序，没有按版本排序的选项，因此**推送
先后就是展示顺序**。矩阵据此排序：prerelease 按 `published_at` 由旧到新，stable
排在最后，`latest` 在 `reconcile-latest` 中最后移动。一次补齐多个标签后，页面自上
而下呈现 `latest` → stable → beta 由新到旧。

`max-parallel: 1` 是这个顺序成立的前提：并发 job 的完成先后不确定，标签时间会乱序。
代价是补齐 N 个标签的耗时线性增长。

**效力边界**：该排序只在**同一次运行推送多个标签**时生效。稳态下每次只推 0–1 个
标签，顺序即推送时序；且 `latest` 仅在 stable digest 变化时才重推，因此两次 stable
之间发布的 beta 会浮到 `latest` 之上。**不要期待 `latest` 长期置顶**——这与版本标签
不可变的设计直接冲突，无法通过重排解决。

### 3.3 调度语义与前提

- 同步 cron 为 `41 4 * * *`，即每日 `04:41 UTC` / `13:41 JST`；
- GitHub Actions 的 scheduled workflow 只运行仓库默认分支上的版本；当前远端默认分支是
  `ops`，所以修改必须先合入 `ops` 才会成为定时任务的实际逻辑；
- cron 是 best-effort，不是准点 SLA，高负载时可能延迟甚至被丢弃；公开仓库连续 60 天
  无活动时，GitHub 还会自动停用 scheduled workflow；人工补跑使用 `workflow_dispatch`，
  结果与定时运行遵循同一发现和发布路径；
- 合并不会立刻触发 registry 写入，但合入默认分支后，下一次每日 cron 会按上述范围
  自动创建缺失标签并在必要时移动 `latest`；
- 同步和审计共享同一 concurrency group 且不取消进行中的 run，审计不会插入正在进行的
  发布，后启动的任务排队等待；
- API、网络、digest 或验证失败都会使本次 run 失败；已成功创建的不可变标签保留，下一次
  只补仍缺失的标签，失败 run 不移动 `latest`；
- 当前没有 Slack、邮件 webhook 或 PagerDuty 等仓库自建告警；可观察信号是 GitHub Actions
  run 状态和每周审计失败。必须由仓库维护者确保 Actions 失败通知设置可用。

上述默认分支、延迟/丢弃和闲置停用语义以
[GitHub Actions `schedule` 官方文档](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)
为准。

## 4. 上游与架构验证

每个 Release 必须满足：

- tag 使用 `vX.Y.Z`；
- `draft=false`；
- stable/prerelease 状态与生成标签一致；
- 同时存在 `Xray-linux-64.zip` 和 `Xray-linux-arm64-v8a.zip`；
- 两个 GitHub asset digest 都是有效 SHA256；
- 构建前校验下载文件；
- 镜像 index 恰好包含 `linux/amd64`、`linux/arm64`；
- 两个平台运行时都报告预期 Xray 版本。

`linux/amd64` 包含 Intel 64/x86-64 和 AMD64；`linux/arm64` 表示 AArch64/ARMv8。

## 5. 发布前本地检查

```bash
git status --short --branch

bash -n \
  docker-build/build-fingerprint.sh \
  docker-build/discover-release-window.sh \
  docker-build/audit-image-tags.sh \
  docker-build/verify-image.sh \
  tests/test_xray_release_discovery.sh \
  tests/test_xray_image_tag_audit.sh \
  tests/test_xray_image_workflow.sh \
  tests/test_xray_image_verify.sh

bash tests/test_xray_release_discovery.sh
bash tests/test_xray_image_tag_audit.sh
bash tests/test_xray_image_workflow.sh
bash tests/test_xray_image_verify.sh
git diff --check
```

真实只读 dry-run：

```bash
bash docker-build/discover-release-window.sh taoziyoyo2566/xray-docker
```

它必须列出完整活动窗口和缺失数量，不登录 Docker Hub、不构建、不创建 tag。

## 6. 2026-08-27 首次同步基线

官方 API 和 Docker Hub 的只读 dry-run 得到：

```text
v26.7.28-beta
v26.7.11-beta
v26.6.27-beta
v26.6.22-beta
v26.6.1-beta
v26.5.9-beta
v26.5.3-beta
v26.4.25-beta
v26.4.17-beta
v26.4.15-beta
v26.4.13-beta
v26.3.27
```

`v26.3.27` 和 `latest` 已存在且共同指向
`sha256:a5c6e5de23ce9b5f9d1ccbe5562b82557968ec1b3696c31b9d4ea352cfe73098`。
首次同步缺失 11 个 beta 标签；因此会执行 11 次双架构构建，stable 不重建，
`latest` 只验证、不应移动。

该数据是带日期的快照。实际执行前必须重新 dry-run；结果漂移时以新官方 API 和
Docker Hub 只读证据为准，并重新评审写入范围。

首次动态同步于 2026-08-27 JST 通过
[Actions run 32986819040](https://github.com/taoziyoyo2566/reality-ops/actions/runs/32986819040)
成功完成，以上 11 个 beta 标签均已创建。同步尚未结束时人工启动的审计曾看到瞬时
`missing=1`；同步和审计因此共享 `xray-image-registry-state` concurrency group，避免后续
审计读取发布中的中间状态。此处记录的是事件证据，不替代每次操作前的实时 dry-run。

## 7. 首次或批量同步

前提：同步实现已经通过 PR 合入 `ops`，Repository Secrets
`DOCKERHUB_USERNAME`、`DOCKERHUB_TOKEN` 有效，质量检查通过。

操作摘要：

- **发生什么：** 手动运行 `Sync Xray Release Images`；
- **目标：** dry-run 中列出的全部缺失不可变标签，以及必要时的 `latest`；
- **影响：** 每个缺失版本创建一个双架构公开标签；
- **风险：** 首次运行消耗多个 runner/build cache，单版本失败会使 workflow 失败；
- **恢复：** 已成功的不可变标签保留，下次同步只重试仍缺失版本；
- **不包含：** 不删除旧标签、不覆盖版本标签、不部署 VPS。

GitHub UI：

```text
Actions → Sync Xray Release Images → Run workflow → Branch: ops
```

不要并行启动第二个 run；共享 concurrency group 会串行 registry writer。

## 8. 发布后验收

先重新运行审计：

```bash
bash docker-build/audit-image-tags.sh
```

必须满足：

- `Missing required tags` 为空；
- 当前 stable 版本标签和 `latest` 顶层 digest 相同；
- 每个活动窗口 beta 标签存在；
- 没有无后缀 prerelease 被误认为 stable；
- workflow summaries 记录每个新标签、顶层 digest 和两个平台。

抽查 tag：

```bash
image_tag='v26.7.28-beta'
curl --fail --silent --show-error --location \
  "https://hub.docker.com/v2/repositories/taoziyoyo2566/xray-docker/tags/${image_tag}" \
  | jq '{name, digest, platforms: [.images[] | select(.os == "linux") | (.os + "/" + .architecture)]}'
```

把 workflow URL、Git commit、发现窗口、新建标签、digest、平台和失败项记录到发布证据。

## 9. 日常自动同步

定时 run 无缺失标签时不构建，只验证 stable 并确认 `latest`。GitHub 新增 prerelease
时只构建新的 `-beta`；新增 stable 时重新计算窗口、构建新的 stable，并在验证后移动
`latest`。旧窗口标签不自动删除。

如果 prerelease 后来以同版本成为 stable，必须从最终官方 stable assets fresh build
无 `-beta` 标签；旧 `-beta` digest 不得直接改名。

每日任务的运行检查清单：

- `discover` summary 中的 stable、窗口和缺失数量合理；
- 有缺失时，所有矩阵项完成后 `reconcile-latest` 才运行；
- 无缺失时，没有 Docker 构建和登录，仅验证 stable/`latest` 对账；
- run 失败时查看失败 job；不要因为部分标签已创建而覆盖或删除它们；
- 超过一个预期周期没有 scheduled run 时，先检查 workflow 是否仍在默认分支、Actions
  是否启用及仓库调度状态，再人工执行同一 workflow。

## 10. 镜像定义变更

修改 `dockerfile`、`entrypoint.sh`、`NOTICE` 或 `.dockerignore` 后**不需要任何登记
动作**。这些文件的指纹由 `docker-build/build-fingerprint.sh` 计算，构建时写入镜像
label `io.taoziyoyo.xray.build-inputs`。

下一次同步会读回当前窗口每个标签的该 label：与仓库当前指纹不一致、或标签根本没有
这个 label 的，都会被重建并重新指向。因此改完合入默认分支即可，等每日同步自动收敛。

需要立即生效时用 `workflow_dispatch` 手动跑一次，路径与定时运行完全相同。

## 11. 失败与重试

| 失败 | 处理 |
|---|---|
| GitHub Release/tag 格式错误 | 停止；不猜测或改写上游 tag。 |
| 官方 asset/digest 缺失 | 停止该窗口同步，检查上游 Release。 |
| 目标版本标签已存在 | 不覆盖；确认 ledger 是否错误或 registry 已完成。 |
| 单版本构建/验证失败 | 修复原因后重跑；已成功版本会被自动跳过。 |
| stable 构建失败 | 不移动 `latest`。 |
| Docker Hub 登录失败 | 检查 Actions Secrets 和 PAT 权限/期限，不打印 Token。 |
| API rate limit/网络失败 | 本次 run 失败，不使用不完整列表发布。 |

## 12. 回滚 `latest`

版本标签不可变，因此从发布证据中选择已验证 stable tag/digest，只移动 `latest`。
回滚不会改变任何版本标签，也不会自动部署节点。错误移动 `latest` 是 Docker Hub 写操作，
必须单独评审目标 digest。

## 13. 审计与清理

`Audit Xray Image Tags` 使用 cron `29 5 * * 1`，即每周一 `05:29 UTC` /
`14:29 JST`，也可手动运行。它只读执行，分类规则：

- 合规 `vX.Y.Z[-rN]`、`vX.Y.Z-beta[-rN]` 和 `latest`：保留；
- 当前 prerelease 的无后缀标签、旧 `stable/prerelease/stable-previous`：人工判断；
- `build-*` 和 40 位 Git SHA tag：清理候选；
- 活动窗口版本或 `latest` 缺失：审计失败。

人工判断和清理候选只产生 warning，不使 workflow 失败；只有必需标签缺失才失败。审计
不会删除标签。清理前重新查询引用和 digest，明确列出删除集合，并单独取得 Docker Hub
删除授权。不可把首次同步和旧标签清理合并成一次模糊操作。

## 14. Docker Hub Overview 与凭据

Overview 源文件是 [`README.md`](../../README.md)。镜像发布不会
自动更新 Docker Hub Overview；更新说明文字是独立外部写操作。

GitHub Actions 使用 Repository Secrets 登录。不要把 PAT 放进 Git、日志、证据或聊天。
如果人工应急在本机执行 `docker login` 且未配置 credential helper，操作完成后运行
`docker logout` 删除 `~/.docker/config.json` 中保存的登录信息。
