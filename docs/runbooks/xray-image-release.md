# Xray 镜像同步与发布操作手册

最后复核：2026-08-28 JST

> 本文件描述**怎么操作**。各处配置**为什么是现在这样**、否决了哪些替代方案、
> 依据是什么、什么时候该重新审视——记在 [`../decisions.md`](../decisions.md)。

## 1. 目标与边界

本仓库把 XTLS/Xray-core 官方 GitHub Releases 同步为
`taoziyoyo2566/xray-docker` 多架构镜像。活动窗口定义为：

1. GitHub Releases API 中按发布时间从新到旧的第一个非 draft stable；
2. 该 stable 之前所有更新的非 draft prerelease；
3. 不自动补建更早的历史窗口；窗口外已发布的标签保留，且不再被重建。

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
- 修订标签（`-rN`）已停用，不再新建；已发布的历史 `-rN` 标签保留不动；
- 上游 Release 是 `immutable=false` 的，同一 tag 的官方资产可能被替换。构建时使用的
  两个资产 digest 写在 label `io.taoziyoyo.xray.asset-sha256-amd64` /
  `-arm64` 里，同步时与当前 Release 比对，不符即自动重建并重新指向；
- 版本标签与 `latest` 的 index 携带同一组 OCI annotation，由
  `docker-build/index-annotations.sh` 单点产出。**不要给其中任何一个单独加注解**：
  annotation 会改变 index digest，而 `reconcile-latest` 正是靠
  「`latest` 的 digest == stable 的 digest」判断是否需要移动 `latest`，
  两边不一致会导致 `latest` 被每天无谓重推；
- 同理，annotation 里不得出现随 run 变化的值（`image.created`、`image.revision`）。
  它们仍然作为 label 存在于各平台的镜像 config 中，不影响 index digest；
- 运行时和发布证据使用顶层 `sha256:` digest。

## 3. 同步工作流

`Sync Xray Release Images` 仅通过以下方式触发：

- `workflow_dispatch`：人工同步；
- 每日 `04:41 UTC` 定时同步。

合并代码本身不触发 registry 写入。工作流包含三个 job：

1. `discover`：读取官方 Release、官方资产 digest 和 Docker Hub 标签，生成缺失矩阵；
2. `build-missing`：串行逐个版本（`max-parallel: 1`），按 digest 推送、双架构验证，
   再创建版本标签；
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
5. 分页读取 Docker Hub tags API，取得已存在的标签集合；
6. 逐个读回窗口内已存在标签的镜像 config label，按三项判据决定是否重建：标签不存在、
   构建指纹不符、或两个源资产 digest 与当前 Release 不符；任一成立即进入矩阵；
7. 判据为空时不执行构建；
8. 矩阵全部成功后，`reconcile-latest` 才验证 stable 并按需移动 `latest`。


这意味着 GitHub Release 是版本范围和资产 digest 的事实来源，Docker Hub 上已发布镜像的
label 是“已经用什么构建过”的事实来源，仓库本身不缓存任何版本号。
读取 config label 的请求一旦失败会直接中止本次 run，不会把读取失败误当成“没有 label”
而触发整窗重建。发现器最多读取 10 页、
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
之间发布的 beta 会浮到 `latest` 之上。**不要期待 `latest` 长期置顶**——这是 `latest`
重推条件的直接结果，无法通过重排解决。

### 3.3 调度语义与前提

- 同步 cron 为 `41 4 * * *`，即每日 `04:41 UTC` / `13:41 JST`；
- GitHub Actions 的 scheduled workflow 只运行仓库默认分支上的版本；本仓库的远端默认分支是
  `main`，所以修改必须先合入 `main` 才会成为定时任务的实际逻辑；
- cron 是 best-effort，不是准点 SLA，高负载时可能延迟甚至被丢弃；公开仓库连续 60 天
  无活动时，GitHub 还会自动停用 scheduled workflow；人工补跑使用 `workflow_dispatch`，
  结果与定时运行遵循同一发现和发布路径；
- 合并不会立刻触发 registry 写入，但合入默认分支后，下一次每日 cron 会按上述范围
  自动创建缺失标签并在必要时移动 `latest`；
- 同步和审计共享同一 concurrency group，配置为 `cancel-in-progress: false` +
  `queue: max`，审计不会插入正在进行的发布，后启动的任务依次排队（上限 100，
  超出才会被取消）。没有 `queue: max` 时 GitHub 默认只允许一个 run 处于 pending，
  第三个 run 会顶掉排队中的第二个而不是跟在它后面；
- API、网络、digest 或验证失败都会使本次 run 失败；已成功创建的标签保留，下一次
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
- 两个平台运行时都报告预期 Xray 版本；
- 两个平台上都真正执行一次 `/entrypoint.sh`：不给配置时必须以文档记录的消息拒绝
  启动。只查版本会绕开 entrypoint，改坏的 entrypoint 能通过验证并替换掉 `latest`。

`linux/amd64` 包含 Intel 64/x86-64 和 AMD64；`linux/arm64` 表示 AArch64/ARMv8。

## 5. 发布前本地检查

```bash
git status --short --branch

bash -n \
  docker-build/build-fingerprint.sh \
  docker-build/discover-release-window.sh \
  docker-build/audit-image-tags.sh \
  docker-build/verify-image.sh \
  docker-build/smoke-image.sh \
  docker-build/index-annotations.sh \
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

静态检查（PR 的 `static-analysis` job 跑的是同一组命令；三个 linter 在 workflow 里
按版本 + SHA256 固定，本地请自行安装对应版本以免结论不一致）：

```bash
shellcheck -x docker-build/*.sh tests/*.sh
actionlint -no-color -shellcheck "$(command -v shellcheck)" \
  -ignore 'unexpected key "queue" for "concurrency" section'
hadolint docker-build/dockerfile
```

三者必须为零 finding。Dockerfile 只保留带紧邻原因的窄范围 hadolint 抑制。

`-ignore` 不能省：actionlint 1.7.12 还不认识 `concurrency.queue`，省掉它本地会对
三个工作流各报一条假阳性。它的范围和复审条件见 `decisions.md` D-17——**升级
`ACTIONLINT_VERSION` 时要回头试删这一行**。

行为冒烟（需要本机 Docker；PR 检查跑的是同一个脚本）：

```bash
version="$(curl -sSfL 'https://api.github.com/repos/XTLS/Xray-core/releases' \
  | jq -r 'map(select(.draft == false and .prerelease == false)) | first | .tag_name')"
amd64="$(curl -sSfL "https://api.github.com/repos/XTLS/Xray-core/releases/tags/${version}" \
  | jq -r '[.assets[] | select(.name == "Xray-linux-64.zip") | .digest] | first | sub("^sha256:"; "")')"
arm64="$(curl -sSfL "https://api.github.com/repos/XTLS/Xray-core/releases/tags/${version}" \
  | jq -r '[.assets[] | select(.name == "Xray-linux-arm64-v8a.zip") | .digest] | first | sub("^sha256:"; "")')"

docker build --file docker-build/dockerfile \
  --build-arg "XRAY_VERSION=${version}" \
  --build-arg "XRAY_SHA256_AMD64=${amd64}" \
  --build-arg "XRAY_SHA256_ARM64=${arm64}" \
  --tag xray-image:local docker-build

bash docker-build/smoke-image.sh xray-image:local "${version}"

# 漏洞扫描。PR 只对「已有修复的 CRITICAL」失败：
trivy image --scanners vuln --severity CRITICAL --ignore-unfixed --exit-code 1 xray-image:local
# 完整报告（含无法由本仓库修复的上游 Go stdlib 漏洞）：
trivy image --scanners vuln --severity CRITICAL,HIGH,MEDIUM xray-image:local
```

镜像里的 `xray` 是上游预编译二进制，它的 Go stdlib 漏洞只能等上游用新版 Go 重新
发布，本仓库改不了；因此闸门刻意不设在 HIGH，否则每个 PR 都会被一批无法处置的
条目挡住。Alpine 包的可修复项则由 Dependabot 推进 base image digest 来解决。

真实只读 dry-run：

```bash
bash docker-build/discover-release-window.sh taoziyoyo2566/xray-docker
```

它必须列出完整活动窗口和缺失数量，不构建、不创建 tag；未设置只读凭据时匿名读取。

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
首次同步缺失 11 个 beta 标签。**当时据此预判「stable 不重建、`latest` 只验证不移动」——
实际运行推翻了这一条**，见下。

该数据是带日期的快照。实际执行前必须重新 dry-run；结果漂移时以新官方 API 和
Docker Hub 只读证据为准，并重新评审写入范围。

首次动态同步于 2026-08-27 JST 完成，以上 11 个 beta 标签均已创建，
**并且 `v26.3.27` 被重建、`latest` 随之移动**——两者现在共同指向
`sha256:b891c9781882c59c774af5fb3710e4f8809883447e1e9b13fde9fd92024792fd`
（`[实测]` 2026-08-28 读 Docker Hub tags API，`last_updated` 分别为该次 run 内的
`17:10:13Z` 与 `17:10:45Z`）。上面的预判之所以错，原因就写在 §10 最后一句：那两个
标签是在指纹机制上线**之前**发布的，身上根本没有 `io.taoziyoyo.xray.build-inputs`
label，按判据视为不符而被补建一次。这是设计内的行为，不是故障；**留在这里是因为
它是本机制第一次端到端跑通的实证**，也提醒别把窗口内「已存在的标签」默认当成
「不会被动的标签」。当时本项目尚未拆分为
独立仓库，运行记录留在拆分前的
[reality-ops Actions run 32986819040](https://github.com/taoziyoyo2566/reality-ops/actions/runs/32986819040)
（分支 `ops`，结论 success）——**这是拆分前的历史证据，不是本仓库当前的运行路径**。
同步尚未结束时人工启动的审计曾看到瞬时
`missing=1`；同步和审计因此共享 `xray-image-registry-state` concurrency group，避免后续
审计读取发布中的中间状态。此处记录的是事件证据，不替代每次操作前的实时 dry-run。

## 7. 首次或批量同步

前提：同步实现已经通过 PR 合入 `main`，Repository Secrets
`DOCKERHUB_USERNAME`、`DOCKERHUB_TOKEN` 有效，质量检查通过。

操作摘要：

- **发生什么：** 手动运行 `Sync Xray Release Images`；
- **目标：** dry-run 中列出的全部待建或待刷新标签，以及必要时的 `latest`；
- **影响：** 每个缺失版本创建一个双架构公开标签；
- **风险：** 首次运行消耗多个 runner/build cache，单版本失败会使 workflow 失败；
- **恢复：** 已成功创建的标签保留，下次同步只重试仍缺失或仍待刷新的版本；
- **不包含：** 不删除旧标签、不部署 VPS。版本标签的重新指向是本流程的正常行为，
  不在排除之列。

GitHub UI：

```text
Actions → Sync Xray Release Images → Run workflow → Branch: main
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
- 无缺失时，没有 Docker 构建或写凭据登录，仅验证 stable/`latest` 对账；
- run 失败时查看失败 job；不要因为部分标签已创建而覆盖或删除它们；
- 超过一个预期周期没有 scheduled run 时，先检查 workflow 是否仍在默认分支、Actions
  是否启用及仓库调度状态，再人工执行同一 workflow。

## 10. 自动重建的两个触发条件

重建不需要任何人工登记动作。下一次同步会读回当前窗口每个标签的镜像 config label，
命中以下任一条即重建并重新指向：

1. **发布定义变了。** 修改 `dockerfile`、`entrypoint.sh`、`NOTICE`、`.dockerignore`、
   `GPL-3.0.txt` 或 `index-annotations.sh` 后，`docker-build/build-fingerprint.sh`
   算出的指纹改变，与标签上记录的 `io.taoziyoyo.xray.build-inputs` 不符。
2. **上游资产变了。** 当前 Release 的 `Xray-linux-64.zip` /
   `Xray-linux-arm64-v8a.zip` digest 与标签上记录的
   `io.taoziyoyo.xray.asset-sha256-amd64` / `-arm64` 不符。

标签根本没有这些 label（本机制上线前发布的）同样视为不符，会被补建一次。
因此改完合入默认分支即可，等每日同步自动收敛。

需要立即生效时用 `workflow_dispatch` 手动跑一次，路径与定时运行完全相同。

## 11. 失败与重试

| 失败 | 处理 |
|---|---|
| GitHub Release/tag 格式错误 | 停止；不猜测或改写上游 tag。 |
| 官方 asset/digest 缺失 | 停止该窗口同步，检查上游 Release。 |
| 目标版本标签已存在 | 正常状态：指纹一致时不重建；指纹不符时按设计重新指向，无需人工干预。 |
| 单版本构建/验证失败 | 修复原因后重跑；已成功版本会被自动跳过。 |
| stable 构建失败 | 不移动 `latest`。 |
| Docker Hub 登录失败 | 检查 Actions Secrets 和 PAT 权限/期限，不打印 Token。 |
| 读取已发布镜像 config 失败 | 本次 run 失败；不把读取失败当成「没有 label」，避免误重建整个窗口。 |
| PR 的构建/冒烟检查失败 | 不要绕过。该闸门挡的正是会被同步推成公开标签的坏构建。 |
| API rate limit/网络失败 | 本次 run 失败，不使用不完整列表发布。每个 HTTP 请求已有 3 次有界重试（仅针对瞬时故障）和 60 秒上限；确定性的 401/404 立即返回，不重试。 |
| job 超时 | 所有 job 都设了 `timeout-minutes`。超时说明卡在网络或构建上；重跑前先看最后一步的日志，不要直接加大超时。 |

## 12. 回滚 `latest`

**回滚目标必须用 digest 指定，不能用版本标签。** 版本标签是移动别名：`v26.3.27`
今天指向的字节，未必是你上次验证它时的那一份。按标签回滚等于回滚到一个未经复核的
当前内容。

目标 digest 必须是**公开标签真正解析到的那个 index digest**。run summary 的
`Digest:` 行报的就是它：`Published <tag>` 取自 `imagetools create --metadata-file`
的结果，`Current stable image` 取自 Docker Hub 上该标签的 digest，两者同类可比。

> **不要用构建步骤的 digest。** `docker/build-push-action` 用 `push-by-digest`
> 推上去的是加注解**之前**的候选 index；`imagetools create` 加注解后会产生一个
> **不同**的 digest，公开标签指向的是后者。把 `latest` 指到候选 digest 上，会得到
> 一个没有任何标签指向、缺少 index annotation 的镜像，而且次日 `reconcile-latest`
> 会发现它与 stable 不等，把这次回滚**原样撤销**。

动手前先确认目标：

```bash
docker buildx imagetools inspect taoziyoyo2566/xray-docker@<digest> --raw | head
```

只把 `latest` 移到它上面。回滚不改变任何版本标签，也不会自动部署节点。
错误移动 `latest` 是 Docker Hub 写操作，必须单独评审目标 digest。

## 13. 审计与清理

`Audit Xray Image Tags` 使用 cron `29 5 * * 1`，即每周一 `05:29 UTC` /
`14:29 JST`，也可手动运行。它只读执行，分类规则：

- 合规 `vX.Y.Z`、`vX.Y.Z-beta` 和 `latest`：保留；
- 历史遗留的 `-rN` 后缀标签：保留，不主动清理（修订标签已停用，不再新建）；
- 当前 prerelease 的无后缀标签、旧 `stable/prerelease/stable-previous`：人工判断；
- `build-*` 和 40 位 Git SHA tag：清理候选；
- 活动窗口版本或 `latest` 缺失：审计失败。

人工判断和清理候选只产生 warning，不使 workflow 失败。审计有**两个**失败条件：
必需标签缺失，以及 `latest` 与当前 stable 版本标签的顶层 digest 不相等（§8 的验收
条件之一）。两个标签之一缺失时不按不相等失败——那由前一个条件报出。审计
不会删除标签。清理前重新查询引用和 digest，明确列出删除集合，并单独取得 Docker Hub
删除授权。不可把首次同步和旧标签清理合并成一次模糊操作。

## 14. Docker Hub Overview 与凭据

Overview 源文件是 [`README.md`](../../README.md)。同步由**独立的**
`Sync Docker Hub Overview` 工作流承担，触发条件是 `README.md` 推到 `main`
（或手动 dispatch），因此改完 README 合入默认分支即可，不需要人工写操作。

它**刻意不挂在发布流程上**。此前它跑在 `reconcile-latest` 之后，每天执行，有两个
问题：Overview 同步失败会让一次已经成功发布的 run 显示为部分失败；而该 Action 要求
的 PAT 权限比发布本身更高（见下），绑在一起会迫使发布令牌获得删除镜像的能力。

两种「不做事」的情况会被明确跳过而不是报错：Docker Hub 仓库尚未创建（首次推送镜像
之前它不存在），以及 `DOCKERHUB_OVERVIEW_TOKEN` 未配置。后者会留一条 warning
说明要建什么令牌。

### 14.1 需要的 Repository Secrets

| Secret | 权限 | 用途 | 缺失时 |
|---|---|---|---|
| `DOCKERHUB_USERNAME` | — | 所有 Docker Hub 认证 | 登录失败，发布中止 |
| `DOCKERHUB_TOKEN` | PAT，含 **Write** | 推送镜像、移动 `latest` | 发布中止 |
| `DOCKERHUB_RO_TOKEN` | PAT，只勾 **Read** | `discover`/审计读取已发布镜像 config；`reconcile-latest` 验证前拉取 | **自动回落匿名**，不会失败 |
| `DOCKERHUB_OVERVIEW_TOKEN` | PAT，含 **Delete** | 只用于写 Docker Hub Overview | Overview 不更新，留 warning；**不影响发布** |

`DOCKERHUB_RO_TOKEN` 是可选的可靠性加固，不是发布前提。未配置时上述读取走匿名路径，
按 runner 出口 IP 计入 Docker Hub 配额（实测响应头 `100;w=3600`，且该 IP 与其他
GitHub Actions 用户共享）。撞限时本次 run 失败并在次日 cron 重试，属 fail-closed，
不会发布错误内容。

创建方法：Docker Hub → Account settings → Personal access tokens → New Access Token，
Access permissions **只勾 Read**（Docker Hub 的三个权限级别是 Read / Write / Delete，
只勾 Read 即为只读令牌），存为该 Secret 即自动生效，无需改动代码。

三个令牌刻意分开，各自只拿它那条路径需要的权限：

- `DOCKERHUB_RO_TOKEN` —— `discover` 和审计都只读，不该拿到能改写 registry 的凭据。
  `reconcile-latest` 先用它完成验证，仅在确实要移动 `latest` 时才换成读写令牌。
- `DOCKERHUB_OVERVIEW_TOKEN` —— `peter-evans/dockerhub-description` 的 README 要求
  PAT 具备 **read/write/delete** scope。发布只需要 write，因此**不要**把
  `DOCKERHUB_TOKEN` 用于 Overview：那等于让每天运行的发布令牌获得删除镜像的能力。
  这个令牌只被那一个独立工作流使用，且只在 README 变更时才会用到。

不要把任何 PAT 放进 Git、日志、证据或聊天。
如果人工应急在本机执行 `docker login` 且未配置 credential helper，操作完成后运行
`docker logout` 删除 `~/.docker/config.json` 中保存的登录信息。
