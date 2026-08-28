#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${repo_root}/.github/workflows/build-image.yml"
audit_workflow="${repo_root}/.github/workflows/audit-xray-image-tags.yml"

grep -F 'name: Sync Xray Release Images' "${workflow}" >/dev/null
grep -F 'bash docker-build/discover-release-window.sh' "${workflow}" >/dev/null
# shellcheck disable=SC2016  # 断言的是 workflow 里的字面量 ${{ }}，不能展开
grep -F 'matrix: ${{ fromJSON(needs.discover.outputs.matrix) }}' "${workflow}" >/dev/null
grep -F 'max-parallel: 1' "${workflow}" >/dev/null
grep -F 'schedule:' "${workflow}" >/dev/null
grep -F 'workflow_dispatch:' "${workflow}" >/dev/null
grep -F 'group: xray-image-registry-state' "${workflow}" >/dev/null
grep -F 'group: xray-image-registry-state' "${audit_workflow}" >/dev/null
grep -F -- '- name: Report legacy tag debt' "${audit_workflow}" >/dev/null
grep -F -- '- name: Fail on missing required tags' "${audit_workflow}" >/dev/null
grep -F "if: steps.audit.outputs.missing_count != '0'" "${audit_workflow}" >/dev/null

if grep -F -- '- name: Fail on tag drift' "${audit_workflow}" >/dev/null; then
  echo 'audit workflow still fails on legacy tag debt' >&2
  exit 1
fi

if grep -F 'push:' "${workflow}" >/dev/null; then
  echo 'merging workflow changes triggers an implicit registry synchronization' >&2
  exit 1
fi
if grep -Eq 'type=raw,value=build-|--tag .*build-' "${workflow}"; then
  echo 'workflow publishes a public build-revision tag' >&2
  exit 1
fi

build_line="$(grep -nF -- '- name: Build and push image candidate' "${workflow}" | cut -d: -f1)"
verify_line="$(grep -nF -- '- name: Verify pushed multi-platform image' "${workflow}" | cut -d: -f1)"
publish_line="$(grep -nF -- '- name: Publish version tag' "${workflow}" | cut -d: -f1)"
if (( build_line >= verify_line || verify_line >= publish_line )); then
  echo 'image publication steps are not ordered build, verify, publish' >&2
  exit 1
fi

build_block="$(sed -n "${build_line},$((verify_line - 1))p" "${workflow}")"
if grep -Eq '^[[:space:]]+tags:' <<< "${build_block}"; then
  echo 'candidate build publishes tags before verification' >&2
  exit 1
fi

if grep -qF 'check-image-tag-available' "${workflow}"; then
  echo 'workflow still refuses to re-point a moving version tag' >&2
  exit 1
fi

grep -F 'io.taoziyoyo.xray.build-inputs=' "${workflow}" >/dev/null

# Source asset labels make mutable upstream release assets observable.
grep -F 'io.taoziyoyo.xray.asset-sha256-amd64=' "${workflow}" >/dev/null
grep -F 'io.taoziyoyo.xray.asset-sha256-arm64=' "${workflow}" >/dev/null

annotations_script="${repo_root}/docker-build/index-annotations.sh"
licenses="$(bash "${annotations_script}" --licenses)"
# shellcheck disable=SC2016
grep -F 'org.opencontainers.image.licenses=${{ steps.licenses.outputs.value }}' "${workflow}" >/dev/null

quality_workflow="${repo_root}/.github/workflows/quality.yml"
grep -F 'bash docker-build/smoke-image.sh' "${quality_workflow}" >/dev/null \
  || { echo 'the quality workflow no longer smoke-tests a built image' >&2; exit 1; }
if ! grep -qF 'load: true' "${quality_workflow}"; then
  echo 'the quality workflow no longer builds the image locally' >&2
  exit 1
fi
if grep -qE '^\s*push:\s*true' "${quality_workflow}"; then
  echo 'the quality workflow pushes an image; PR checks must not write to the registry' >&2
  exit 1
fi

# These job identifiers are the CI contract; the jobs run their own tools.
grep -qE '^  static-analysis:$' "${quality_workflow}"
grep -qE '^  image-build-smoke:$' "${quality_workflow}"

for wf in build-image.yml audit-xray-image-tags.yml; do
  if ! grep -qE '^ *queue: max$' "${repo_root}/.github/workflows/${wf}"; then
    echo "${wf} lost queue: max; a third run would silently displace a queued one" >&2
    exit 1
  fi
  if grep -qE '^ *cancel-in-progress: true$' "${repo_root}/.github/workflows/${wf}"; then
    echo "${wf} sets cancel-in-progress: true, which GitHub rejects alongside queue: max" >&2
    exit 1
  fi
done

for pin in SHELLCHECK_SHA256 ACTIONLINT_SHA256 HADOLINT_SHA256; do
  if ! grep -qE "^ *${pin}: [0-9a-f]{64}$" "${quality_workflow}"; then
    echo "the ${pin} pin is missing or malformed" >&2
    exit 1
  fi
done

# 固定摘要只保证「装的是哪个版本」，不保证它被调用到任何东西上。把某个 linter 步骤
# 改成 `--version`，或把目标换成一个不存在的路径，摘要断言照样通过。因此对着真实
# 目标断言，而不是断言工具名出现过。（decisions.md G-06）
if ! grep -qE '^ *run: shellcheck -x docker-build/\*\.sh tests/\*\.sh$' "${quality_workflow}"; then
  echo 'the shellcheck step no longer runs against docker-build/*.sh and tests/*.sh' >&2
  exit 1
fi
if ! grep -qE '^ *run: hadolint docker-build/dockerfile$' "${quality_workflow}"; then
  echo 'the hadolint step no longer runs against docker-build/dockerfile' >&2
  exit 1
fi
# shellcheck disable=SC2016  # 断言 workflow 里的字面量，不能展开
if ! grep -qF -- 'actionlint -no-color -shellcheck "$(command -v shellcheck)"' "${quality_workflow}"; then
  echo 'the actionlint step no longer runs with the pinned shellcheck' >&2
  exit 1
fi

# D-17：这条抑制必须始终限定到 concurrency.queue 这一个假阳性。放宽成整段静默会把
# actionlint 变成一个永远绿的闸门，而那正是它存在的理由。用计数比较而不是 grep 模式，
# 因为以 '-' 开头的模式会被 grep 当成选项。
ignore_lines="$(grep -c -- '-ignore' "${quality_workflow}" || true)"
scoped_lines="$(grep -cF -- "-ignore 'unexpected key \"queue\" for \"concurrency\" section'" "${quality_workflow}" || true)"
if [[ "${ignore_lines}" != '1' || "${scoped_lines}" != '1' ]]; then
  echo 'the actionlint -ignore must appear exactly once, scoped to concurrency.queue' >&2
  echo "  -ignore occurrences: ${ignore_lines}, scoped occurrences: ${scoped_lines}" >&2
  exit 1
fi

if ! grep -qF 'ignore-unfixed: true' "${quality_workflow}"; then
  echo 'the vulnerability gate no longer ignores unfixed findings' >&2
  exit 1
fi
if grep -qE "^ *severity: CRITICAL,HIGH$" "${quality_workflow}"; then
  echo 'the vulnerability gate was widened to HIGH; upstream Go CVEs would block every PR' >&2
  exit 1
fi

overview="${repo_root}/README.md"
# shellcheck disable=SC2016  # 断言的是 README 里的反引号字面量
for form in '`latest`' '`vX.Y.Z`' '`vX.Y.Z-beta`'; do
  if ! grep -qF "${form}" "${overview}"; then
    echo "overview no longer documents the ${form} tag form" >&2
    exit 1
  fi
done
if grep -qF -- '-rN' "${overview}"; then
  echo 'overview still documents a revision suffix that is no longer published' >&2
  exit 1
fi
# shellcheck disable=SC2016
grep -F -- '--tag "${IMAGE_NAME}:${IMAGE_TAG}"' "${workflow}" >/dev/null
# shellcheck disable=SC2016
grep -F -- '--tag "${IMAGE_NAME}:latest"' "${workflow}" >/dev/null
for removed_tag in stable prerelease stable-previous; do
  # shellcheck disable=SC2016
  if grep -F -- "--tag \"\${IMAGE_NAME}:${removed_tag}\"" "${workflow}" >/dev/null; then
    echo "workflow publishes removed floating tag: ${removed_tag}" >&2
    exit 1
  fi
done

if [[ -e "${repo_root}/.github/workflows/promote-xray-stable.yml" ]]; then
  echo 'unsafe alias-only stable promotion workflow still exists' >&2
  exit 1
fi
if [[ -e "${repo_root}/.github/workflows/test.yml" ]]; then
  echo 'obsolete Docker Hub push-test workflow still exists' >&2
  exit 1
fi

# Index equality requires deterministic annotations for version tags and latest.
first_run="$(bash "${annotations_script}" v26.3.27)"
second_run="$(bash "${annotations_script}" v26.3.27)"
if [[ "${first_run}" != "${second_run}" ]]; then
  echo 'index annotations are not deterministic for the same version' >&2
  exit 1
fi

for volatile in 'image.created' 'image.revision'; do
  if grep -qF "${volatile}" <<< "${first_run}"; then
    echo "index annotations contain a run-varying value: ${volatile}" >&2
    echo 'this makes the latest and version tag indexes differ on every run' >&2
    exit 1
  fi
done

while IFS= read -r annotation_line; do
  if [[ "${annotation_line}" != index:* ]]; then
    echo "index annotation is not index-scoped: ${annotation_line}" >&2
    exit 1
  fi
done <<< "${first_run}"

grep -qF 'index:org.opencontainers.image.version=v26.3.27' <<< "${first_run}" \
  || { echo 'index annotations do not carry the image version' >&2; exit 1; }

annotation_licenses="$(sed -n 's/^index:org\.opencontainers\.image\.licenses=//p' <<< "${first_run}")"
if [[ -z "${annotation_licenses}" || "${annotation_licenses}" != "${licenses}" ]]; then
  echo 'the licenses annotation disagrees with the canonical license expression' >&2
  echo "  annotation: ${annotation_licenses}" >&2
  echo "  canonical:  ${licenses}" >&2
  exit 1
fi

# 对外报告的 digest 必须是公开标签真正解析到的那个。imagetools create 加注解会
# 产出新的 index digest，而 push-by-digest 的 steps.build.outputs.digest 是加注解
# 之前的候选；用后者报告会让 runbook 的回滚指引指向一个无标签指向的镜像。
# 先剥注释：注释里也提到了这个选项，连注释一起数会让断言恒真。
workflow_code="$(sed 's/[[:space:]]*#.*$//' "${workflow}")"
if [[ "$(grep -cF -- '--metadata-file' <<< "${workflow_code}")" -ne 2 ]]; then
  echo 'both imagetools create calls must capture their result with --metadata-file' >&2
  exit 1
fi
# shellcheck disable=SC2016
if ! grep -qF 'DIGEST: ${{ steps.publish.outputs.digest }}' "${workflow}"; then
  echo 'the published-image summary must report the digest imagetools create returned' >&2
  exit 1
fi
# shellcheck disable=SC2016
if grep -qF 'DIGEST: ${{ steps.build.outputs.digest }}' "${workflow}"; then
  echo 'the summary reports the pre-annotation build digest; no public tag resolves to it' >&2
  exit 1
fi
if ! grep -qF 'containerimage.descriptor' "${workflow}"; then
  echo 'the create result digest must be read from .["containerimage.descriptor"].digest' >&2
  exit 1
fi

if [[ "$(grep -cF 'bash docker-build/index-annotations.sh' "${workflow}")" -ne 3 ]]; then
  echo 'licenses, version tags, and latest must derive metadata from index-annotations.sh' >&2
  exit 1
fi

# Authentication must precede the verification pulls.
ro_login_line="$(grep -nF -- '- name: Login to Docker Hub with read-only credentials' "${workflow}" | cut -d: -f1)"
verify_stable_line="$(grep -nF -- '- name: Verify current stable image' "${workflow}" | cut -d: -f1)"
if [[ -z "${ro_login_line}" || -z "${verify_stable_line}" ]]; then
  echo 'the read-only login or the stable verification step is missing' >&2
  exit 1
fi
if (( ro_login_line >= verify_stable_line )); then
  echo 'the stable image is verified before logging in; that pull is anonymous' >&2
  exit 1
fi

discover_block="$(sed -n '/^  discover:/,/^  build-missing:/p' "${workflow}" \
  | sed 's/[[:space:]]*#.*$//')"
if grep -qF 'DOCKERHUB_TOKEN' <<< "${discover_block}"; then
  echo 'the read-only discover job was given the write-scoped Docker Hub token' >&2
  exit 1
fi

# 审计必须真的因 latest 指错而失败；只产出一个 output 而没人读它等于没检查。
# shellcheck disable=SC2016
if ! grep -qF "steps.audit.outputs.latest_matches_stable == 'false'" "${audit_workflow}"; then
  echo 'the audit workflow does not fail when latest stops pointing at stable' >&2
  exit 1
fi

for wf in "${workflow}" "${audit_workflow}" \
          "${repo_root}/.github/workflows/quality.yml" \
          "${repo_root}/.github/workflows/sync-dockerhub-overview.yml"; do
  # 只统计 jobs: 之后的二级键——on: 下面的 schedule: 缩进相同，会被误计。
  job_count="$(awk '/^jobs:/ {in_jobs = 1; next}
                    in_jobs && /^  [a-z][a-z0-9-]*:$/ {n++}
                    END {print n + 0}' "${wf}")"
  timeout_count="$(grep -cE '^    timeout-minutes: [0-9]+$' "${wf}")"
  if [[ "${job_count}" -ne "${timeout_count}" ]]; then
    echo "not every job in ${wf} has a bounded timeout (${timeout_count}/${job_count})" >&2
    exit 1
  fi
done

echo 'Xray release synchronization workflow tests passed'
