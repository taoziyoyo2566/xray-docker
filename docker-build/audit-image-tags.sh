#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image_name="${1:-taoziyoyo2566/xray-docker}"
output_file="$(mktemp /tmp/xray-tag-audit-discovery.XXXXXX)"
trap 'rm -f -- "${output_file}"' EXIT

GITHUB_OUTPUT="${output_file}" bash "${repo_root}/docker-build/discover-release-window.sh" \
  "${image_name}" >/dev/null

read_output() {
  sed -n "s/^${1}=//p" "${output_file}"
}
expected_tags="$(read_output expected_tags)"
prerelease_versions="$(read_output prerelease_versions)"
registry_tags="$(read_output registry_tags)"
stable_tag="$(read_output stable_tag)"

declare -A expected=()
while IFS= read -r tag; do
  expected["${tag}"]=1
done < <(jq -r '.[]' <<< "${expected_tags}")
expected[latest]=1

declare -A prerelease=()
while IFS= read -r version; do
  prerelease["${version}"]=1
done < <(jq -r '.[]' <<< "${prerelease_versions}")

declare -A seen=()
kept=()
cleanup=()
review=()
while IFS=$'\t' read -r tag digest; do
  seen["${tag}"]=1
  base_version="${tag%%-r[1-9]*}"
  if [[ -n "${prerelease[${base_version}]:-}" && "${tag}" != *-beta* ]]; then
    review+=("${tag}"$'\t'"${digest}")
  elif [[ -n "${expected[${tag}]:-}" ||
          "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-beta)?(-r[1-9][0-9]*)?$ ]]; then
    kept+=("${tag}"$'\t'"${digest}")
  elif [[ "${tag}" == build-* || "${tag}" =~ ^[0-9a-f]{40}$ ]]; then
    cleanup+=("${tag}"$'\t'"${digest}")
  else
    review+=("${tag}"$'\t'"${digest}")
  fi
done < <(jq -r '.[] | [.name, .digest] | @tsv' <<< "${registry_tags}" | sort)

missing=()
for tag in "${!expected[@]}"; do
  if [[ -z "${seen[${tag}]:-}" ]]; then
    missing+=("${tag}")
  fi
done
# Avoid turning an empty array into one empty element through printf.
if [[ "${#missing[@]}" -gt 0 ]]; then
  mapfile -t missing < <(printf '%s\n' "${missing[@]}" | sort)
fi

print_group() {
  local title="$1"
  shift
  echo "## ${title}"
  if [[ "$#" -eq 0 ]]; then echo '(none)'; else printf '%s\n' "$@"; fi
  echo
}

# runbook §8 把「stable 版本标签与 latest 顶层 digest 相同」列为验收必须满足项，
# 而在此之前审计从不检查它：只要两个标签都存在，指向哪里都算通过。
# latest 指错镜像是这套发布里最直接的用户可见故障，必须由每周审计兜住。
tag_digest() {
  jq -r --arg t "$1" 'map(select(.name == $t)) | first | .digest // empty' \
    <<< "${registry_tags}"
}
latest_digest="$(tag_digest latest)"
stable_digest="$(tag_digest "${stable_tag}")"
digest_match='unknown'
if [[ -n "${latest_digest}" && -n "${stable_digest}" ]]; then
  if [[ "${latest_digest}" == "${stable_digest}" ]]; then
    digest_match='true'
  else
    digest_match='false'
  fi
fi

echo "## latest alignment"
echo "stable tag:    ${stable_tag:-(unknown)}"
echo "stable digest: ${stable_digest:-(absent)}"
echo "latest digest: ${latest_digest:-(absent)}"
case "${digest_match}" in
  true)  echo 'latest points at the current stable image.' ;;
  false) echo 'MISMATCH: latest does not point at the current stable image.' ;;
  *)     echo 'Not comparable: one of the two tags is absent (see missing tags below).' ;;
esac
echo

print_group 'Retain' "${kept[@]}"
print_group 'Cleanup candidates' "${cleanup[@]}"
print_group 'Manual review' "${review[@]}"
print_group 'Missing required tags' "${missing[@]}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "retain_count=${#kept[@]}"
    echo "cleanup_count=${#cleanup[@]}"
    echo "review_count=${#review[@]}"
    echo "missing_count=${#missing[@]}"
    echo "latest_matches_stable=${digest_match}"
  } >> "${GITHUB_OUTPUT}"
fi
