#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
availability="${repo_root}/docker-build/check-image-tag-available.sh"
overview="${repo_root}/README.md"
fixture_dir="$(mktemp -d /tmp/xray-image-tags-test.XXXXXX)"
trap 'rm -rf -- "${fixture_dir}"' EXIT

# Overview 是使用者看到的标签契约。断言标签标识符本身而不是措辞：
# 前者是契约的一部分，后者只是行文，改写文档不应弄坏测试。
for form in '`latest`' '`vX.Y.Z`' '`vX.Y.Z-beta`' '`vX.Y.Z-rN`' '`vX.Y.Z-beta-rN`'; do
  if ! grep -qF "${form}" "${overview}"; then
    echo "overview no longer documents the ${form} tag form" >&2
    exit 1
  fi
done
if ! grep -qF 'The only tag that moves' "${overview}"; then
  echo 'overview no longer states that latest is the sole moving tag' >&2
  exit 1
fi
if ! grep -qF 'never moved to different content' "${overview}"; then
  echo 'overview no longer states that version tags are immutable' >&2
  exit 1
fi

mock_curl="${fixture_dir}/curl"
cat > "${mock_curl}" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "${MOCK_STATUS:-404}" in
  200) printf '{}\n200' ;;
  404) printf '{}\n404' ;;
  *) printf '{}\n500' ;;
esac
MOCK
chmod 755 "${mock_curl}"

CURL_BIN="${mock_curl}" MOCK_STATUS=404 \
  bash "${availability}" example/test-image v26.3.27-r1 >/dev/null
for status in 200 500; do
  if CURL_BIN="${mock_curl}" MOCK_STATUS="${status}" \
    bash "${availability}" example/test-image v26.3.27-r1 \
      >/dev/null 2>&1; then
    echo "unavailable immutable tag was accepted for HTTP ${status}" >&2
    exit 1
  fi
done

echo 'Xray immutable image tag tests passed'
