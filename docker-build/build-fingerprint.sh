#!/usr/bin/env bash
# Hash every repository input that changes image or index bytes.
# The upstream version is represented by the published tag instead.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${1:-${repo_root}/docker-build}"

inputs=(dockerfile entrypoint.sh NOTICE .dockerignore GPL-3.0.txt index-annotations.sh)

for f in "${inputs[@]}"; do
  if [[ ! -f "${build_dir}/${f}" ]]; then
    echo "build input is missing: ${build_dir}/${f}" >&2
    exit 1
  fi
done

# Preserve the declared order so filesystem ordering cannot affect the result.
{
  for f in "${inputs[@]}"; do
    printf '%s %s\n' "${f}" "$(sha256sum "${build_dir}/${f}" | cut -d' ' -f1)"
  done
} | sha256sum | cut -c1-16
