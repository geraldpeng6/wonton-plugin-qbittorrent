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
    # 升级前的老配置没有 VueTorrent 两项；键已存在（用户可能关掉了备用 WebUI）就不碰。
    if ! grep -q '^WebUI\\AlternativeUIEnabled=' "$config_file"; then
        sed -i '/^WebUI\\AuthSubnetWhitelistEnabled=/a WebUI\\RootFolder=/vuetorrent' "$config_file"
        sed -i '/^WebUI\\AuthSubnetWhitelistEnabled=/a WebUI\\AlternativeUIEnabled=true' "$config_file"
    fi
fi

# 备用 WebUI 用 VueTorrent：官方发版取来解压进数据目录。版本与校验和写死在 docker-compose.yml。
version="${VUETORRENT_VERSION:?}"
sha256="${VUETORRENT_SHA256:?}"
dest=/vuetorrent
if [ "$(cat "$dest/.version" 2>/dev/null || true)" = "$version" ] && [ -f "$dest/public/index.html" ]; then
    exit 0
fi

zip=/tmp/vuetorrent.zip
url="https://github.com/VueTorrent/VueTorrent/releases/download/${version}/vuetorrent.zip"
# 经出网代理到 GitHub 发版 CDN 的链路可能停摆也可能只是慢（慢链路实测 37 KB/s，6.5 MB 要约 3 分钟）：
# 30 秒没等到 1 KiB 当瞬时错误触发重试，--max-time 给慢而不断的传输留足时间，-C - 让重试接着已下载的字节继续。
if ! curl -fsSL --retry 4 --retry-delay 2 --retry-max-time 180 --connect-timeout 10 \
    --speed-limit 1024 --speed-time 30 --max-time 240 -C - -o "$zip" "$url"; then
    echo "下载 VueTorrent 失败：${url}（检查出网代理是否可用、GitHub 是否可达）"
    exit 1
fi
echo "${sha256}  $zip" | sha256sum -c - || { echo "VueTorrent 校验和不匹配，删除残留后退出"; rm -f "$zip"; exit 1; }
stage=/tmp/vuetorrent-extract
rm -rf "$stage"
mkdir -p "$stage"
unzip -q "$zip" -d "$stage"
[ -f "$stage/vuetorrent/public/index.html" ] ||
    { echo "vuetorrent.zip 里没有 vuetorrent/public/index.html"; exit 1; }
# 换版本时清掉旧文件再放进新文件；挂载点本身不删。
find "$dest" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
mv "$stage/vuetorrent/"* "$dest/"
rmdir "$stage/vuetorrent" "$stage"
rm -f "$zip"
printf '%s\n' "$version" >"$dest/.version"
