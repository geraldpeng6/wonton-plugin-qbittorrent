#!/bin/sh
set -eu

config_dir=/config/qBittorrent/config
config_file="$config_dir/qBittorrent.conf"

if [ ! -e "$config_file" ]; then
    mkdir -p "$config_dir"
    sed "s/__WONTON_CORE_ADDRESS__/${WONTON_CORE_ADDRESS:?}/g" /seed/qBittorrent.conf >"$config_file"
else
    # 重装会重建插件网络，核心地址可能变化；只刷新免认证白名单，保留 qBittorrent 其他配置。
    sed -i "s|^WebUI\\\\AuthSubnetWhitelist=.*|WebUI\\\\AuthSubnetWhitelist=${WONTON_CORE_ADDRESS:?}/32|" "$config_file"
fi
