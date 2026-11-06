# scripts/smoke.sh / dev.sh probes 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法。
# shellcheck shell=bash
# 只用钩子约定内的变量（SMOKE_STATE、SMOKE_JAR、SMOKE_WEB_URL、SMOKE_OWNER、SMOKE_BASE、SMOKE_TOKEN、
# SMOKE_INSTANCE）和助手（web_get、dweb）；SMOKE_STATE 是实例的 .wonton，数据目录和共享文件夹都从它出发。
export IDENTITY_NA=1
export SMOKE_NOTE="qBittorrent 是单用户 WebUI；应用侧没有可断言的用户身份接口，免登录由网关来源地址白名单保证。"

qbit_acceptance() (
  set -u
  local share marker swork index torrent_name torrent_file info item hash name hashes
  local downloaded speed speed_seen=0 download_file=""
  share="${SMOKE_STATE:?}/data/shares/downloads"
  marker="${SMOKE_STATE:?}/qbit-smoke-torrents.txt"
  swork="${TMPDIR:-/tmp}/wonton-qbittorrent-smoke.$$"
  mkdir -p "$swork"
  # shellcheck disable=SC2317 # trap 回调，shellcheck 看不到调用点
  cleanup() {
    hashes="$(cat "$marker" 2>/dev/null || true)"
    if [ -n "$hashes" ]; then
      web_get /api/v2/torrents/delete -X POST \
        --data-urlencode "hashes=$hashes" --data-urlencode 'deleteFiles=true' >/dev/null 2>&1 || true
    fi
    rm -f "$marker"
    rm -rf "$swork"
  }
  trap cleanup EXIT

  # 上次没跑完留下的种子先清掉，保证探针幂等。
  hashes="$(cat "$marker" 2>/dev/null || true)"
  if [ -n "$hashes" ]; then
    web_get /api/v2/torrents/delete -X POST \
      --data-urlencode "hashes=$hashes" --data-urlencode 'deleteFiles=true' >/dev/null 2>&1 || true
    rm -f "$marker"
  fi

  web_get /api/v2/app/version >/dev/null || { echo 'qBittorrent API 会话不可用'; return 1; }

  index="$(curl -fsSL --max-time 60 'https://cdimage.debian.org/debian-cd/current/amd64/bt-cd/')" || {
    echo '下载 Debian 种子目录失败'; return 1; }
  torrent_name="$(printf '%s' "$index" | python3 -c 'import re, sys; m = re.findall(r"href=[\"'"'"']([^\"'"'"']+amd64-netinst\.iso\.torrent)[\"'"'"']", sys.stdin.read()); print(m[0].rsplit("/", 1)[-1] if m else "")')"
  [ -n "$torrent_name" ] || { echo 'Debian 种子目录没有 amd64 netinst torrent'; return 1; }
  torrent_file="$swork/$torrent_name"
  curl -fsSL --max-time 120 -o "$torrent_file" \
    "https://cdimage.debian.org/debian-cd/current/amd64/bt-cd/$torrent_name" || {
    echo '下载 Debian netinst torrent 失败'; return 1; }

  info="$(web_get /api/v2/torrents/add -X POST -F "torrents=@$torrent_file")" || {
    echo "添加 Debian torrent 失败：$info"; return 1; }
  jq -e '(.success_count // 0) >= 1 and (.failure_count // 0) == 0' <<<"$info" >/dev/null 2>&1 ||
    { echo "qBittorrent 未接受 torrent：$info"; return 1; }

  for _ in $(seq 1 90); do
    info="$(web_get '/api/v2/torrents/info?filter=all')" || { echo '读取 torrent 状态失败'; return 1; }
    item="$(jq -c '[.[] | select(.name | test("debian.*netinst"; "i"))][0] // empty' <<<"$info")"
    if [ -n "$item" ]; then
      hash="$(jq -r '.hash' <<<"$item")"
      name="$(jq -r '.name' <<<"$item")"
      downloaded="$(jq -r '.downloaded // .completed // 0' <<<"$item")"
      speed="$(jq -r '.dlspeed // 0' <<<"$item")"
      [ "$speed" -gt 0 ] && speed_seen=1
      [ -n "$hash" ] && printf '%s\n' "$hash" >>"$marker"
      if [ "$downloaded" -ge 2097152 ] && [ "$speed_seen" -eq 1 ]; then
        break
      fi
    fi
    sleep 2
  done
  [ -n "${hash:-}" ] || { echo '找不到刚添加的 Debian torrent'; return 1; }
  if [ "${downloaded:-0}" -lt 2097152 ] || [ "$speed_seen" -ne 1 ]; then
    echo "Debian torrent 未达到 2 MiB 且未观察到下载速度（downloaded=${downloaded:-0}, dlspeed=${speed:-0}）"; return 1
  fi

  download_file="$(find "$share" -type f -iname '*netinst*' -print -quit 2>/dev/null || true)"
  if [ -z "$download_file" ] || [ ! -f "$download_file" ]; then
    echo "下载文件不在 downloads 共享文件夹：$share"; return 1
  fi

  web_get /api/v2/torrents/delete -X POST \
    --data-urlencode "hashes=$hash" --data-urlencode 'deleteFiles=true' >/dev/null ||
    { echo '删除 Debian torrent 失败'; return 1; }
  for _ in $(seq 1 30); do
    info="$(web_get '/api/v2/torrents/info?filter=all' 2>/dev/null || true)"
    jq -e --arg h "$hash" 'any(.[]; .hash == $h)' <<<"$info" >/dev/null 2>&1 || break
    sleep 1
  done
  hash=""
  for _ in $(seq 1 30); do
    [ ! -e "$download_file" ] && break
    sleep 1
  done
  [ ! -e "$download_file" ] || { echo "删除 torrent 后文件仍在：$download_file"; return 1; }
  echo "Debian netinst torrent 下载达到 ${downloaded} 字节且观察到速度，文件已删除：${name:-${torrent_name}}"
)

web_assert() {
  grep -qi 'VueTorrent' || return 1
  qbit_acceptance
}
