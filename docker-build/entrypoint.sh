#!/bin/sh
set -eu

# Preserve the historical single-file default.
config_file="${XRAY_CONFIG:-/config.json}"
# Xray prepends merged outbounds unless a filename contains "tail"; the first
# outbound is the default. Inspect changes with `xray run -confdir DIR -dump`.
# https://xtls.github.io/en/config/features/multiple.html
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

    # Reject invalid configuration before a restart policy can hide the cause.
    if ! xray "$@" -test; then
        echo "configuration failed validation; refusing to start" >&2
        exit 1
    fi

    exec xray "$@"
}

main "$@"
