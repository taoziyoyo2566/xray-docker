#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_dir="$(mktemp -d /tmp/xray-release-discovery-test.XXXXXX)"
trap 'rm -rf -- "${fixture_dir}"' EXIT
releases="${fixture_dir}/releases.json"
tags="${fixture_dir}/tags.json"
published="${fixture_dir}/published.json"
output="${fixture_dir}/output"

fingerprint_dir="${fixture_dir}/build-inputs"
mkdir "${fingerprint_dir}"
cp "${repo_root}"/docker-build/{dockerfile,entrypoint.sh,NOTICE,.dockerignore,GPL-3.0.txt,index-annotations.sh} \
  "${fingerprint_dir}/"
fingerprint="$(bash "${repo_root}/docker-build/build-fingerprint.sh" "${fingerprint_dir}")"

# These files alter the published artifact and must change its fingerprint.
for required in index-annotations.sh GPL-3.0.txt; do
  printf '\nfingerprint probe\n' >> "${fingerprint_dir}/${required}"
  if [[ "$(bash "${repo_root}/docker-build/build-fingerprint.sh" "${fingerprint_dir}")" == "${fingerprint}" ]]; then
    echo "${required} does not affect the build fingerprint" >&2
    exit 1
  fi
  cp "${repo_root}/docker-build/${required}" "${fingerprint_dir}/${required}"
done

# Build a published-state fixture; an empty character represents a missing label.
pub_entry() {
  jq -n --arg i "$1" --arg c "$2" \
    '{inputs: $i, amd64: (if $c == "" then "" else ($c * 64) end),
      arm64: (if $c == "" then "" else ($c * 64) end)}'
}

jq -n '
  def asset($name; $char): {name: $name, digest: ("sha256:" + ($char * 64))};
  def release($tag; $pre; $char): {
    tag_name: $tag, prerelease: $pre, draft: false, published_at: "2026-01-01T00:00:00Z",
    assets: [asset("Xray-linux-64.zip"; $char), asset("Xray-linux-arm64-v8a.zip"; $char)]
  };
  [release("v26.4.2"; true; "c"), release("v26.4.1"; true; "b"),
   release("v26.3.27"; false; "a"), release("v26.3.23"; true; "d")]
' > "${releases}"
printf '%s\n' '{"results":[{"name":"v26.3.27","digest":"sha256:a"},{"name":"v26.4.1-beta","digest":"sha256:b"}]}' > "${tags}"
jq -n --argjson a "$(pub_entry "${fingerprint}" a)" --argjson b "$(pub_entry "${fingerprint}" b)" \
  '{"v26.3.27": $a, "v26.4.1-beta": $b}' > "${published}"

RELEASES_JSON_FILE="${releases}" TAG_JSON_FILE="${tags}" PUBLISHED_STATE_FILE="${published}" GITHUB_OUTPUT="${output}" \
  bash "${repo_root}/docker-build/discover-release-window.sh" \
    example/test-image >/dev/null

grep -Fx 'stable_version=v26.3.27' "${output}" >/dev/null
grep -Fx 'stable_tag=v26.3.27' "${output}" >/dev/null
grep -Fx 'expected_tags=["v26.4.2-beta","v26.4.1-beta","v26.3.27"]' "${output}" >/dev/null
grep -Fx 'prerelease_versions=["v26.4.2","v26.4.1"]' "${output}" >/dev/null
grep -Fx 'missing_count=1' "${output}" >/dev/null
jq -e '.include[0].image_tag == "v26.4.2-beta" and .include[0].amd64_sha == ("c" * 64)' \
  <<< "$(sed -n 's/^matrix=//p' "${output}")" >/dev/null

# 推送顺序决定 Docker Hub 的默认展示顺序，因此必须断言完整顺序而非仅首项。
# 覆盖三件事：多 tag 缺失、published_at 不同、以及同一秒发布的 tie-break。
jq -n '
  def asset($name; $char): {name: $name, digest: ("sha256:" + ($char * 64))};
  def release($tag; $pre; $char; $at): {
    tag_name: $tag, prerelease: $pre, draft: false, published_at: $at,
    assets: [asset("Xray-linux-64.zip"; $char), asset("Xray-linux-arm64-v8a.zip"; $char)]
  };
  [release("v26.5.3"; true; "1"; "2026-05-02T00:00:00Z"),
   release("v26.5.2"; true; "2"; "2026-05-02T00:00:00Z"),
   release("v26.5.1"; true; "3"; "2026-05-01T00:00:00Z"),
   release("v26.4.9"; false; "4"; "2026-04-09T00:00:00Z")]
' > "${releases}"
printf '%s\n' '{"results":[]}' > "${tags}"
: > "${output}"

printf '%s\n' '{}' > "${published}"
RELEASES_JSON_FILE="${releases}" TAG_JSON_FILE="${tags}" PUBLISHED_STATE_FILE="${published}" GITHUB_OUTPUT="${output}" \
  bash "${repo_root}/docker-build/discover-release-window.sh" \
    example/test-image >/dev/null

order="$(sed -n 's/^matrix=//p' "${output}" | jq -c '[.include[].image_tag]')"
expected_order='["v26.5.1-beta","v26.5.2-beta","v26.5.3-beta","v26.4.9"]'
if [[ "${order}" != "${expected_order}" ]]; then
  echo "build order is wrong" >&2
  echo "  expected: ${expected_order}" >&2
  echo "  actual:   ${order}" >&2
  exit 1
fi

# 首次发布时 Docker Hub 仓库尚不存在，tags API 返回 404。
# 该路径此前完全未被覆盖：所有用例都用 TAG_JSON_FILE 绕过了 curl。
mock_curl="${fixture_dir}/curl"
cat > "${mock_curl}" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n%s' '{"results":[],"next":null}' "${MOCK_STATUS:-200}"
MOCK
chmod 755 "${mock_curl}"

: > "${output}"
printf '%s\n' '{}' > "${published}"
RELEASES_JSON_FILE="${releases}" CURL_BIN="${mock_curl}" MOCK_STATUS=404 PUBLISHED_STATE_FILE="${published}" GITHUB_OUTPUT="${output}" \
  bash "${repo_root}/docker-build/discover-release-window.sh" \
    example/test-image >/dev/null 2>&1

if ! grep -Fx 'missing_count=4' "${output}" >/dev/null; then
  echo 'a missing Docker Hub repository was not treated as an empty tag set' >&2
  sed -n 's/^missing_count=/  actual missing_count=/p' "${output}" >&2
  exit 1
fi

# 其他 HTTP 错误必须仍然失败，不能被一并吞掉。
if RELEASES_JSON_FILE="${releases}" CURL_BIN="${mock_curl}" MOCK_STATUS=500 PUBLISHED_STATE_FILE="${published}" \
  bash "${repo_root}/docker-build/discover-release-window.sh" \
    example/test-image >/dev/null 2>&1; then
  echo 'a Docker Hub server error was accepted as an empty tag set' >&2
  exit 1
fi

# 镜像定义变化后，已存在的标签必须被重建，否则修复到不了使用者手里。
# 该 fixture 的窗口是 v26.5.1/5.2/5.3-beta 加 stable v26.4.9，全部已发布。
printf '%s\n' '{"results":[{"name":"v26.5.1-beta","digest":"sha256:a"},{"name":"v26.5.2-beta","digest":"sha256:b"},{"name":"v26.5.3-beta","digest":"sha256:c"},{"name":"v26.4.9","digest":"sha256:d"}]}' > "${tags}"
jq -n --argjson p3 "$(pub_entry "${fingerprint}" 3)" \
      --argjson p2 "$(pub_entry stale0000 2)" \
      --argjson p1 "$(pub_entry "${fingerprint}" 1)" \
      --argjson p4 "$(pub_entry "${fingerprint}" 4)" \
  '{"v26.5.1-beta": $p3, "v26.5.2-beta": $p2, "v26.5.3-beta": $p1, "v26.4.9": $p4}' > "${published}"
: > "${output}"
RELEASES_JSON_FILE="${releases}" TAG_JSON_FILE="${tags}" PUBLISHED_STATE_FILE="${published}" GITHUB_OUTPUT="${output}" \
  bash "${repo_root}/docker-build/discover-release-window.sh" \
    example/test-image >/dev/null

if ! grep -Fx 'missing_count=1' "${output}" >/dev/null; then
  echo 'a tag built from an outdated image definition was not scheduled for rebuild' >&2
  exit 1
fi
if ! jq -e '.include[0].image_tag == "v26.5.2-beta"' <<< "$(sed -n 's/^matrix=//p' "${output}")" >/dev/null; then
  echo 'the wrong tag was scheduled for rebuild' >&2
  exit 1
fi

# A converged release window must remain idle.
jq -n --argjson p3 "$(pub_entry "${fingerprint}" 3)" \
      --argjson p2 "$(pub_entry "${fingerprint}" 2)" \
      --argjson p1 "$(pub_entry "${fingerprint}" 1)" \
      --argjson p4 "$(pub_entry "${fingerprint}" 4)" \
  '{"v26.5.1-beta": $p3, "v26.5.2-beta": $p2, "v26.5.3-beta": $p1, "v26.4.9": $p4}' > "${published}"
: > "${output}"
RELEASES_JSON_FILE="${releases}" TAG_JSON_FILE="${tags}" PUBLISHED_STATE_FILE="${published}" GITHUB_OUTPUT="${output}" \
  bash "${repo_root}/docker-build/discover-release-window.sh" \
    example/test-image >/dev/null

if ! grep -Fx 'missing_count=0' "${output}" >/dev/null; then
  echo 'a fully converged window was scheduled for rebuild anyway' >&2
  sed -n 's/^missing_count=/  actual missing_count=/p' "${output}" >&2
  exit 1
fi

# A changed upstream asset digest must rebuild the affected tag.
jq -n --argjson drift "$(pub_entry "${fingerprint}" 9)" \
      --argjson p2 "$(pub_entry "${fingerprint}" 2)" \
      --argjson p1 "$(pub_entry "${fingerprint}" 1)" \
      --argjson p4 "$(pub_entry "${fingerprint}" 4)" \
  '{"v26.5.1-beta": $drift, "v26.5.2-beta": $p2, "v26.5.3-beta": $p1, "v26.4.9": $p4}' > "${published}"
: > "${output}"
RELEASES_JSON_FILE="${releases}" TAG_JSON_FILE="${tags}" PUBLISHED_STATE_FILE="${published}" GITHUB_OUTPUT="${output}" \
  bash "${repo_root}/docker-build/discover-release-window.sh" \
    example/test-image >/dev/null

if ! grep -Fx 'missing_count=1' "${output}" >/dev/null; then
  echo 'a replaced upstream asset digest did not schedule a rebuild' >&2
  sed -n 's/^missing_count=/  actual missing_count=/p' "${output}" >&2
  exit 1
fi
if ! jq -e '.include[0].image_tag == "v26.5.1-beta"' <<< "$(sed -n 's/^matrix=//p' "${output}")" >/dev/null; then
  echo 'asset drift scheduled the wrong tag for rebuild' >&2
  exit 1
fi

# Legacy tags without asset labels need one convergence rebuild.
jq -n --argjson legacy "$(pub_entry "${fingerprint}" "")" \
      --argjson p2 "$(pub_entry "${fingerprint}" 2)" \
      --argjson p1 "$(pub_entry "${fingerprint}" 1)" \
      --argjson p3 "$(pub_entry "${fingerprint}" 3)" \
  '{"v26.5.1-beta": $p3, "v26.5.2-beta": $p2, "v26.5.3-beta": $p1, "v26.4.9": $legacy}' > "${published}"
: > "${output}"
RELEASES_JSON_FILE="${releases}" TAG_JSON_FILE="${tags}" PUBLISHED_STATE_FILE="${published}" GITHUB_OUTPUT="${output}" \
  bash "${repo_root}/docker-build/discover-release-window.sh" \
    example/test-image >/dev/null

if ! jq -e '.include | length == 1 and .[0].image_tag == "v26.4.9"' \
  <<< "$(sed -n 's/^matrix=//p' "${output}")" >/dev/null; then
  echo 'a tag published without the asset-sha256 labels was not scheduled for rebuild' >&2
  exit 1
fi

echo 'Xray release discovery tests passed'
