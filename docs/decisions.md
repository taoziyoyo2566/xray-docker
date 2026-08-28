# 设计决策记录

## 关于本文件

代码里的注释回答「这里在做什么、为什么这样写」。本文件回答注释装不下的三件事：

1. **否决了哪些替代方案**，以及否决的理由；
2. **定案依据**——哪次实验、哪条上游文档、哪个实测结果；
3. **什么时候该回来重新审视**这个决定。

因此本文件**刻意不复述代码**。当两者冲突时，**代码是事实**，本文件是过期的记录，
应当以代码为准来修正本文件。反过来，若代码变了而这里的「复审条件」已经满足，
说明该决定到了重新评估的时候。

标注 `[实测]` 的依据是在本机或本仓库 CI 上实际跑出来的；标注 `[文档]` 的来自上游
官方文档；标注 `[未验证]` 的是尚未取得直接证据的判断。

---

## 1. 发布契约

### D-01 版本标签是移动别名，不是不可变标签

`vX.Y.Z` 命名的是「上游 Xray 的某个版本」，不是「某一组确定的字节」。镜像定义变化
（base image 升级、打包修复）时，窗口内的全部标签都会重建并重新指向。

- **否决**：真正不可变的版本标签。那样 base image 的安全更新就永远到不了已发布的
  标签，使用者要么手动追新版本号，要么长期停在有漏洞的镜像上。
- **代价**：使用者无法靠标签获得可复现的字节，必须钉 digest。这一点必须在 README
  和 runbook 里显著说明——**这是本项目最容易被误解的一点**。
- **复审**：若将来引入「安全更新单独发 `-rN` 修订标签」的机制，此决定应重估。

### D-02 先按 digest 推送、验证通过后才创建公开标签

`build-missing` 用 `push-by-digest=true` 推送候选镜像，跑完双架构验证，才用
`imagetools create` 打上公开标签。

- **理由**：候选镜像在验证前**没有任何公开 tag**，验证失败的构建不会被任何人拉到。
- **否决**：先打标签再验证。那样一次失败的验证会留下一个已经对外可见的坏标签，
  而版本标签是移动别名（D-01），坏标签会直接替换掉当前可用的镜像。
- **复审**：若改为不可变标签，此顺序的必要性下降但仍然更安全。

### D-02b 对外报告的 digest 一律取自 `imagetools create --metadata-file`

- **背景（2026-08-28 修正的缺陷）**：`Report published image` 曾报
  `steps.build.outputs.digest`，那是 `push-by-digest` 推上去的、**加注解之前**的
  候选 index digest；公开标签指向的是 `imagetools create` 加注解后产生的另一个
  digest。两个 summary 因此报着两类不可比的 digest，而 runbook 的回滚章节正是让
  操作者去取那一行——照做会把 `latest` 指到一个无标签指向的候选上，并在次日
  reconcile 时被自动撤销。
- **依据**：`[实测]` 2026-08-28 本机私有 registry：源 `sha256:79ff19e9…`，
  加注解 create 之后标签解析到 `sha256:441691fb…`，`--metadata-file` 写出的
  `.["containerimage.descriptor"].digest` 与后者一致。**没有顶层
  `containerimage.digest` 键**，取值路径别写错。
- **验证仍跑在构建 digest 上是对的**：注解只改 index，各平台 manifest 逐字节不变。
- **附带的不变量检查**：`Move latest` 也取 `--metadata-file`，并断言结果等于源
  stable digest。相同注解重复施加是幂等的，不等只可能是两次 create 的注解集合
  发生了分歧——即 D-04/D-06 描述的那个故障，现在会就地失败而不是每天悄悄重推。

### D-03 `latest` 只在 stable 的 index digest 变化时才移动

- **理由**：避免每天无谓地重写 `latest`，也让「latest 是否移动过」成为一个有信息量
  的信号。
- **后果（已知且接受）**：Docker Hub 的标签列表按更新时间排序，因此两次 stable 之间
  发布的 beta 会浮到 `latest` 上面。**不要期待 `latest` 长期置顶**，这是本决定的直接
  结果，无法通过调整推送顺序解决。
- **依据**：`[实测]` 2026-08-28，本机起私有 registry 复现了「同一 digest 重复
  `imagetools create` 不改变 digest」，因此比对 digest 是稳定的判据。

---

## 2. 重建判据

### D-04 构建指纹覆盖「决定已发布产物」的全部文件

指纹（`build-fingerprint.sh`）写进镜像 label `io.taoziyoyo.xray.build-inputs`，
同步时比对不上即重建。当前输入集合见该脚本，其中两个的入选理由不显然：

- **`index-annotations.sh`**：它不影响镜像内容，只影响 index 的字节。但
  `reconcile-latest` 靠「latest 的 index digest == 版本标签的 index digest」判断是否
  移动 latest。若它不在指纹里，改注解会落入两个都错的分支：两个 digest 原本相等时，
  移动步骤被跳过、**新注解永远发布不出去**；latest 落后于版本标签时，则变成**每天用
  新注解重推一次 latest 却永远追不平**。纳入指纹后，改注解触发窗口内标签重建，新注解
  烘进版本标签，latest 才能收敛。
- **`GPL-3.0.txt`**：它是镜像内容（见 D-24），换掉它就该重建。
- **依据**：`[实测]` 2026-08-28 私有 registry 实验确认注解会改变 index digest，
  且对同一注解集合幂等。
- **复审**：新增任何进入镜像或进入 index 的文件时，必须同步加进指纹输入。
  `tests/test_xray_release_discovery.sh` 对上述两项有**行为断言**：它在夹具目录里
  逐个改动这两个文件并要求指纹随之改变，而不是去匹配 `inputs=` 那一行的文本——
  换一种写法把文件移出输入集合，同样会被抓到。

### D-05 上游资产 digest 参与重建判据

构建时用到的两个官方资产 digest 写进 label `io.taoziyoyo.xray.asset-sha256-{amd64,arm64}`，
同步时与当前 Release 的资产比对，不符即重建。

- **理由**：GitHub Release 是 `immutable=false` 的，同一个 tag 的官方资产**可以被替换**。
  只比对版本号无法发现这种漂移，重建同一版本会静默得到不同的二进制。
- **复审**：若上游改用 immutable release，此判据可简化但保留无害。

---

## 3. Index annotations

### D-06 注解由单个脚本产出，两次 `imagetools create` 必须使用同一集合

- **理由**：版本标签和 `latest` 是两次独立的 `create`。注解进入 index 的字节并改变其
  digest，两次给出的集合只要有一点不同，两个 digest 就永不相等，`latest` 会被每天
  无谓重推（见 D-04）。由同一个脚本产出是最简单可靠的保证。
- **依据**：`[实测]` 2026-08-28 私有 registry：`imagetools create` 不带注解时是字节
  相同的拷贝；带注解会改变 index digest；相同注解重复施加是幂等的。

### D-07 注解里排除 `image.created` 与 `image.revision`

- **理由**：只允许「由版本唯一确定」的值。`created` 每次 run 都不同，`revision`
  （`github.sha`）跨 run 会变——放进去等于让 D-06 的等价条件永远不成立。
- **补偿**：这两项仍作为 label 存在于各平台的镜像 config 里，那里不影响 index digest。
- **复审**：任何想加进注解的新字段，先问「同一个版本重跑一次，它会变吗」。

---

## 4. 凭据

### D-08 读用只读凭据，写凭据只在真正要移动 `latest` 时才登录

- **理由**：最小权限。稳态下每天的同步对 registry **只读不写**，不该让有写权限的
  令牌出现在那条路径上。
- **措辞修正（2026-08-28）**：此前这里写的是「每天的运行只读不写」，那是错的——
  Docker Hub Overview 同步当时挂在同一个 run 里，每天用写令牌写一次仓库元数据。
  该 job 已拆为独立工作流（见 D-11b），此处的限定词也一并收窄到 registry。
- **依据**：`[实测]` 2026-08-28 抓取 Docker Hub 响应头，匿名配额为 `100;w=3600`
  （按出口 IP / IPv6 /64 计），而官方文档写的是 100/6h——**实测比文档更严**。
  GitHub 共享 runner 的出口 IP 是与他人共用的，匿名拉取随时可能被限流。
- **复审**：若 Docker Hub 改变配额口径，重新实测而不是照抄文档。

### D-09 登录必须在验证步骤**之前**，且不能只在需要移动 latest 时才做

- **理由**：验证要拉两个平台的镜像。稳态下 `move_latest` 为 false，若把登录放在
  移动 latest 的条件分支里，那条路径整轮都是匿名拉取——恰好是最常走的路径。
- **位置**：`.github/workflows/build-image.yml` 的 `reconcile-latest`。

### D-10 `HAS_READONLY_LOGIN` 在 job 级 `env` 里映射成布尔值

- **理由**：`secrets` 上下文在 **step 级 `if`** 里不可用，只能在 job 级 `env` 里取值
  再由 step 的 `if` 读 `env`。这不是风格选择，是平台限制。
- **依据**：`[文档]` GitHub Actions 上下文可用性表。

### D-11 只读凭据是可选的，缺失时降级为匿名并明确打印

- **理由**：这是可靠性加固，不是运行前提。没有配置时同步仍然可用，只是走匿名配额。
  脚本会打印走的是哪条路径，便于事后判断限流原因。

### D-11b Docker Hub Overview 同步是独立工作流，用独立令牌

- **决定**：从 `build-image.yml` 移出，改为 `sync-dockerhub-overview.yml`，触发条件
  是 `README.md` 推到 `main` 或手动 dispatch，使用独立的
  `DOCKERHUB_OVERVIEW_TOKEN`。
- **否决**：留在发布流程里。两个具体损害：Overview 同步失败会让一次**已经成功
  发布**的 run 显示为部分失败，把发布的成败信号和一个文案同步搅在一起；而
  `peter-evans/dockerhub-description` 的 README 要求 PAT 具备 **read/write/delete**
  scope，发布只需要 write——绑在一起就只有两个结果：Overview 步骤失败，或者让每天
  运行的发布令牌获得删除镜像的能力。
- **不是上游的推荐做法**：该 Action 的 README 给了 push / release / README-path
  几种触发示例，**没有**推荐任何一种。拆分是本项目的判断，理由如上。
- **两种「不做事」被显式跳过而非报错**：Docker Hub 仓库尚未创建（首次推送镜像前
  它不存在），以及令牌未配置（留 warning 说明要建什么）。
- **复审**：若该 Action 将来降低权限要求，可重新评估是否合并回发布流程；但
  失败域分离这条理由独立成立。

---

## 5. 并发、超时与重试

### D-12 同步与审计共享 concurrency group，`cancel-in-progress: false` + `queue: max`

- **理由**：两者都读写同一份 registry 状态。审计若插入正在进行的发布，会读到中间态
  （历史上出现过瞬时 `missing=1`，见 runbook §6）。
- **为什么必须写 `queue: max`**：GitHub 的默认值是 `queue: single`，**只允许一个 run
  处于 pending**——第三个 run 会顶掉排队中的第二个，而不是跟在它后面。被顶掉的 run
  显示为 cancelled，不是失败，很容易被当成正常现象忽略。
- **依据**：`[文档]` GitHub 2026-05-07 changelog 与并发文档；`queue: max` 上限 100，
  且与 `cancel-in-progress: true` 互斥（本仓库为 false，可共存）。
- **代价**：`actionlint` v1.7.12（截至 2026-08-28 的最新版）尚不认识 `queue` 键，
  需要定向抑制，见 D-17。

### D-13 每个 job 都设 `timeout-minutes`

- **理由**：默认超时是 6 小时。卡在网络或 QEMU 构建上的 job 会白占 6 小时的额度，
  也会一直压着 concurrency group 不放。
- **复审**：超时触发时先看最后一步日志，**不要直接加大超时**——它是信号不是限制。

### D-14 所有对外 curl 都设连接/总时长上限与有界重试

- **理由**：无上限的 curl 遇到挂起的对端会一直等到 job 超时，把一个 10 秒的网络抖动
  放大成一次 30 分钟的失败。
- **有界**：重试次数固定，不做指数退避到无限——同步是每日任务，失败等下一轮即可。
- **漂移记录（2026-08-28）**：本条一度不成立——`quality.yml` 里下载 linter 和查询
  上游 Release 的两处 curl 都没有重试与超时，而这里写着「所有」。已给代码补齐，
  而不是把文档改弱。**这是本文件的第一处实证漂移**，说明「文档声称覆盖全部」这类
  断言最容易过期；写这类全称句时要么当场核对全部调用点，要么别写全称。

---

## 6. 质量闸门

### D-15 PR 上真实构建镜像并跑行为冒烟

- **理由**：缺这个闸门时，改坏 `dockerfile` 或 `entrypoint.sh` 的 PR 可以通过全部
  检查合入，再由每日同步把坏构建推成公开标签——而版本标签是移动别名（D-01），
  那会直接替换掉当前可用的镜像。
- **依据**：`[实测]` 2026-08-28 用变异验证过：故意改坏 entrypoint 后，旧的检查集合
  全部通过。
- **范围限制**：只构建 runner 架构（`linux/amd64`）。arm64 走 QEMU 太慢，且推送后
  的 `verify-image.sh` 会做双架构验证兜底。**这意味着 arm64 特有的构建问题只能在
  推送后才被发现**，是已知缺口（见 G-02）。

### D-16 三个 linter 按版本 + SHA256 固定下载，不用 runner 自带版本

- **理由**：runner 镜像换一次，检查结果就可能无声漂移或突然变红。固定下载让「检查
  结果变了」只可能来自代码变化。
- **代价**：升级 linter 变成需要手动改两个常量的动作，Dependabot 不覆盖。
- **依据**：`actionlint`/`hadolint` 的摘要取自各自官方 checksums 文件；`shellcheck`
  上游不发布 checksums，记录的是固定该版本时实际核对过的摘要。

### D-17 `actionlint` 的 `-ignore` 必须始终限定到 `concurrency.queue`

- **理由**：这是一条确定的假阳性——GitHub 2026-05-07 加了 `queue` 键，actionlint
  的解析器（其 `parse.go` 的 `unexpectedKey`）至今只接受 `group` 和
  `cancel-in-progress`。抑制的是工具的滞后，不是我们的问题。
- **依据**：`[实测]` 2026-08-28 变异验证：该正则只静默 `queue`，同一段落里的
  `cancel-in-progres` 错字仍会被报出。
- **复审（重要）**：**提升 `ACTIONLINT_VERSION` 时必须回头试删这一行。** 抑制一旦
  比它的成因活得更久，就变成了永久的盲区。

### D-18 漏洞扫描分成「报告」和「闸门」两步

- **报告**：`CRITICAL,HIGH,MEDIUM`，不设失败，输出到 run summary 供人看。
- **闸门**：只对 `CRITICAL` 且 `ignore-unfixed: true` 失败。
- **理由**：镜像里的 xray 是上游预编译二进制，它的 Go stdlib 漏洞**本仓库无法修复**。
  闸门设到 HIGH 会让每个 PR 都被卡在改不动的问题上，几周内就会被加 `continue-on-error`
  绕过——那等于没有闸门。
- **依据**：`[实测]` 2026-08-28 扫描结果：`gobinary` 36 个 HIGH（上游 Go stdlib，
  修不了）对 `alpine` 2 个 HIGH。可修复的 CRITICAL 为 0，闸门通过。
- **闸门为什么仍然有价值**：可修复的 CRITICAL 绝大多数来自 Alpine 包，解法是让
  Dependabot 把 base image 的 digest 往前推一格——这是可操作的，而且因为版本标签是
  移动别名（D-01），推进后的修复会真的到达**已发布**的标签，不只到达新版本。

### D-19 `smoke-image.sh` 放在 `docker-build/` 而不是 `tests/`

- **理由**：CI 用 `for t in tests/*.sh` 遍历跑测试。冒烟脚本需要一个镜像参数，放进
  `tests/` 会被无参调用，**很可能是"跳过并成功"而不是失败**——一个永远绿的假闸门。
  放在 `docker-build/` 让它只能被显式调用。

---

## 7. 镜像构建

### D-20 安装动作全部收在单个 `RUN` 层

- **理由**：属主和权限一次定妥。后续层若再 `chown` 二进制会触发 copy-up，使 36MB 的
  `xray` 在镜像里出现第二份。

### D-21 不写 `EXPOSE`

- **理由**：监听端口完全由用户挂载的配置决定，镜像无从得知。写一个猜测值只会让
  `docker run -P` 映射错端口，属于**主动给出错误信息**，比不给更糟。
- **背景**：此前写的是 `EXPOSE 8443`，而该端口在本仓库其它任何地方都没有依据。

### D-22 `HEALTHCHECK` 用 shell 形式，保留 `hadolint ignore=DL3025`

- **理由**：探测端口来自运行时环境变量 `${XRAY_HEALTH_PORT}`，JSON exec 形式不经过
  shell，无法展开。这是硬性限制，不是风格问题。
- **另**：BusyBox 的 `nc` 没有 `-z`，只能靠一次真实连接判定。

### D-23 `COPY --chmod` 的目标目录必须由前面的 `RUN` 先建好

- **依据**：`[实测]` 2026-08-28。`COPY --chmod=0644` 会把**同一个模式套到它隐式创建
  的父目录上**，0644 的目录没有 x 位，非 root 进不去——文件在镜像里却读不到，且
  `ls` 该目录显示为空。这个失败**只在以非 root 运行时暴露**，是本轮冒烟断言抓到的。
- **复审**：任何新增的 `COPY --chmod` 到新目录，都要确认目录已存在。

---

## 8. 许可与数据

### D-24 geodata 维持内置

`geoip.dat` / `geosite.dat` 随官方 Xray release zip 进入镜像，本项目不单独获取。

- **决定日期**：2026-08-28。
- **理由**：移除内置 geodata 是对公开镜像的**破坏性变更**——配置里用到
  `geoip:` / `geosite:` 规则的用户会在下次重建时静默失效，而版本标签是移动别名
  （D-01），他们不会收到任何提示。而支撑这个变更的依据，是一份**本项目并非缔约方**
  的合同的解读（见下）。基于未经审查的合同解读推破坏性变更，代价与依据不匹配。
- **否决的方案及其失效点**：
  - *删除旧标签以满足 30 天条款*——**无效**。当前 stable 标签携带的也是它自己发布
    日的数据，同样会超期；这不是标签保留策略造成的。
  - *构建时独立获取最新 geodata*——**部分有效**。今天建的标签半年后仍带半年前的
    数据，除非配合「不超过 30 天的强制重建」，而现有指纹机制是「输入变化才重建」，
    不是定时重建。这是一次架构改动，不是一次配置调整。
  - *不内置*——唯一干净的方案，但见上文的破坏性代价。
- **未决问题（三条，均**未经法律审查**）**：
  1. 打包项目的 GPL-3.0 是否延伸到仅仅捆绑了生成数据的容器镜像；
  2. MaxMind GeoLite EULA 的三十天陈旧条款是否约束**衍生数据集的下游收件人**；
  3. 该 EULA 的「第三方披露需事先书面同意」条款是否约束本链条上的任何一方。
- **两方立场要分开陈述（2026-08-28 修正）**：MaxMind 自己的口径是宽的——其支持
  文档称「**任何使用** GeoLite 数据库或 GeoLite 网络服务的人都受 GeoLite EULA
  约束」，并要求「若你与他人共享 GeoLite 数据，你需要让对方承担相同或实质相似的
  义务」。按这个读法，使用即受约束，与是否见过条款无关。
  开放的不是 MaxMind 主张什么，而是该主张能否成立：这些是**合同**条款，而本项目
  从未向 MaxMind 取过数据、从未表示同意，收到的是格式不同的衍生数据集。未表示
  同意的下游接收者是否受约束，是法律问题不是工程问题。
  **此前本条只写了「非缔约方」这一侧，是片面的**；两侧都要在场，任何一方都不得
  被当作既定结论。
- **复审条件**：取得法律意见时；或上游改变 geodata 来源时；或本项目决定发布
  major 版本、有条件承担破坏性变更时。
- **详细记录**：`THIRD-PARTY-NOTICES.md` 的 Status 块与 EULA 条款逐字引用。

### D-25 镜像内附带 GPL-3.0 全文与对应源码提供声明

- **理由**：镜像在 `org.opencontainers.image.licenses` 里**机器可读地断言了 GPL-3.0-only**。
  若该断言成立，GPLv3 要求分发非源码形式时一并提供许可证全文与源码获取途径；
  两者缺失会让那条 label 没有支撑。
- **为什么不等法律审查**：成本近乎为零，且结论是**不对称**的——若 GPL 适用，这就
  补上了一个真实缺口；若不适用，我们只是多带了一个文本文件。
- **复审**：若将来把 GPL-3.0-only 从 licenses label 里去掉，这个文件的必要性随之重估；
  **不要只去掉一个**，那会让断言与随附材料不一致。

### D-26 `licenses` label 使用完整 SPDX 表达式而非单一许可证

取值见 `docker-build/index-annotations.sh`（`--licenses`），由该脚本单点产出，
`build-image.yml` 与 index 注解共用同一个值，测试对两者一致性有断言。

- **背景**：此前该 label 写的是 `MIT`，那是**本仓库工具链**的许可证，而不是镜像
  实际分发内容的许可证——属于误导性元数据。
- **`GPL-3.0` → `GPL-3.0-only`（2026-08-28）**：`[实测]` 拉取 SPDX 官方 license
  列表确认 `GPL-3.0` 已 `deprecated=true`，当前标识是 `GPL-3.0-only` /
  `GPL-3.0-or-later`。选 `-only` 的依据：上游 `v2ray-rules-dat` 只有一份裸
  `LICENSE`，没有「or any later version」的授予声明（该文件里出现的 "any later
  version" 属于 GPL 自带的 *How to Apply These Terms* 附录，每份拷贝都有，不是
  项目的表态）；而 SPDX 给废弃 ID `GPL-3.0` 的正式名称本就是 "GNU General Public
  License v3.0 **only**"。因此这是等价替换，没有新增任何断言。
- **复审**：若上游明确了版本政策，按其表述重取。

---

## 9. 已知缺口

- **G-01 `licenses` label 与只读凭据路径只能在真实 run 上确认。** 本机 `docker build`
  不经过 `metadata-action`；只读令牌不应也不会被取来本地验证。已核对四处注入点的
  变量名一致性，其余留待首次真实运行观察——`discover` 的日志应从
  `...anonymously` 变为 `Reading published image state as <account>`。
- **G-02 arm64 只有推送后验证，PR 上不覆盖。** 见 D-15 的范围限制。
- **G-03 `shellcheck` 的固定摘要是本仓库自行核对的**，上游不发布 checksums 文件。
- **G-04 attestation 未做身份签名。** 目前只有 BuildKit 的 provenance(`mode=max`)
  与 SBOM，那是**未签名**的 attestation manifest；没有接 `actions/attest`，也没有
  `id-token` / `attestations` 权限。已核实（2026-08-28）：

  - **官方方案**是 `actions/attest@v4`（最新 v4.2.2，2026-08-04）。`[文档]`
    权限以该 Action **自己的 README** 为准，它比 GitHub 文档页多一项：
    `id-token: write` / `attestations: write` / **`artifact-metadata: write`**。
    文档页另列的 `packages: write` 只为 GHCR，本仓库推 Docker Hub 不需要。
  - **`create-storage-record` 必须显式设为 `false`。** 它默认 `true`，而 storage
    record **只能为组织所有的仓库创建**；`taoziyoyo2566/xray-docker` 是个人仓库。
    不设就会失败。`[文档]`
  - **记录一次自己的漂移（2026-08-28）**：本条初版只照抄了 GitHub 文档页，漏掉了
    上面两项。教训是：**Action 的行为以它自己的 README 为准**，平台文档页可能滞后
    或只覆盖常见场景。
  - **Docker Hub 支持 OCI referrers API**，因此 `push-to-registry: true` 在本仓库可用。
    `[实测]` 2026-08-28：`GET /v2/taoziyoyo2566/xray-docker/referrers/<digest>` 返回
    HTTP 200 与合法的空 OCI index（不是 404）。官方文档未说明各 registry 的支持情况，
    此处是直接实测的结论。
  - **顺序约束（本仓库特有，落地时最容易踩）**：**不能**对
    `steps.build.outputs.digest` 签名。那是 `push-by-digest` 推上去的原始 index digest，
    而 `imagetools create` 加注解会改变 index digest（见 D-06），公开标签指向的是加注解
    **之后**的 digest。对构建产物签名会得到一份没有任何标签指向它的证明，使用者对
    `v26.3.27` 执行 `gh attestation verify` 会找不到。签名步骤必须放在
    `Publish version tag` **之后**，主体取该标签的最终 index digest。
  - **`latest` 不需要单独签名**：按设计它的 index digest 与当前 stable 版本标签相同
    （这正是 D-03 判断是否移动 latest 的依据），同一份证明即覆盖两者。
  - **权限落点**：`build-missing` 当前是 `contents: read`，需补两项；它本来就已用写
    凭据登录（要推送），`push-to-registry` 不需要额外放权。

  仍属加固项，未排期；本条记录的是落地前已经查清的约束，避免届时重新踩一遍。
- **G-06（已关闭 2026-08-28）三个 linter 的调用未被断言。** 固定摘要只保证装的是
  哪个版本，不保证它被调用到任何东西上。已补四条断言：`shellcheck` 对
  `docker-build/*.sh tests/*.sh`、`hadolint` 对 `docker-build/dockerfile`、
  `actionlint` 带固定的 `-shellcheck`，以及 D-17 那条 `-ignore` 必须恰好出现一次且
  限定到 `concurrency.queue`。`[实测]` 四条均经变异验证：改成 `--version`、换目标、
  去掉 `-shellcheck`、把 `-ignore` 放宽成 `'.*'`，全部被拦下。
- **G-05 `# syntax=docker/dockerfile:1` 引入了一个未固定的外部依赖。**
  该指令让每次构建都要从 Docker Hub 取前端镜像，与本仓库「base image、每个 action、
  三个 linter 全部按摘要固定」的姿态不一致，也给构建增加了一个网络故障点与一次
  Docker Hub 拉取。`[实测]` 2026-08-28：本机凭据失效时构建直接失败在取前端镜像这一步。
  若要保留该指令，考虑按 digest 固定它。

---

## 10. 变更批次（复盘用）

- **2026-08-27**：首次同步基线，见 runbook §6。
- **2026-08-28 第一轮**：外部审查开出 P1×5 / P2×4。修复 geodata 归属链路、confdir
  合并语义文档、CI 构建+冒烟闸门、发布契约自相矛盾、上游资产漂移检测、Dependabot
  docker、lint + CVE 扫描、只读凭据、index 注解 / 超时 / 有界重试。
- **2026-08-28 第二轮**：第二次审查指出前一轮三处未真正关闭。经逐条核实：
  - **成立**：runbook 有 5 处 + run summary 1 处仍称版本标签「不可变」，其中 §12
    回滚章节以此为前提指导操作——第一轮只改了 README 和标签表，没有全文清扫。
  - **成立**：注解脚本未参与指纹（D-04），且脚本里那条「重推一次即收敛」的注释是
    错的；但审查给出的触发条件不准确，真实行为是两个分支（见 D-04）。
  - **成立**：`queue: max`（D-12）、`EXPOSE`（D-21）。
  - **部分成立**：geodata 的 30 天条款属实且此前漏查，但审查用「三月的发布包与今日
    上游数据 digest 不同」作为证据是无效的（那是每日更新的数据文件），且把问题
    归因到「永久保留旧标签」定位错误（见 D-24）。
  - **未采纳**：`# syntax=docker/dockerfile:1`（理由见 G-05；该指令后经他人加入，
    G-05 保留为待评估项）。
- **2026-08-28 第三轮**：第三次审查确认 P1×1（真）+ 若干 P2。经逐条核实：
  - **成立且严重**：发布 summary 报的是加注解**前**的候选 digest，而第二轮我重写的
    §12 回滚恰恰指向那一行——**这个缺陷是第二轮引入的**。同一条推理（注解改变 index
    digest）我当时用在了尚未实现的签名功能上，却没回头检查已存在的代码。见 D-02b。
  - **成立**：审计不检查 stable/latest digest 等式（P2-4）、`GPL-3.0` 是废弃 SPDX ID
    （D-26）、Overview 与发布错误耦合且凭据契约不成立（D-11b）。
  - **成立，且都是我在第二轮写的文档里的漂移**：D-14 的全称断言不成立、G-04 漏了
    `artifact-metadata: write` 与 `create-storage-record`。
  - **修正了我自己的一处框架错误**：MaxMind 支持文档称「任何**使用**者都受 EULA
    约束」，比我此前「只约束缔约方」的说法宽。两方立场现已并列陈述，见 D-24。
  - **未采纳**：「该 Action 官方推荐独立工作流」——其 README 并无此推荐（拆分照做，
    但理由是本项目自己的，不是上游立场）；「代码中仍有实施历史」举的两处实为局部
    不变量注释；「文档 MECE」是体裁偏好，且其论证误引本文件第 11 行（那句说的是
    不复述代码，与体裁混合是两回事）。
- **2026-08-28 第四轮（自查，无外部审查）**：只查一类东西——文档里每一处引用了具体
  step id、output 名、secret 名、文件路径、失败条件的地方，逐条对回代码。选这个范围
  是因为第三轮我自己犯的就是这一类（D-02b），而它测试覆盖不到，只能读。查出 7 处：
  - **runbook §13** 写「只有必需标签缺失才失败」，而同一轮我刚给审计加了第二个失败
    条件（latest 与 stable digest 不等）。**改代码时漏改了描述它的那一段。**
  - **runbook §5** 的本地 `actionlint` 命令没带 `-ignore`，而 CI 带。照 runbook 跑会
    得到三条假阳性，与同一段落「三者必须为零 finding」直接矛盾。
  - **runbook §6** 记的首次同步预判「stable 不重建、latest 不移动」被实际运行推翻。
    `[实测]` 2026-08-28 读 Docker Hub：`v26.3.27` 与 `latest` 现同指
    `sha256:b891c978…`，而 §6 记的是 `sha256:a5c6e5de…`，两个标签的 `last_updated`
    都落在那次 run 内。原因是它们发布于指纹机制上线之前、身上没有 label，按判据
    补建了一次——**设计内行为，但文档把一个被推翻的预判留成了既成事实**。
  - **THIRD-PARTY-NOTICES 维护者须知**让人去改 `build-image.yml` 里的 licenses
    label，而该值的唯一来源是 `index-annotations.sh`；照做等于改了个没用的地方。
  - **D-18** 的「（见 D-25）」指错——D-25 是 GPL 全文那条，该论点实际靠的是 D-01。
  - **§10 本身**的第三轮排在第二轮前面。一份给复盘用的日志乱序，是体裁性缺陷。
  - **README** 称 `THIRD-PARTY-NOTICES.md` 的副本随镜像分发，实际随镜像走的是内容
    不同的 `NOTICE`。
  - 同批**关闭 G-06**（见上），并按「简洁 + 用法 + 注意事项 + 如何应对更新」重写
    README，新增显式的更新与钉 digest 操作段。
  - **这一轮的教训**：七条里有三条（§13、§5、§10）是**同一轮改动自己留下的**——改了
    行为却没回头改描述该行为的段落。写「只有 X 才失败」「跑的是同一组命令」这类
    全称句时，和 D-14 记的是同一个坑：要么当场核对全部，要么别写全称。
