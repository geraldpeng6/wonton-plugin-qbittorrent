# scripts/smoke.sh source 本文件，不单独执行。
# shellcheck shell=bash
# qBittorrent：sso=proxy；qBittorrent 不提供用户身份接口，主人身份由云吞网关认证。
export IDENTITY_NA=1
export SMOKE_NOTE="qBittorrent 是单用户 WebUI；应用侧没有可断言的用户身份接口，免登录由网关来源地址白名单保证。"

qbit_session() (
  # 会话有效就直接用；失效时用核心登录变量重建。qBittorrent 不认 Remote-User，免登录靠网关来源白名单。
  set -u
  local web jar
  web="${E2E_WEB_URL:-${SMOKE_WEB_URL:?SMOKE_WEB_URL 未导出}}"
  web="${web%/}"   # 套件导出的 web_url 带尾斜杠，拼出来会得到 //api/v2/...，qBittorrent 回 404
  jar="${E2E_JAR:-${SMOKE_JAR:?SMOKE_JAR 未导出}}"
  curl -fsS --noproxy '*' -b "$jar" "$web/api/v2/app/version" >/dev/null 2>&1 && return 0
  local token base
  token="${E2E_TOKEN:-${SMOKE_TOKEN:-}}"
  base="${E2E_BASE:-${SMOKE_BASE:-}}"
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
  web="${E2E_WEB_URL:-${SMOKE_WEB_URL:?SMOKE_WEB_URL 未导出}}"
  web="${web%/}"   # 套件导出的 web_url 带尾斜杠，拼出来会得到 //api/v2/...，qBittorrent 回 404
  jar="${E2E_JAR:-${SMOKE_JAR:?SMOKE_JAR 未导出}}"
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
  web="${E2E_WEB_URL:-${SMOKE_WEB_URL:?SMOKE_WEB_URL 未导出}}"
  web="${web%/}"   # 套件导出的 web_url 带尾斜杠，拼出来会得到 //api/v2/...，qBittorrent 回 404
  jar="${E2E_JAR:-${SMOKE_JAR:?SMOKE_JAR 未导出}}"
  qbit_session || return 1
  cats="$(curl -sS --noproxy '*' --fail-with-body -b "$jar" "$web/api/v2/torrents/categories")" || {
    echo "读分类失败：${cats:-（空响应）}"; return 1; }
  jq -e 'has("wonton-smoke")' <<<"$cats" >/dev/null || {
    echo "升级/重装后找不到 wonton-smoke 分类：$(head -c 200 <<<"$cats")"; return 1; }
  echo "wonton-smoke 分类还在：升级/重装保住了数据"
)

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
  grep -qi 'VueTorrent' || return 1
  qbit_acceptance
}

# ---------- 通知邮件（notify，规范 0.11）----------
qbit_core() { # 核心容器：通知房记录、Matrix 令牌和 Tuwunel 都在它的数据目录/网络上
	docker ps --format '{{.Names}}' | grep -xE "wonton-${SMOKE_INSTANCE:-}--core" | head -1
}

qbit_dd() { # 核心数据目录（e2e 冒烟有 read_env；dev.sh probes 用 probes_setting）
	if declare -F read_env >/dev/null; then read_env WONTON_DATA_DIR; else probes_setting WONTON_DATA_DIR; fi
}

qbit_room_query() { # 用主人令牌读「Wonton」通知房最近消息（信被核心投进私聊的最终证据）。
	# 主人令牌照核心自己的做法：管理令牌走 Tuwunel 的 impersonation 登录；都在核心容器里拿。
	local core dd room admin srv otok
	core="$(qbit_core)" || return 1
	dd="$(qbit_dd)"
	room="$(docker exec "$core" cat "$dd/core/matrix-notice-room")" ||
		{ echo "读不到通知房记录（$dd/core/matrix-notice-room）"; return 1; }
	admin="$(docker exec "$core" cat "$dd/core/matrix-admin-token")" ||
		{ echo "读不到 Matrix 管理令牌"; return 1; }
	srv="$(docker exec "$core" cat "$dd/../secrets/matrix-server-name")" ||
		{ echo "读不到 Matrix 服务器名"; return 1; }
	otok="$(docker run --rm --network "container:$core" -e HTTP_PROXY= -e HTTPS_PROXY= -e http_proxy= -e https_proxy= -e NO_PROXY='*' \
		curlimages/curl:8.23.0 -sS -H "Authorization: Bearer $admin" -H 'Content-Type: application/json' -d '{}' \
		"http://tuwunel.wonton.internal:8008/_synapse/admin/v1/users/@owner:$srv/login" | jq -er .access_token)" ||
		{ echo "拿不到主人的 Matrix 令牌"; return 1; }
	docker run --rm --network "container:$core" -e HTTP_PROXY= -e HTTPS_PROXY= -e http_proxy= -e https_proxy= -e NO_PROXY='*' \
		curlimages/curl:8.23.0 -sS -H "Authorization: Bearer $otok" \
		"http://tuwunel.wonton.internal:8008/_matrix/client/v3/rooms/$room/messages?dir=b&limit=20"
}

qbit_room_newest_ts() { # <前缀>：通知房里该插件最近一条邮件消息的 origin_server_ts（没有则 0）
	local out
	out="$(qbit_room_query)" || { echo 0; return 0; }
	jq -r --arg p "$1" '[.chunk[]? | select(.type == "m.room.message" and (.content.body | startswith($p))) | .origin_server_ts] | max // 0' <<<"$out" 2>/dev/null || echo 0
}

qbit_room_wait() { # <前缀> <标记> <起始 ts> [次数=40]：等通知房里出现这条插件发的新邮件消息（投进私聊后一直都在）
	local prefix="$1" marker="$2" since="$3" n="${4:-40}" i out hits
	for ((i = 0; i < n; i++)); do
		out="$(qbit_room_query)" || { sleep 2; continue; }
		hits="$(jq -r --arg p "$prefix" --arg m "$marker" --argjson s "$since" '
			[.chunk[]? | select(.type == "m.room.message" and (.content.body | startswith($p)) and .origin_server_ts > $s)
			 | select($m == "" or (.content.body | contains($m)))] | length' <<<"$out" 2>/dev/null || echo 0)"
		[[ "${hits:-0}" -ge 1 ]] && return 0
		sleep 2
	done
	return 1
}

extra_check() (
	# 发信端到端：应用自己的「发送测试邮件」接口真发一封（收件人是 init 写进配置的主人内部邮箱），
	# 核心投进主人私聊后从 Mailpit 取走删除
	set -u
	local web jar resp to out
	web="${E2E_WEB_URL:-${SMOKE_WEB_URL:?SMOKE_WEB_URL 未导出}}"
	web="${web%/}"
	jar="${E2E_JAR:-${SMOKE_JAR:?SMOKE_JAR 未导出}}"
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
	# 记下触发前该插件最近一封邮件消息的时间，之后只认更新的。
	before="$(qbit_room_newest_ts "qBittorrent：")"
	# 触发一封真实测试信。
	code="$(curl -sS --noproxy '*' -b "$jar" -o /dev/null -w '%{http_code}' -X POST "$web/api/v2/app/sendTestEmail")"
	[ "$code" = 200 ] || { echo "sendTestEmail HTTP $code"; return 1; }
	# 核心把信投进主人的「Wonton」私聊：房里出现这一封。
	qbit_room_wait "qBittorrent：" "" "$before" 40 ||
		{ echo "测试信 80 秒没出现在主人的 Wonton 私聊：$(qbit_room_query | head -c 300)"; return 1; }
	echo "测试信已进主人的 Wonton 私聊（qBittorrent：…，收件人 $to）"
)
