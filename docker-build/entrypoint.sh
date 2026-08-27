#!/bin/sh
set -eu

# 单文件配置（历史默认，挂载 /config.json 的部署继续可用）
config_file="${XRAY_CONFIG:-/config.json}"
# 多片段配置目录。注意 Xray 的合并语义：inbounds/outbounds 数组会追加，
# 但 routing/dns/policy 这类对象会被后读入的文件整体替换，
# 因此每个这类对象只能出现在唯一一个片段中。
config_dir="${XRAY_CONFDIR:-/etc/xray/conf.d}"

main() {
    if [ -f "${config_file}" ]; then
        set -- run -config "${config_file}"
    elif [ -d "${config_dir}" ] && [ -n "$(ls -A "${config_dir}" 2>/dev/null)" ]; then
        set -- run -confdir "${config_dir}"
    else
        echo "no configuration found: expected ${config_file} or JSON files in ${config_dir}" >&2
        exit 1
    fi

    # 先校验再启动。容器通常配 restart: always，坏配置若直接 exec 会变成静默重启循环，
    # 真正的错误信息淹没在反复的启动日志里。
    if ! xray "$@" -test; then
        echo "configuration failed validation; refusing to start" >&2
        exit 1
    fi

    exec xray "$@"
}

main "$@"
