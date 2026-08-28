#!/usr/bin/env bash
# 对一个已构建的镜像做行为冒烟。与 verify-image.sh 分工：
#   verify-image.sh —— 推送后、打标签前，逐平台确认版本与 entrypoint 可达；
#   smoke-image.sh  —— 合入前，在构建平台上跑完整行为矩阵。
# 需要能运行该镜像的 Docker；不访问 registry 之外的任何外部服务。
set -euo pipefail

image_ref="${1:-}"
expected_version="${2:-}"
docker_bin="${DOCKER_BIN:-docker}"

if [[ -z "${image_ref}" ]]; then
  echo "usage: smoke-image.sh <image-ref> [expected-version]" >&2
  exit 2
fi
if [[ -n "${expected_version}" && ! "${expected_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "expected version must use vX.Y.Z form: '${expected_version}'" >&2
  exit 1
fi

work_dir="$(mktemp -d)"
container="xray-smoke-$$"
cleanup() {
  "${docker_bin}" rm -f "${container}" >/dev/null 2>&1 || true
  rm -rf -- "${work_dir}"
}
trap cleanup EXIT

pass=0
ok() { pass=$((pass + 1)); printf '  ok  %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; exit 1; }

run_sh() { "${docker_bin}" run --rm --entrypoint /bin/sh "${image_ref}" -c "$1"; }

# --- 1. 二进制与版本 ---------------------------------------------------------
first_line="$("${docker_bin}" run --rm --entrypoint /usr/bin/xray "${image_ref}" -version | sed -n '1p')"
actual_version="$(awk '$1 == "Xray" { print "v" $2; exit }' <<< "${first_line}")"
[[ "${actual_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "could not read Xray version: '${first_line}'"
if [[ -n "${expected_version}" && "${actual_version}" != "${expected_version}" ]]; then
  fail "image contains ${actual_version}, expected ${expected_version}"
fi
ok "xray reports ${actual_version}"

# --- 2. 运行身份 -------------------------------------------------------------
id_line="$(run_sh 'id -u; id -g')"
[[ "$(sed -n 1p <<< "${id_line}")" == '10000' ]] || fail "container uid is not 10000: ${id_line}"
[[ "$(sed -n 2p <<< "${id_line}")" == '10000' ]] || fail "container gid is not 10000: ${id_line}"
ok "runs as uid/gid 10000"

# --- 3. 随镜像分发的资产与许可文件 -------------------------------------------
# NOTICE 里的 MaxMind 署名是 GeoLite EULA 的硬性要求，掉了即违约，因此断言到具体行。
for f in /usr/local/share/xray/geoip.dat /usr/local/share/xray/geosite.dat \
         /usr/share/licenses/xray/LICENSE /usr/share/licenses/xray/NOTICE \
         /usr/share/licenses/geodata/GPL-3.0.txt; do
  run_sh "[ -s '${f}' ]" || fail "missing or empty in image: ${f}"
done
run_sh 'grep -q "GeoLite2 data created by MaxMind" /usr/share/licenses/xray/NOTICE' \
  || fail 'the required MaxMind attribution is missing from the in-image NOTICE'
# 镜像在 licenses label 里断言了 GPL-3.0；断言成立就必须附带全文，
# 否则那条 label 是没有支撑的。断言到许可证自身的标题行而不只是文件存在。
run_sh 'grep -q "GNU GENERAL PUBLIC LICENSE" /usr/share/licenses/geodata/GPL-3.0.txt' \
  || fail 'the shipped GPL-3.0.txt is not the GPL-3.0 text'
ok "geodata and license notices ship in the image"

# --- 4. 无配置时的失败路径（走真实 entrypoint）-------------------------------
if out="$("${docker_bin}" run --rm "${image_ref}" 2>&1)"; then
  fail "the entrypoint started without any configuration"
fi
grep -qF 'no configuration found' <<< "${out}" \
  || fail "unexpected no-config message: ${out}"
ok "no configuration is refused with the documented message"

# --- 5. 坏配置必须在启动前被拦下 ---------------------------------------------
printf '%s\n' '{ this is not json' > "${work_dir}/broken.json"
if out="$("${docker_bin}" run --rm -v "${work_dir}/broken.json:/config.json:ro" "${image_ref}" 2>&1)"; then
  fail "the entrypoint started with an invalid configuration"
fi
grep -qF 'configuration failed validation' <<< "${out}" \
  || fail "unexpected invalid-config message: ${out}"
ok "an invalid configuration is refused before xray starts"

# --- 6. 单文件配置 + 硬化运行 + healthcheck ----------------------------------
cat > "${work_dir}/config.json" <<'JSON'
{
  "log": {"loglevel": "warning"},
  "inbounds": [{"tag": "in", "port": 10808, "listen": "127.0.0.1", "protocol": "socks", "settings": {"udp": false}}],
  "outbounds": [{"tag": "direct", "protocol": "freedom"}]
}
JSON
"${docker_bin}" run -d --name "${container}" \
  --read-only --cap-drop ALL --security-opt no-new-privileges \
  -e XRAY_HEALTH_PORT=10808 \
  -v "${work_dir}/config.json:/config.json:ro" \
  "${image_ref}" >/dev/null

health=''
for _ in $(seq 1 40); do
  health="$("${docker_bin}" inspect --format '{{.State.Health.Status}}' "${container}" 2>/dev/null || echo missing)"
  [[ "${health}" == 'healthy' || "${health}" == 'unhealthy' ]] && break
  sleep 2
done
if [[ "${health}" != 'healthy' ]]; then
  echo "--- container logs ---" >&2
  "${docker_bin}" logs "${container}" >&2 2>&1 || true
  fail "container did not become healthy under --read-only --cap-drop ALL --security-opt no-new-privileges (status: ${health})"
fi
# 先落到变量再匹配：grep -q 会提前关闭管道，docker logs 收到 SIGPIPE 后
# 在 pipefail 下会把整条管道判成失败。
startup_logs="$("${docker_bin}" logs "${container}" 2>&1)"
grep -qF 'Xray' <<< "${startup_logs}" \
  || fail "container logs do not mention Xray starting: ${startup_logs}"
"${docker_bin}" rm -f "${container}" >/dev/null
ok "single-file config runs healthy with a read-only root and no capabilities"

# --- 7. 片段目录 + README 记录的合并语义 -------------------------------------
# 新 outbound 默认前插，文件名含 tail 时改为追加。README 和 entrypoint 注释都按
# 这个语义写；此处对着真实 xray 断言，避免上游改语义后文档无声变错。
mkdir -p "${work_dir}/conf.d"
cat > "${work_dir}/conf.d/01_base.json" <<'JSON'
{
  "log": {"loglevel": "warning"},
  "inbounds": [{"tag": "in", "port": 10809, "listen": "127.0.0.1", "protocol": "socks", "settings": {"udp": false}}],
  "outbounds": [{"tag": "direct", "protocol": "freedom"}]
}
JSON
printf '%s\n' '{"outbounds": [{"tag": "blocked", "protocol": "blackhole"}]}' \
  > "${work_dir}/conf.d/99_tail.json"

dump_tags() {
  "${docker_bin}" run --rm --entrypoint /usr/bin/xray \
    -v "${work_dir}/conf.d:/etc/xray/conf.d:ro" "${image_ref}" \
    run -confdir /etc/xray/conf.d -dump 2>/dev/null | jq -c '[.outbounds[].tag]'
}
tail_order="$(dump_tags)"
[[ "${tail_order}" == '["direct","blocked"]' ]] \
  || fail "a *tail* fragment did not append its outbound: ${tail_order}"

mv "${work_dir}/conf.d/99_tail.json" "${work_dir}/conf.d/99_extra.json"
plain_order="$(dump_tags)"
[[ "${plain_order}" == '["blocked","direct"]' ]] \
  || fail "a non-tail fragment did not prepend its outbound: ${plain_order}"
mv "${work_dir}/conf.d/99_extra.json" "${work_dir}/conf.d/99_tail.json"
ok "confdir merge order matches the documented tail rule"

"${docker_bin}" run -d --name "${container}" \
  -e XRAY_HEALTH_PORT=10809 \
  -v "${work_dir}/conf.d:/etc/xray/conf.d:ro" \
  "${image_ref}" >/dev/null
health=''
for _ in $(seq 1 40); do
  health="$("${docker_bin}" inspect --format '{{.State.Health.Status}}' "${container}" 2>/dev/null || echo missing)"
  [[ "${health}" == 'healthy' || "${health}" == 'unhealthy' ]] && break
  sleep 2
done
if [[ "${health}" != 'healthy' ]]; then
  echo "--- container logs ---" >&2
  "${docker_bin}" logs "${container}" >&2 2>&1 || true
  fail "the confdir path did not become healthy (status: ${health})"
fi
"${docker_bin}" rm -f "${container}" >/dev/null
ok "fragment directory config runs healthy"

echo "Xray image smoke tests passed (${pass} checks) for ${image_ref}"
