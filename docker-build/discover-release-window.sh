#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image_name="${1:-taoziyoyo2566/xray-docker}"
curl_bin="${CURL_BIN:-curl}"

if [[ ! "${image_name}" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ ]]; then
  echo "invalid Docker Hub image name: '${image_name}'" >&2
  exit 1
fi

# Retry transient failures while leaving deterministic HTTP errors fail-closed.
curl_opts=(--retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60)

# 决定镜像内容的那些文件的指纹。已发布的标签把它记在 label 里，
# 比对不上就说明该标签是用旧的镜像定义构建的，需要重建。
build_inputs="$(bash "${repo_root}/docker-build/build-fingerprint.sh")"

if [[ -n "${RELEASES_JSON_FILE:-}" ]]; then
  releases_json="$(< "${RELEASES_JSON_FILE}")"
else
  releases_json='[]'
  page=1
  github_auth=()
  if [[ -n "${GH_TOKEN:-}" ]]; then
    github_auth=(-H "Authorization: Bearer ${GH_TOKEN}")
  fi
  while true; do
    page_json="$("${curl_bin}" --fail --silent --show-error --location "${curl_opts[@]}" \
      -H 'Accept: application/vnd.github+json' \
      "${github_auth[@]}" \
      -H 'X-GitHub-Api-Version: 2026-03-10' \
      "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=100&page=${page}")"
    if ! jq -e 'type == "array"' <<< "${page_json}" >/dev/null; then
      echo 'GitHub releases response is not an array' >&2
      exit 1
    fi
    releases_json="$(jq -sc '.[0] + .[1]' \
      <(printf '%s\n' "${releases_json}") <(printf '%s\n' "${page_json}"))"
    if jq -e 'map(select(.draft == false and .prerelease == false)) | length > 0' <<< "${releases_json}" >/dev/null; then
      break
    fi
    if [[ "$(jq 'length' <<< "${page_json}")" -eq 0 || "${page}" -ge 10 ]]; then
      echo 'no non-draft stable GitHub release found' >&2
      exit 1
    fi
    page=$((page + 1))
  done
fi

window_json="$(jq -ce '
  if type != "array" then error("releases response is not an array") else . end
  | (to_entries | map(select(.value.draft == false and .value.prerelease == false)) | first | .key) as $stable_index
  | if $stable_index == null then error("no non-draft stable release found") else . end
  | .[0:($stable_index + 1)]
  | map(select(.draft == false))
  | map(
      . as $release
      | .tag_name as $version
      | ([.assets[]? | select(.name == "Xray-linux-64.zip") | .digest] | first) as $amd64
      | ([.assets[]? | select(.name == "Xray-linux-arm64-v8a.zip") | .digest] | first) as $arm64
      | if ($version | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$") | not) then error("invalid release tag: " + $version)
        elif (($amd64 // "") | test("^sha256:[0-9a-f]{64}$") | not) then error("invalid amd64 digest for " + $version)
        elif (($arm64 // "") | test("^sha256:[0-9a-f]{64}$") | not) then error("invalid arm64 digest for " + $version)
        else {
          version: $version,
          prerelease: .prerelease,
          channel: (if .prerelease then "beta" else "stable" end),
          image_tag: ($version + (if .prerelease then "-beta" else "" end)),
          amd64_sha: ($amd64 | sub("^sha256:"; "")),
          arm64_sha: ($arm64 | sub("^sha256:"; "")),
          published_at: .published_at
        } end
    )
' <<< "${releases_json}")"

if [[ -n "${TAG_JSON_FILE:-}" ]]; then
  tags_json="$(< "${TAG_JSON_FILE}")"
else
  tags_json='{"results":[]}'
  next_url="https://hub.docker.com/v2/repositories/${image_name}/tags?page_size=100"
  first_page=1
  while [[ -n "${next_url}" ]]; do
    response="$("${curl_bin}" --silent --show-error --location "${curl_opts[@]}" \
      --write-out $'\n%{http_code}' "${next_url}")"
    status="${response##*$'\n'}"
    page_json="${response%$'\n'*}"
    # 仓库尚不存在时 Docker Hub 返回 404。首次发布时这是正常状态，
    # 等价于“没有任何标签”，整个窗口都待构建。仅首页接受该状态：
    # 后续页的 URL 来自 API 自身，那里出现 404 属于异常。
    if [[ "${status}" == "404" && "${first_page}" -eq 1 ]]; then
      echo "Docker Hub repository does not exist yet: ${image_name}" >&2
      break
    fi
    if [[ "${status}" != "200" ]]; then
      echo "Docker Hub returned HTTP ${status} while listing tags for ${image_name}" >&2
      exit 1
    fi
    tags_json="$(jq -sc '{results: (.[0].results + .[1].results)}' \
      <(printf '%s\n' "${tags_json}") <(printf '%s\n' "${page_json}"))"
    next_url="$(jq -r '.next // empty' <<< "${page_json}")"
    first_page=0
  done
fi
if ! jq -e '.results | type == "array"' <<< "${tags_json}" >/dev/null; then
  echo 'Docker Hub tag response does not contain a results array' >&2
  exit 1
fi

registry_names="$(jq -c '[.results[].name]' <<< "${tags_json}")"

# Return {tag: {inputs, amd64, arm64}} from image labels or a test fixture.
read_published_state() {
  if [[ -n "${PUBLISHED_STATE_FILE:-}" ]]; then
    cat "${PUBLISHED_STATE_FILE}"
    return
  fi

  local accept_index='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json'
  local accept_manifest='application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'
  # Optional read-only credentials use the account quota instead of runner IP quota.
  local token registry_auth=()
  if [[ -n "${DOCKERHUB_USERNAME:-}" && -n "${DOCKERHUB_RO_TOKEN:-}" ]]; then
    registry_auth=(--user "${DOCKERHUB_USERNAME}:${DOCKERHUB_RO_TOKEN}")
    echo "Reading published image state as ${DOCKERHUB_USERNAME}" >&2
  else
    echo 'Reading published image state anonymously; set DOCKERHUB_USERNAME and DOCKERHUB_RO_TOKEN to use the account quota' >&2
  fi
  token="$("${curl_bin}" --fail --silent --show-error --location "${curl_opts[@]}" \
    "${registry_auth[@]}" \
    "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${image_name}:pull" \
    | jq -r '.token')"
  if [[ -z "${token}" || "${token}" == "null" ]]; then
    echo "could not obtain a registry pull token for ${image_name}" >&2
    exit 1
  fi

  local out='{}' tag index child manifest config blob value
  while IFS= read -r tag; do
    jq -e --arg t "${tag}" '.results | any(.name == $t)' <<< "${tags_json}" >/dev/null || continue

    index="$("${curl_bin}" --silent --show-error --location "${curl_opts[@]}" \
      -H "Authorization: Bearer ${token}" -H "Accept: ${accept_index},${accept_manifest}" \
      "https://registry-1.docker.io/v2/${image_name}/manifests/${tag}")"
    child="$(jq -r '[.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "amd64") | .digest] | first // empty' <<< "${index}")"
    if [[ -z "${child}" ]]; then
      echo "could not resolve an amd64 manifest for ${image_name}:${tag}" >&2
      exit 1
    fi

    manifest="$("${curl_bin}" --silent --show-error --location "${curl_opts[@]}" \
      -H "Authorization: Bearer ${token}" -H "Accept: ${accept_manifest}" \
      "https://registry-1.docker.io/v2/${image_name}/manifests/${child}")"
    config="$(jq -r '.config.digest // empty' <<< "${manifest}")"
    if [[ -z "${config}" ]]; then
      echo "could not resolve an image config for ${image_name}:${tag}" >&2
      exit 1
    fi

    # --fail distinguishes an absent label from an HTTP error response.
    if ! blob="$("${curl_bin}" --fail --silent --show-error --location "${curl_opts[@]}" \
      -H "Authorization: Bearer ${token}" \
      "https://registry-1.docker.io/v2/${image_name}/blobs/${config}")"; then
      echo "could not read the image config blob for ${image_name}:${tag}" >&2
      exit 1
    fi
    value="$(jq -c '.config.Labels // {} | {
        inputs: (.["io.taoziyoyo.xray.build-inputs"] // ""),
        amd64:  (.["io.taoziyoyo.xray.asset-sha256-amd64"] // ""),
        arm64:  (.["io.taoziyoyo.xray.asset-sha256-arm64"] // "")
      }' <<< "${blob}")"
    out="$(jq -c --arg t "${tag}" --argjson v "${value}" '.[$t] = $v' <<< "${out}")"
  done < <(jq -r '.[].image_tag' <<< "${window_json}")

  printf '%s' "${out}"
}

published_state="$(read_published_state)"
# Docker Hub 的 tag 页默认按 last_updated 倒序，因此推送顺序决定展示顺序。
# 输入为 GitHub 的新→旧顺序；先 reverse 再按 published_at 稳定排序，
# 使同一秒发布的 release 也保持旧→新（jq 的 sort_by 是稳定排序）。
# 最后把唯一的 stable 排到末位，令其成为最后推送、在页面上位于 beta 之上的一个。
missing_json="$(jq -c --argjson names "${registry_names}" \
  --argjson published "${published_state}" --arg inputs "${build_inputs}" '
  [.[] | select(
      . as $release
      | ($names | index($release.image_tag) | not)          # 标签尚不存在
        or (($published[$release.image_tag] // {}) as $pub
            | (($pub.inputs // "") != $inputs)               # 由旧的镜像定义构建
              or (($pub.amd64 // "") != $release.amd64_sha)  # 上游资产已被替换
              or (($pub.arm64 // "") != $release.arm64_sha)))
  ]
  | reverse
  | sort_by(.published_at)
  | (map(select(.prerelease)) + map(select(.prerelease | not)))
' <<< "${window_json}")"
matrix="$(jq -cn --argjson include "${missing_json}" '{include: $include}')"
expected_tags="$(jq -c '[.[].image_tag]' <<< "${window_json}")"
prerelease_versions="$(jq -c '[.[] | select(.prerelease) | .version]' <<< "${window_json}")"
stable_version="$(jq -r '[.[] | select(.prerelease == false)] | first | .version' <<< "${window_json}")"
stable_tag="$(jq -r '[.[] | select(.prerelease == false)] | first | .image_tag' <<< "${window_json}")"
missing_count="$(jq 'length' <<< "${missing_json}")"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "matrix=${matrix}"
    echo "expected_tags=${expected_tags}"
    echo "prerelease_versions=${prerelease_versions}"
    echo "registry_tags=$(jq -c '.results' <<< "${tags_json}")"
    echo "missing_count=${missing_count}"
    echo "stable_version=${stable_version}"
    echo "stable_tag=${stable_tag}"
    echo "build_inputs=${build_inputs}"
  } >> "${GITHUB_OUTPUT}"
fi

echo "Release window: ${stable_version} through $(jq -r 'first.version' <<< "${window_json}")"
jq -r '.[] | [.image_tag, .channel] | @tsv' <<< "${window_json}"
echo "Build inputs fingerprint: ${build_inputs}"
echo "Tags to build or refresh: ${missing_count}"
