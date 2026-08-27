#!/usr/bin/env bash
# 输出决定镜像内容的那些文件的指纹。
# 同步流程用它判断已发布的标签是否由当前的镜像定义构建；不一致即重建。
# 上游 Xray 版本不参与指纹——那由标签名本身表达。
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${1:-${repo_root}/docker-build}"

inputs=(dockerfile entrypoint.sh NOTICE .dockerignore)

for f in "${inputs[@]}"; do
  if [[ ! -f "${build_dir}/${f}" ]]; then
    echo "build input is missing: ${build_dir}/${f}" >&2
    exit 1
  fi
done

# 按固定顺序拼接文件名与内容哈希，避免文件系统顺序影响结果。
{
  for f in "${inputs[@]}"; do
    printf '%s %s\n' "${f}" "$(sha256sum "${build_dir}/${f}" | cut -d' ' -f1)"
  done
} | sha256sum | cut -c1-16
