#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${repo_root}/.github/workflows/build-image.yml"
audit_workflow="${repo_root}/.github/workflows/audit-xray-image-tags.yml"

grep -F 'name: Sync Xray Release Images' "${workflow}" >/dev/null
grep -F 'bash docker-build/discover-release-window.sh' "${workflow}" >/dev/null
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

# 版本标签现在是移动别名，重新指向属正常发布路径；旧的“拒绝覆盖”守卫会挡住它。
if grep -qF 'check-image-tag-available' "${workflow}"; then
  echo 'workflow still refuses to re-point a moving version tag' >&2
  exit 1
fi

# 构建指纹必须写进镜像，否则下一次同步无从判断标签是否由当前定义构建。
grep -F 'io.taoziyoyo.xray.build-inputs=' "${workflow}" >/dev/null

# Overview 承载标签契约。断言标签标识符本身而不是措辞。
overview="${repo_root}/README.md"
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

echo 'Xray release synchronization workflow tests passed'
