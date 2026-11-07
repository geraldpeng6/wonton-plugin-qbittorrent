# scripts/smoke.sh source 本文件，不单独执行。
# shellcheck shell=bash
# qBittorrent：sso=proxy；qBittorrent 不提供用户身份接口，主人身份由云吞网关认证。
export IDENTITY_NA=1
export SMOKE_NOTE="qBittorrent 是单用户 WebUI；应用侧没有可断言的用户身份接口，免登录由网关来源地址白名单保证。"

qbit_acceptance() (
  set -u
  local web jar dir share swork index torrent_name torrent_file info item hash name
  local downloaded speed speed_seen=0 download_file=""
  web="${E2E_WEB_URL:-${SMOKE_WEB_URL:-}}"
  web="${web%/}"   # 网关 web_url 带尾斜杠，直接拼会得到 //api/v2/...，qBittorrent 回 404 Not Found
  jar="${E2E_JAR:-${SMOKE_JAR:-}}"
  dir="${E2E_DIR:-${SMOKE_DIR:-}}"
  share="$dir/.wonton/data/shares/downloads"
  swork="${TMPDIR:-/tmp}/wonton-qbittorrent-smoke.$$"
  hash=""
  mkdir -p "$swork"
  # shellcheck disable=SC2317 # trap 回调，shellcheck 看不到调用点
  cleanup() {
    local cleanup_hashes="${hash:-}"
    if [ -z "$cleanup_hashes" ]; then
      cleanup_hashes="$(curl -sS --noproxy '*' -b "$jar" "$web/api/v2/torrents/info?filter=all" 2>/dev/null \
        | jq -r '[.[] | select(.name | test("debian.*netinst"; "i")) | .hash] | join(",")' 2>/dev/null || true)"
    fi
    if [ -n "$cleanup_hashes" ]; then
      curl -sS --noproxy '*' -b "$jar" -X POST \
        --data-urlencode "hashes=$cleanup_hashes" --data-urlencode 'deleteFiles=true' \
        "$web/api/v2/torrents/delete" >/dev/null 2>&1 || true
    fi
    rm -rf "$swork"
  }
  trap cleanup EXIT
  if ! curl -fsS --noproxy '*' -b "$jar" "$web/api/v2/app/version" >/dev/null 2>&1; then
    if [ -z "${E2E_TOKEN:-}" ] || [ -z "${E2E_BASE:-}" ]; then
      echo 'qBittorrent 插件会话失效，且没有核心登录变量'; return 1
    fi
    curl -sS --noproxy '*' -o /dev/null -c "$jar" \
      --data-urlencode "token=$E2E_TOKEN" "$E2E_BASE/_wonton/login" || {
      echo '主人令牌登录不了核心'; return 1; }
    curl -fsS --noproxy '*' -o /dev/null -L -b "$jar" -c "$jar" \
      -H 'Accept: text/html' "$web/" || {
      echo 'qBittorrent 插件网页会话登录失败'; return 1; }
  fi

  index="$(curl -fsSL --max-time 60 'https://cdimage.debian.org/debian-cd/current/amd64/bt-cd/')" || {
    echo '下载 Debian 种子目录失败'; return 1; }
  torrent_name="$(printf '%s' "$index" | python3 -c 'import re, sys; m = re.findall(r"href=[\"'"'"']([^\"'"'"']+amd64-netinst\.iso\.torrent)[\"'"'"']", sys.stdin.read()); print(m[0].rsplit("/", 1)[-1] if m else "")')"
  [ -n "$torrent_name" ] || { echo 'Debian 种子目录没有 amd64 netinst torrent'; return 1; }
  torrent_file="$swork/$torrent_name"
  curl -fsSL --max-time 120 -o "$torrent_file" \
    "https://cdimage.debian.org/debian-cd/current/amd64/bt-cd/$torrent_name" || {
    echo '下载 Debian netinst torrent 失败'; return 1; }

  info="$(curl -sS --noproxy '*' --fail-with-body -b "$jar" \
    -F "torrents=@$torrent_file" "$web/api/v2/torrents/add")" || {
    echo "添加 Debian torrent 失败：$info"; return 1; }
  jq -e '(.success_count // 0) >= 1 and (.failure_count // 0) == 0' <<<"$info" >/dev/null 2>&1 || { echo "qBittorrent 未接受 torrent：$info"; return 1; }

  for _ in $(seq 1 90); do
    info="$(curl -sS --noproxy '*' --fail-with-body -b "$jar" \
      "$web/api/v2/torrents/info?filter=all")" || { echo '读取 torrent 状态失败'; return 1; }
    item="$(jq -c '[.[] | select(.name | test("debian.*netinst"; "i"))][0] // empty' <<<"$info")"
    if [ -n "$item" ]; then
      hash="$(jq -r '.hash' <<<"$item")"
      name="$(jq -r '.name' <<<"$item")"
      downloaded="$(jq -r '.downloaded // .completed // 0' <<<"$item")"
      speed="$(jq -r '.dlspeed // 0' <<<"$item")"
      [ "$speed" -gt 0 ] && speed_seen=1
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

  curl -sS --noproxy '*' --fail-with-body -b "$jar" -X POST \
    --data-urlencode "hashes=$hash" --data-urlencode 'deleteFiles=true' \
    "$web/api/v2/torrents/delete" >/dev/null || { echo '删除 Debian torrent 失败'; return 1; }
  for _ in $(seq 1 30); do
    info="$(curl -sS --noproxy '*' --fail-with-body -b "$jar" \
      "$web/api/v2/torrents/info?filter=all")" || true
    jq -e --arg h "$hash" 'any(.[]; .hash == $h)' <<<"$info" >/dev/null 2>&1 || break
    sleep 1
  done
  hash=""
  for _ in $(seq 1 30); do
    [ ! -e "$download_file" ] && break
    sleep 1
  done
  [ ! -e "$download_file" ] || { echo "删除 torrent 后文件仍在：$download_file"; return 1; }
  echo "Debian netinst torrent 下载达到 ${downloaded} 字节且观察到速度，文件已删除：$name"
)

web_assert() {
  # 登录页同样有 qBittorrent 字样；#desktop 只有已登录的私有首页才有（登录页没有）。
  grep -q '<div id="desktop">' || return 1
  qbit_acceptance
}
