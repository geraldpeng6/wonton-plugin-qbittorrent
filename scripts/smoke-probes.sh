# scripts/smoke.sh source 本文件，不单独执行。
# shellcheck shell=bash
# qBittorrent：sso=proxy；qBittorrent 不提供用户身份接口，主人身份由云吞网关认证。
export IDENTITY_NA=1
export SMOKE_NOTE="qBittorrent 是单用户 WebUI；应用侧没有可断言的用户身份接口，免登录由网关来源地址白名单保证。"

qbit_session() (
  # 会话有效就直接用；失效时用核心登录变量重建。qBittorrent 不认 Remote-User，免登录靠网关来源白名单。
  set -u
  local web jar
  web="${SMOKE_WEB_URL:?SMOKE_WEB_URL 未导出}"
  jar="${SMOKE_JAR:?SMOKE_JAR 未导出}"
  curl -fsS --noproxy '*' -b "$jar" "$web/api/v2/app/version" >/dev/null 2>&1 && return 0
  local token base
  token="${SMOKE_TOKEN:-}"
  base="${SMOKE_BASE:-}"
  if [ -z "$token" ] || [ -z "$base" ]; then
    echo 'qBittorrent 插件会话失效，且没有核心登录变量'; return 1
  fi
  curl -sS --noproxy '*' -o /dev/null -c "$jar" \
    --data-urlencode "token=$token" "$base/_wonton/login" || {
    echo '主人令牌登录不了核心'; return 1; }
  curl -fsS --noproxy '*' -o /dev/null -L -b "$jar" -c "$jar" \
    -H 'Accept: text/html' "$web/" || {
    echo 'qBittorrent 插件网页会话登录失败'; return 1; }
)

# data_write：在应用里写一条落盘的数据标记（分类，存进 categories.json），升级/重装后由 data_check 验证。
data_write() (
  set -eu
  local web jar code
  web="${SMOKE_WEB_URL:?SMOKE_WEB_URL 未导出}"
  jar="${SMOKE_JAR:?SMOKE_JAR 未导出}"
  qbit_session || return 1
  # 先删旧标记再建，冒烟重跑不残留。
  curl -sS --noproxy '*' -b "$jar" -X POST --data-urlencode 'categories=wonton-smoke' \
    "$web/api/v2/torrents/deleteCategories" >/dev/null 2>&1 || true
  code="$(curl -sS --noproxy '*' -b "$jar" -o /dev/null -w '%{http_code}' \
    -X POST --data-urlencode 'category=wonton-smoke' "$web/api/v2/torrents/createCategory")"
  [ "$code" = 200 ] || { echo "写数据标记失败：createCategory HTTP $code"; return 1; }
  echo "已写数据标记：分类 wonton-smoke"
)

# data_check：升级/重装后分类还在，应用数据才算保住。
data_check() (
  set -eu
  local web jar cats
  web="${SMOKE_WEB_URL:?SMOKE_WEB_URL 未导出}"
  jar="${SMOKE_JAR:?SMOKE_JAR 未导出}"
  qbit_session || return 1
  cats="$(curl -sS --noproxy '*' --fail-with-body -b "$jar" "$web/api/v2/torrents/categories")" || {
    echo "读分类失败：${cats:-（空响应）}"; return 1; }
  jq -e 'has("wonton-smoke")' <<<"$cats" >/dev/null || {
    echo "升级/重装后找不到 wonton-smoke 分类：$(head -c 200 <<<"$cats")"; return 1; }
  echo "wonton-smoke 分类还在：升级/重装保住了数据"
)

qbit_acceptance() (
  set -u
  local web jar core share swork index torrent_name torrent_file info item hash name
  local downloaded speed speed_seen=0 download_file=""
  web="${SMOKE_WEB_URL:?SMOKE_WEB_URL 未导出}"
  jar="${SMOKE_JAR:?SMOKE_JAR 未导出}"
  core="${SMOKE_CORE:?SMOKE_CORE 未导出}"
  # downloads 共享目录在核心容器的数据目录里，探针从那里核对文件落位（宿主没有实例数据路径）。
  share="$SMOKE_DATA_DIR/shares/downloads"
  swork="${TMPDIR:-/tmp}/wonton-qbittorrent-smoke.$$"
  hash=""
  mkdir -p "$swork"
  # shellcheck disable=SC2317,SC2329 # trap 回调，shellcheck 看不到调用点
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
  qbit_session || { echo 'qBittorrent 插件网页会话登录失败'; return 1; }

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

  download_file="$(docker exec "$core" find "$share" -type f -iname '*netinst*' -print -quit 2>/dev/null || true)"
  if [ -z "$download_file" ] || ! docker exec "$core" test -f "$download_file"; then
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
    docker exec "$core" test -e "$download_file" 2>/dev/null || break
    sleep 1
  done
  if docker exec "$core" test -e "$download_file" 2>/dev/null; then
    echo "删除 torrent 后文件仍在：$download_file"; return 1
  fi
  echo "Debian netinst torrent 下载达到 ${downloaded} 字节且观察到速度，文件已删除：$name"
)

web_assert() {
  grep -qi 'VueTorrent' || return 1
  qbit_acceptance
}

# ---------- 通知邮件（notify，规范 0.11）----------
qbit_room_wait() { # <超时秒> <要找的文字>：等主人的「Wonton」私聊出现这段文字（套件助手读
	# SMOKE_CORE/SMOKE_DATA_DIR/SMOKE_OWNER，都在探针环境里）。测试信没有随机的标记，文字用
	# 插件前缀；冒烟里 extra_check 是唯一发信方，等待开始后出现即可认。
	probes_owner_room_wait "$1" "$2"
}

extra_check() (
	# 发信端到端：应用自己的「发送测试邮件」接口真发一封（收件人是 init 写进配置的主人内部邮箱），
	# 核心投进主人私聊后从 Mailpit 取走删除
	set -u
	local web jar to out wp code
	web="${SMOKE_WEB_URL:?SMOKE_WEB_URL 未导出}"
	jar="${SMOKE_JAR:?SMOKE_JAR 未导出}"
	to="${SMOKE_OWNER:-owner}@wonton.internal"
	qbit_session || { echo 'qBittorrent 插件网页会话登录失败'; return 1; }
	# 配置里的通知邮件收件人应是主人的内部邮箱（init 服务写好的）。
	out="$(curl -sS --noproxy '*' --fail-with-body -b "$jar" "$web/api/v2/app/preferences")" ||
		{ echo "读偏好失败：$(echo "$out" | head -c 200)"; return 1; }
	jq -e --arg to "$to" '.mail_notification_email == $to and .mail_notification_enabled == true' <<<"$out" >/dev/null ||
		{ echo "通知邮件配置不对：$(jq -c '{mail_notification_enabled, mail_notification_email}' <<<"$out")"; return 1; }
	# 触发一封真实测试信。
	code="$(curl -sS --noproxy '*' -b "$jar" -o /dev/null -w '%{http_code}' -X POST "$web/api/v2/app/sendTestEmail")"
	[ "$code" = 200 ] || { echo "sendTestEmail HTTP $code"; return 1; }
	# 等待先挂后台再触发（模板的用法）：信进私聊是秒级投递，先等后发才等得到。
	qbit_room_wait 120 "qBittorrent：" & wp=$!
	# 触发一封真实测试信。
	code="$(curl -sS --noproxy '*' -b "$jar" -o /dev/null -w '%{http_code}' -X POST "$web/api/v2/app/sendTestEmail")"
	[ "$code" = 200 ] || { kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null; echo "sendTestEmail HTTP $code"; return 1; }
	# 核心把信投进主人的「Wonton」私聊：房里出现这一封。
	wait "$wp" || { echo "测试信 120 秒没出现在主人的 Wonton 私聊（房里没这封信）"; return 1; }
	echo "测试信已进主人的 Wonton 私聊（qBittorrent：…，收件人 $to）"
)
