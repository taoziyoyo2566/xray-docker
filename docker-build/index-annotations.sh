#!/usr/bin/env bash
# Emit deterministic index annotations shared by version tags and latest.
set -euo pipefail

# SPDX 已把 GPL-3.0 标为废弃；其正式名称本就是 "GNU General Public License v3.0
# only"，因此 GPL-3.0-only 是等价替换，不额外断言任何东西。上游 v2ray-rules-dat
# 只提供一份裸 LICENSE，没有 "or any later version" 的授予声明，保守读作 only。
licenses='MPL-2.0 AND GPL-3.0-only AND MIT AND CC-BY-SA-4.0 AND LicenseRef-MaxMind-GeoLite-EULA'
if [[ "${1:-}" == '--licenses' ]]; then
  printf '%s\n' "${licenses}"
  exit 0
fi

version="${1:-}"
if [[ ! "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "index-annotations.sh: version must use vX.Y.Z form: '${version}'" >&2
  exit 1
fi

source_url='https://github.com/taoziyoyo2566/xray-docker'

printf 'index:%s\n' \
  "org.opencontainers.image.title=xray-docker" \
  "org.opencontainers.image.description=Xray-core packaged for linux/amd64 and linux/arm64" \
  "org.opencontainers.image.source=${source_url}" \
  "org.opencontainers.image.url=${source_url}" \
  "org.opencontainers.image.version=${version}" \
  "org.opencontainers.image.licenses=${licenses}"
