#!/usr/bin/env bash
#
# REALITY 一键安装与管理
# 只做一件事：VLESS + XTLS-Vision + REALITY（Xray-core）
# 支持 Debian 11+ / Ubuntu 20.04+，x86_64 / ARM64
#
#   安装：bash <(curl -fsSL https://raw.githubusercontent.com/Frank683456/reality-script/main/install.sh)
#   管理：reality
#
# 安全约定（每条都对应一次真实踩坑）：
#   · 只动自己装的东西：/opt/reality、reality.service、/usr/local/bin/reality
#   · 不 kill、不停任何不是自己的进程和服务
#   · 改配置先过 xray -test；重启后起不来自动换回上一份
#   · Xray 只从官方 GitHub 下载，SHA256 对不上就不装
#   · 不记访问日志

SCRIPT_VERSION="1.0.2"
REPO="Frank683456/reality-script"
RAW_URL="https://raw.githubusercontent.com/${REPO}/main/install.sh"
XRAY_REPO="XTLS/Xray-core"

BASE=/opt/reality
BIN=$BASE/xray
CONF=$BASE/config.json
STATE=$BASE/state.json
TRAFFIC=$BASE/traffic.json
CMD=/usr/local/bin/reality
SVC=reality
RUN_USER=reality
UNIT=/etc/systemd/system/reality.service
TUNIT_SVC=/etc/systemd/system/reality-traffic.service
TUNIT_TIMER=/etc/systemd/system/reality-traffic.timer
SYSCTL_FILE=/etc/sysctl.d/99-reality-bbr.conf
FW_TAG=reality-script

# 伪装网站候选（安装时逐个实测，挑合格里握手最快的）。
# Xray 官方提醒：别用带 apple / icloud / microsoft 的，也别用 .cn .ru .ir（容易被封）。
SNI_GLOBAL=(www.cisco.com addons.mozilla.org www.mozilla.org www.samsung.com www.tesla.com
	www.lovelive-anime.jp www.nvidia.com www.intel.com www.oracle.com www.ibm.com
	www.dell.com www.hp.com www.logitech.com www.sony.com dl.google.com www.python.org)
# 国内机器只用境外共享 CDN 上的站（国内有节点的大站一眼就露馅）
SNI_CN=(www.cisco.com addons.mozilla.org www.lovelive-anime.jp www.python.org)
# 不许通过梯子访问服务器本机和内网
PRIVATE_NETS='["127.0.0.0/8","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","100.64.0.0/10","::1/128","fc00::/7","fe80::/10"]'

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
umask 022
LOG=/dev/null

# ───────────────────────────── 基础工具 ─────────────────────────────

set_locale() {
	local l
	for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
		if locale -a 2>/dev/null | grep -qx "$l"; then
			export LC_ALL=$l
			return
		fi
	done
}

init_colors() {
	if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
		RED=$'\e[31m' GRN=$'\e[32m' YEL=$'\e[33m' CYN=$'\e[36m' DIM=$'\e[2m' BLD=$'\e[1m' RST=$'\e[0m'
	else
		RED='' GRN='' YEL='' CYN='' DIM='' BLD='' RST=''
	fi
}

info() { printf '  %s\n' "$*"; }
good() { printf '  %s✓%s %s\n' "$GRN" "$RST" "$*"; }
note() { printf '  %s!%s %s\n' "$YEL" "$RST" "$*"; }
bad() { printf '  %s✗%s %s\n' "$RED" "$RST" "$*" >&2; }
die() {
	bad "$*"
	exit 1
}

# 重复字符
rep() {
	local s=$1 n=$2 out
	((n > 0)) || return 0
	printf -v out '%*s' "$n" ''
	printf '%s' "${out// /$s}"
}

# 去掉颜色码
plain() { printf '%s' "$1" | sed $'s/\e\\[[0-9;]*m//g'; }

# 终端显示宽度（中文算 2 格）
dw() {
	local s i ch cp w=0
	s=$(plain "$1")
	for ((i = 0; i < ${#s}; i++)); do
		ch=${s:i:1}
		printf -v cp '%d' "'$ch"
		if ((cp < 0x1100 || (cp >= 0x2000 && cp < 0x2E80) || (cp >= 0xFF61 && cp <= 0xFFDC))); then
			w=$((w + 1))
		else
			w=$((w + 2))
		fi
	done
	printf '%d' "$w"
}

# 按显示宽度右侧补空格
pad() {
	local w
	w=$(dw "$1")
	printf '%s' "$1"
	rep ' ' $(($2 - w))
}

# 圆角框：box 标题 右侧小字 行...
box() {
	local title=$1 right=$2 l lw w=44 gap
	shift 2
	for l in "$@"; do
		lw=$(dw "$l")
		((lw + 4 > w)) && w=$((lw + 4))
	done
	gap=$((w - 4 - $(dw "$title") - $(dw "$right")))
	((gap < 1)) && {
		w=$((w + 1 - gap))
		gap=1
	}
	printf '  %s╭%s╮%s\n' "$DIM" "$(rep ─ "$w")" "$RST"
	printf '  %s│%s  %s%s%s%s%s%s%s  %s│%s\n' "$DIM" "$RST" "$BLD" "$title" "$RST" "$(rep ' ' "$gap")" "$DIM" "$right" "$RST" "$DIM" "$RST"
	printf '  %s├%s┤%s\n' "$DIM" "$(rep ─ "$w")" "$RST"
	for l in "$@"; do
		printf '  %s│%s  %s%s  %s│%s\n' "$DIM" "$RST" "$l" "$(rep ' ' $((w - 4 - $(dw "$l"))))" "$DIM" "$RST"
	done
	printf '  %s╰%s╯%s\n' "$DIM" "$(rep ─ "$w")" "$RST"
}

item() {
	printf '    %s%s%s  %s' "$CYN" "$1" "$RST" "$(pad "$2" 20)"
	[[ -n ${3:-} ]] && printf '%s%s%s' "$DIM" "$3" "$RST"
	echo
}

line() { printf '  %s%s%s\n' "$DIM" "$(rep ─ "${1:-46}")" "$RST"; }

# 读用户输入：一律从终端读（兼容 curl | bash）
ask() {
	local p=$1 d=${2-}
	REPLY=''
	if ! { read -r -p "$p" REPLY </dev/tty; } 2>/dev/null; then
		REPLY=$d
		echo
	fi
	[[ -z $REPLY ]] && REPLY=$d
	return 0
}
confirm() {
	[[ -n ${ASSUME_YES:-} ]] && return 1
	ask "  $1 [y/N] " n
	[[ $REPLY == [Yy]* ]]
}
confirm_yes() {
	[[ -n ${ASSUME_YES:-} ]] && return 0
	ask "  $1 [Y/n] " y
	[[ $REPLY != [Nn]* ]]
}
pause() { ask "  ${DIM}按回车返回${RST}" ''; }

# 字节 → 好读的单位
hb() {
	awk -v b="${1:-0}" 'BEGIN { split("B KB MB GB TB", u, " "); i = 1
		while (b >= 1024 && i < 5) { b /= 1024; i++ }
		if (i == 1) printf "%d B", b; else printf "%.1f %s", b, u[i] }'
}

# 版本比较：a 比 b 新？
newer() { [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1) == "$1" ]]; }

# ───────────────────────────── 状态读写 ─────────────────────────────

st_get() { jq -r --arg k "$1" '.[$k] // empty | if type == "array" or type == "object" then tojson else tostring end' "$STATE" 2>/dev/null; }
st_set() {
	jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$STATE" >"$STATE.tmp" && mv -f "$STATE.tmp" "$STATE" && chmod 600 "$STATE"
}
st_setj() {
	jq --arg k "$1" --argjson v "$2" '.[$k] = $v' "$STATE" >"$STATE.tmp" && mv -f "$STATE.tmp" "$STATE" && chmod 600 "$STATE"
}

load() {
	local s
	s=$(jq -r '.inbounds[0] | @sh "PORT=\(.port) SNI=\(.streamSettings.realitySettings.serverNames[0]) SID=\(.streamSettings.realitySettings.shortIds[0])"' "$CONF") || die "配置文件读不出来：$CONF"
	eval "$s"
	PBK=$(st_get pbk) ADDR=$(st_get addr) LABEL=$(st_get label) FW=$(st_get fw) VENDOR=$(st_get vendor)
}

users() { jq -r '.inbounds[0].settings.clients[].email' "$CONF"; }
user_count() { jq '.inbounds[0].settings.clients | length' "$CONF"; }

# ───────────────────────────── 系统检测 ─────────────────────────────

detect_os() {
	[[ -r /etc/os-release ]] || die "认不出这台的系统（没有 /etc/os-release）"
	local id ver like
	# shellcheck disable=SC1091
	id=$(. /etc/os-release && echo "${ID:-}")
	# shellcheck disable=SC1091
	ver=$(. /etc/os-release && echo "${VERSION_ID:-}")
	# shellcheck disable=SC1091
	like=$(. /etc/os-release && echo "${ID_LIKE:-}")
	# shellcheck disable=SC1091
	OS_NAME=$(. /etc/os-release && echo "${PRETTY_NAME:-$id}")
	case $id in
	ubuntu) ((${ver%%.*} >= 20)) || die "Ubuntu $ver 太旧了，要 20.04 或更新" ;;
	debian) [[ -z $ver ]] || ((${ver%%.*} >= 11)) || die "Debian $ver 太旧了，要 11 或更新" ;;
	*)
		[[ " $like " == *" debian "* || " $like " == *" ubuntu "* ]] || die "只支持 Debian / Ubuntu，这台是 $OS_NAME"
		;;
	esac
	case $(uname -m) in
	x86_64 | amd64) ARCH=x86_64 XRAY_ASSET=Xray-linux-64.zip ;;
	aarch64 | arm64) ARCH=ARM64 XRAY_ASSET=Xray-linux-arm64-v8a.zip ;;
	*) die "不支持这种 CPU：$(uname -m)（只支持 x86_64 和 ARM64）" ;;
	esac
	VIRT=$(systemd-detect-virt 2>/dev/null) || VIRT=none
}

detect_vendor() {
	local v
	v=$(cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/chassis_asset_tag /sys/class/dmi/id/product_name 2>/dev/null | tr '\n' ' ')
	case $v in
	*OracleCloud*) echo "甲骨文云" ;;
	*Alibaba*) echo "阿里云" ;;
	*Tencent*) echo "腾讯云" ;;
	*Amazon*) echo "AWS" ;;
	*Google*) echo "谷歌云" ;;
	*Huawei* | *HUAWEI*) echo "华为云" ;;
	*7783-7084-3265-9085-8269-3286-77*) echo "Azure" ;;
	esac
}

# 公网地址 + 机房国家
detect_net() {
	local t=''
	t=$(curl -4 -fsS --max-time 6 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null) ||
		t=$(curl -6 -fsS --max-time 6 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null) || t=''
	ADDR=$(sed -n 's/^ip=//p' <<<"$t")
	LOC=$(sed -n 's/^loc=//p' <<<"$t")
	[[ -n $ADDR ]] || ADDR=$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null) || ADDR=''
	if [[ -z $LOC ]] && [[ $(timedatectl show -p Timezone --value 2>/dev/null; cat /etc/timezone 2>/dev/null) == *Asia/Shanghai* ]]; then
		LOC=CN
	fi
	LOC=${LOC:-XX}
}

# 机器上已有的其他梯子
other_proxy() {
	local found=()
	[[ -d /etc/v2ray-agent ]] && found+=("mack-a 八合一脚本")
	pgrep -x xray >/dev/null 2>&1 && [[ ! -d /etc/v2ray-agent ]] && found+=("Xray")
	pgrep -x 'v2ray|sing-box|hysteria' >/dev/null 2>&1 && found+=("V2Ray / sing-box / Hysteria")
	local IFS='、'
	printf '%s' "${found[*]}"
}

need_root() { [[ $EUID -eq 0 ]] || die "要用 root 运行（先执行 sudo -i 再跑）"; }
need_systemd() { [[ -d /run/systemd/system ]] || die "这台没在用 systemd（可能是很老的 OpenVZ 容器），装不了"; }

# 缺什么装什么，绝不升级系统里已有的包
ensure_deps() {
	local need=()
	command -v curl >/dev/null 2>&1 || need+=(curl)
	[[ -s /etc/ssl/certs/ca-certificates.crt ]] || need+=(ca-certificates)
	command -v unzip >/dev/null 2>&1 || need+=(unzip)
	command -v jq >/dev/null 2>&1 || need+=(jq)
	command -v qrencode >/dev/null 2>&1 || need+=(qrencode)
	command -v ss >/dev/null 2>&1 || need+=(iproute2)
	command -v pgrep >/dev/null 2>&1 || need+=(procps)
	PKGS_ADDED=''
	((${#need[@]})) || return 0
	export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
	# 刚开的机器常有自动更新占着 apt，等它最多 5 分钟
	apt-get -o DPkg::Lock::Timeout=300 update >>"$LOG" 2>&1 || true
	apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends "${need[@]}" >>"$LOG" 2>&1 || return 1
	PKGS_ADDED="${need[*]}"
}

# ───────────────────────────── 端口 ─────────────────────────────

port_busy() {
	local p=$1
	ss -Hltn "sport = :$p" 2>/dev/null | grep -q . && return 0
	# Docker 直接转发（不经代理进程）时 ss 看不到，单独查一下
	iptables -t nat -S 2>/dev/null | grep -q -- "--dport $p -j DNAT" && return 0
	return 1
}

# 优先 443（Xray 官方建议），被占就随机挑高位端口
pick_port() {
	port_busy 443 || {
		echo 443
		return 0
	}
	local p i
	for i in $(seq 1 100); do
		p=$((RANDOM % 40000 + 20000))
		port_busy "$p" || {
			echo "$p"
			return 0
		}
	done
	return 1
}

pick_local_port() {
	local p i
	for i in $(seq 1 100); do
		p=$((RANDOM % 10000 + 10000))
		ss -Hltn "sport = :$p" 2>/dev/null | grep -q . || {
			echo "$p"
			return 0
		}
	done
	return 1
}

listening_xray() { ss -Hltnp "sport = :$1" 2>/dev/null | grep -q '"xray"'; }

# ───────────────────────────── Xray 下载 ─────────────────────────────

xray_latest() {
	local u
	u=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --max-time "${1:-15}" "https://github.com/$XRAY_REPO/releases/latest" 2>/dev/null) || return 1
	u=${u##*/}
	[[ $u =~ ^v[0-9]+(\.[0-9]+)+$ ]] || return 1
	printf '%s' "$u"
}

xver() { "${1:-$BIN}" version 2>/dev/null | awk 'NR == 1 { print $2 }'; }

# fetch_xray 版本 目录 → 目录/xray（校验过的）
fetch_xray() {
	local tag=$1 dir=$2 url want got
	FETCH_ERR=''
	[[ -n ${XRAY_ASSET:-} ]] || detect_os
	if [[ -n ${OFFLINE_DIR:-} ]]; then
		if ! { cp "$OFFLINE_DIR/$XRAY_ASSET" "$dir/x.zip" && cp "$OFFLINE_DIR/$XRAY_ASSET.dgst" "$dir/x.dgst"; } 2>>"$LOG"; then
			FETCH_ERR="离线目录里没找到 $XRAY_ASSET 和 $XRAY_ASSET.dgst"
			return 1
		fi
	else
		url="https://github.com/$XRAY_REPO/releases/download/$tag/$XRAY_ASSET"
		if ! { curl -fsSL --retry 2 --connect-timeout 10 --max-time 300 -o "$dir/x.zip" "$url" &&
			curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 -o "$dir/x.dgst" "$url.dgst"; } 2>>"$LOG"; then
			FETCH_ERR="从 GitHub 下载 Xray $tag 失败（版本号不对，或这台连不上 GitHub）"
			return 1
		fi
	fi
	want=$(awk -F'= *' '$1 == "SHA2-256" { print $2 }' "$dir/x.dgst" | tr -d '[:space:]')
	got=$(sha256sum "$dir/x.zip" | awk '{ print $1 }')
	[[ ${#want} -eq 64 && $want == "$got" ]] || {
		FETCH_ERR="校验码对不上（文件可能被篡改或没下完整），没装"
		return 1
	}
	if ! unzip -o -q "$dir/x.zip" xray -d "$dir" 2>>"$LOG"; then
		FETCH_ERR="解压失败"
		return 1
	fi
	chmod 755 "$dir/xray"
	"$dir/xray" version >/dev/null 2>&1 || {
		FETCH_ERR="下载的 Xray 在这台跑不起来"
		return 1
	}
	rm -f "$dir/x.zip" "$dir/x.dgst"
}

# ───────────────────────────── 伪装网站 ─────────────────────────────

sni_bad_name() {
	local s=${1,,}
	[[ $s == *.cn || $s == *.ru || $s == *.ir || $s == *apple* || $s == *icloud* || $s == *microsoft* ]]
}

# TLS 1.3 + 抗量子密钥交换（X25519MLKEM768），用 Xray 自带的检测
sni_tls_ok() {
	local out sec
	out=$(timeout 15 "$2" tls ping "$1" 2>&1) || return 1
	sec=${out#*Pinging with SNI}
	[[ $sec != "$out" ]] || return 1
	grep -q 'Handshake succeeded' <<<"$sec" && grep -q 'TLS 1.3' <<<"$sec" && grep -q 'X25519MLKEM768' <<<"$sec"
}

# 支持 h2、不走 Cloudflare → 打印握手毫秒数
sni_web_ms() {
	local r l hv tc ta
	r=$(curl -sS -o /dev/null -D - --http2 --connect-timeout 5 --max-time 8 \
		-w 'XX %{http_version} %{time_connect} %{time_appconnect}\n' "https://$1/" 2>/dev/null) || return 1
	grep -qi '^server: *cloudflare' <<<"$r" && return 1
	l=$(grep '^XX ' <<<"$r") || return 1
	read -r _ hv tc ta <<<"$l"
	[[ $hv == 2 ]] || return 1
	awk -v a="$ta" -v c="$tc" 'BEGIN { printf "%d", (a - c) * 1000 + 0.5 }'
}

sni_check() { sni_tls_ok "$1" "$2" && sni_web_ms "$1"; }

# pick_sni xray → "域名 毫秒"
pick_sni() {
	local x=$1 tmp d ms best='' bestms=999999 list
	if [[ ${LOC:-} == CN ]]; then list=("${SNI_CN[@]}"); else list=("${SNI_GLOBAL[@]}"); fi
	tmp=$(mktemp -d)
	for d in "${list[@]}"; do
		(sni_tls_ok "$d" "$x" && : >"$tmp/$d") &
	done
	wait
	for d in "${list[@]}"; do
		[[ -e $tmp/$d ]] || continue
		ms=$(sni_web_ms "$d") || continue
		((ms < bestms)) && {
			bestms=$ms
			best=$d
		}
	done
	rm -rf "$tmp"
	[[ -n $best ]] && printf '%s %s' "$best" "$bestms"
}

# ───────────────────────────── 配置 ─────────────────────────────

gen_keys() {
	local k
	k=$("$1" x25519 2>/dev/null) || return 1
	PRIV=$(sed -n -e 's/^PrivateKey: *//p' -e 's/^Private key: *//p' <<<"$k" | head -n1)
	PBK=$(sed -n -e 's/^Password (PublicKey): *//p' -e 's/^Password: *//p' -e 's/^PublicKey: *//p' -e 's/^Public key: *//p' <<<"$k" | head -n1)
	[[ -n $PRIV && -n $PBK ]]
}

new_sid() { head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# build_config 端口 伪装 私钥 shortId 统计口 客户端JSON
build_config() {
	jq -n --argjson port "$1" --arg sni "$2" --arg pk "$3" --arg sid "$4" --argjson api "$5" \
		--argjson clients "$6" --argjson priv "$PRIVATE_NETS" '{
	log: { loglevel: "warning", access: "none" },
	api: { tag: "api", listen: ("127.0.0.1:" + ($api | tostring)), services: ["StatsService"] },
	stats: {},
	policy: { levels: { "0": { statsUserUplink: true, statsUserDownlink: true } } },
	inbounds: [{
		tag: "reality-in", port: $port, protocol: "vless",
		settings: { clients: $clients, decryption: "none" },
		streamSettings: {
			network: "raw", security: "reality",
			realitySettings: {
				target: ($sni + ":443"), serverNames: [$sni], privateKey: $pk,
				shortIds: [$sid], minClientVer: "1.8.0"
			}
		},
		sniffing: { enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true }
	}],
	outbounds: [{ tag: "direct", protocol: "freedom" }, { tag: "block", protocol: "blackhole" }],
	routing: { rules: [{ ip: $priv, outboundTag: "block" }] }
}'
}

valid_name() { [[ $1 =~ ^[[:alnum:]_.-]{1,20}$ ]]; }

# 新配置：先验 → 换上 → 重启 → 起不来就自动换回
apply_conf() {
	local new=$1
	if ! "$BIN" run -test -config "$new" >>"$LOG" 2>&1; then
		rm -f "$new"
		bad "新配置没通过 Xray 检查，没生效（原来的照常跑）"
		return 1
	fi
	collect_traffic
	cp -p "$CONF" "$BASE/config.prev.json"
	install -m 640 -o root -g "$RUN_USER" "$new" "$CONF"
	rm -f "$new"
	load
	if svc_restart && selftest; then
		return 0
	fi
	bad "新配置启动后自检没通过，已自动换回上一份"
	install -m 640 -o root -g "$RUN_USER" "$BASE/config.prev.json" "$CONF"
	svc_restart
	load
	return 1
}

# ───────────────────────────── 服务 ─────────────────────────────

svc_wait() {
	local i p
	p=$(jq -r '.inbounds[0].port' "$CONF")
	for i in $(seq 1 20); do
		systemctl is-active --quiet "$SVC" && listening_xray "$p" && return 0
		sleep 0.5
	done
	return 1
}

svc_restart() {
	systemctl reset-failed "$SVC" >/dev/null 2>&1
	systemctl restart "$SVC" >>"$LOG" 2>&1
	svc_wait
}

uptime_txt() {
	local ts s d
	ts=$(systemctl show "$SVC" -p ActiveEnterTimestamp --value 2>/dev/null)
	s=$(date -d "$ts" +%s 2>/dev/null) || return 0
	d=$(($(date +%s) - s))
	if ((d >= 86400)); then
		printf '已连续运行 %d 天' $((d / 86400))
	elif ((d >= 3600)); then
		printf '已连续运行 %d 小时' $((d / 3600))
	else
		printf '已连续运行 %d 分钟' $((d / 60))
	fi
}

write_file_if_changed() { # 内容从 stdin 来；变了返回 0
	local f=$1 tmp
	tmp=$(mktemp)
	cat >"$tmp"
	if [[ -f $f ]] && cmp -s "$tmp" "$f"; then
		rm -f "$tmp"
		return 1
	fi
	install -m 644 "$tmp" "$f"
	rm -f "$tmp"
	return 0
}

write_units() {
	local changed=1
	write_file_if_changed "$UNIT" <<EOF && changed=0
[Unit]
Description=REALITY proxy (Xray) - managed by reality-script
Documentation=https://github.com/$REPO
After=network-online.target
Wants=network-online.target
# 菜单里连续改配置会连续重启，别让 systemd 的「10 秒 5 次」限流把服务卡死
StartLimitIntervalSec=0

[Service]
Type=simple
User=$RUN_USER
Group=$RUN_USER
ExecStartPre=-+$CMD _fw_up
ExecStart=$BIN run -config $CONF
ExecStopPost=-+$CMD _fw_down
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF
	write_file_if_changed "$TUNIT_SVC" <<EOF && changed=0
[Unit]
Description=REALITY traffic counter

[Service]
Type=oneshot
ExecStart=$CMD _collect
EOF
	write_file_if_changed "$TUNIT_TIMER" <<EOF && changed=0
[Unit]
Description=REALITY traffic counter (hourly)

[Timer]
OnCalendar=hourly
RandomizedDelaySec=120
Persistent=true

[Install]
WantedBy=timers.target
EOF
	systemctl daemon-reload
	return $changed
}

# ───────────────────────────── 防火墙 ─────────────────────────────

fw_detect() {
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
		echo ufw
	elif systemctl is-active --quiet firewalld 2>/dev/null; then
		echo firewalld
	elif command -v iptables >/dev/null 2>&1 && iptables -S 2>/dev/null | grep -q '1PANEL_'; then
		echo 1panel
	elif command -v iptables >/dev/null 2>&1 && iptables -S INPUT 2>/dev/null | grep -Eq '^-P INPUT (DROP|REJECT)|-j (DROP|REJECT)'; then
		echo iptables
	elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -Eq 'hook input .*policy drop'; then
		echo nft
	else
		echo none
	fi
}

fw_label() {
	case $1 in
	ufw) echo "ufw" ;;
	firewalld) echo "firewalld" ;;
	iptables) echo "iptables，随服务自动加删" ;;
	none) echo "没开防火墙，不用放行" ;;
	*) echo "$1" ;;
	esac
}

# ufw / firewalld：只记自己加的端口，卸载时只删自己加的
fw_open_port() {
	local p=$1
	case $FW in
	ufw)
		ufw status 2>/dev/null | grep -Eq "^$p(/tcp)?[[:space:]]" && return 0
		ufw allow "$p/tcp" comment "$FW_TAG" >>"$LOG" 2>&1 || return 1
		;;
	firewalld)
		firewall-cmd --permanent --query-port="$p/tcp" >/dev/null 2>&1 && return 0
		{ firewall-cmd --permanent --add-port="$p/tcp" && firewall-cmd --reload; } >>"$LOG" 2>&1 || return 1
		;;
	*) return 0 ;;
	esac
	st_setj fw_ours "$(jq -c --argjson p "$p" '((.fw_ours // []) + [$p]) | unique' "$STATE")"
}

fw_close_port() {
	local p=$1
	jq -e --argjson p "$p" '(.fw_ours // []) | index($p) != null' "$STATE" >/dev/null 2>&1 || return 0
	case $FW in
	ufw) ufw --force delete allow "$p/tcp" >>"$LOG" 2>&1 ;;
	firewalld) { firewall-cmd --permanent --remove-port="$p/tcp" && firewall-cmd --reload; } >>"$LOG" 2>&1 ;;
	esac
	st_setj fw_ours "$(jq -c --argjson p "$p" '(.fw_ours // []) - [$p]' "$STATE")"
}

# iptables 模式：服务启动时加一条带标记的放行，停止时删（只动带标记的那条）
fw_hook() {
	[[ -f $STATE && -f $CONF ]] || return 0
	# 加只在 iptables 模式；删不看模式——带本脚本标记的规则一定是自己加的
	[[ $1 == down || $(st_get fw) == iptables ]] || return 0
	local t p rule args
	p=$(jq -r '.inbounds[0].port' "$CONF")
	for t in iptables ip6tables; do
		command -v "$t" >/dev/null 2>&1 || continue
		while read -r rule; do
			[[ -n $rule ]] || continue
			read -ra args <<<"${rule#-A }"
			"$t" -D "${args[@]}" 2>/dev/null
		done < <("$t" -S INPUT 2>/dev/null | grep -- "--comment $FW_TAG")
		[[ $1 == up ]] && "$t" -I INPUT 1 -p tcp --dport "$p" -m comment --comment "$FW_TAG" -j ACCEPT 2>/dev/null
	done
	return 0
}

fw_hints() {
	case $FW in
	1panel) note "这台的防火墙归 1Panel 管：到 1Panel 面板「主机 → 防火墙」放行 TCP $PORT，不然外面连不上" ;;
	nft) note "这台开着 nftables 防火墙（默认拒绝）：要自己放行 TCP $PORT" ;;
	esac
	[[ -n ${VENDOR:-} ]] && note "这台在${VENDOR}：还要去服务商控制台的「安全组 / 防火墙」放行 TCP $PORT"
	return 0
}

enable_bbr() {
	local cur
	BBR_ADDED=false
	cur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
	if [[ $cur == bbr* ]]; then
		BBR_TXT="BBR 本来就开着"
		return
	fi
	case $VIRT in openvz | lxc | lxc-libvirt | wsl)
		BBR_TXT="容器类主机改不了加速，跳过"
		return
		;;
	esac
	grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || modprobe tcp_bbr >/dev/null 2>&1
	if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
		BBR_TXT="内核不支持 BBR，跳过"
		return
	fi
	printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' >"$SYSCTL_FILE"
	if sysctl -p "$SYSCTL_FILE" >>"$LOG" 2>&1; then
		BBR_ADDED=true
		BBR_TXT="已开 BBR 加速"
	else
		rm -f "$SYSCTL_FILE"
		BBR_TXT="BBR 没开成，跳过"
	fi
}

# ───────────────────────────── 流量统计 ─────────────────────────────

# 把 Xray 计数器读出来累加到 traffic.json（按天、按人），读完清零
collect_traffic() {
	[[ -f $STATE && -x $BIN ]] || return 0
	systemctl is-active --quiet "$SVC" || return 0
	local api out
	api=$(st_get api_port)
	out=$(timeout 5 "$BIN" api statsquery --server="127.0.0.1:$api" -pattern 'user>>>' -reset 2>/dev/null) || return 0
	[[ -n $out ]] || return 0
	[[ -s $TRAFFIC ]] || echo '{}' >"$TRAFFIC"
	jq --arg d "$(date +%F)" --arg cut "$(date -d '-62 days' +%F)" --argjson s "$out" '
		reduce (($s.stat // [])[]) as $x (.;
			($x.name | split(">>>")) as $p
			| if ($p | length) == 4 and $p[0] == "user" and $p[2] == "traffic" then
				.[$d][$p[1]][(if $p[3] == "uplink" then 0 else 1 end)] += (($x.value // 0) | tonumber)
			else . end)
		| with_entries(select(.key >= $cut))' "$TRAFFIC" >"$TRAFFIC.tmp" && mv -f "$TRAFFIC.tmp" "$TRAFFIC"
	chmod 600 "$TRAFFIC"
}

# 每人：名字<TAB>今天字节<TAB>本月字节
traffic_table() {
	[[ -s $TRAFFIC ]] || echo '{}' >"$TRAFFIC"
	jq -r --arg d "$(date +%F)" --arg m "$(date +%Y-%m)" --slurpfile tf "$TRAFFIC" '
		($tf[0] // {}) as $t
		| .inbounds[0].settings.clients[].email as $u
		| [ $u,
			(($t[$d][$u] // [0, 0]) | map(. // 0) | add),
			([ $t | to_entries[] | select(.key | startswith($m)) | (.value[$u] // [0, 0]) | map(. // 0) | add ] | add // 0)
		] | @tsv' "$CONF"
}

traffic_today_total() {
	[[ -s $TRAFFIC ]] || {
		echo 0
		return
	}
	jq --arg d "$(date +%F)" '[(.[$d] // {})[] | map(. // 0) | add] | add // 0' "$TRAFFIC"
}

# ───────────────────────────── 自检 ─────────────────────────────

probe_url() {
	local u
	for u in https://www.gstatic.com/generate_204 https://www.cloudflare.com/cdn-cgi/trace https://www.baidu.com/; do
		curl -s -o /dev/null --max-time 5 "$u" && {
			echo "$u"
			return
		}
	done
	echo https://www.gstatic.com/generate_204
}

# 起一个临时客户端，真走一遍梯子
selftest() {
	local sp tmp id pid code url i
	id=$(jq -r '.inbounds[0].settings.clients[0].id' "$CONF")
	sp=$(pick_local_port) || return 1
	tmp=$(mktemp -d)
	jq -n --argjson sp "$sp" --argjson port "$PORT" --arg id "$id" --arg sni "$SNI" --arg pbk "$PBK" --arg sid "$SID" '{
		log: { loglevel: "none" },
		inbounds: [{ listen: "127.0.0.1", port: $sp, protocol: "socks", settings: { udp: false } }],
		outbounds: [{ protocol: "vless",
			settings: { vnext: [{ address: "127.0.0.1", port: $port,
				users: [{ id: $id, flow: "xtls-rprx-vision", encryption: "none" }] }] },
			streamSettings: { network: "raw", security: "reality",
				realitySettings: { serverName: $sni, fingerprint: "chrome", publicKey: $pbk, shortId: $sid } } }]
	}' >"$tmp/c.json"
	"$BIN" run -config "$tmp/c.json" >/dev/null 2>&1 &
	pid=$!
	for i in $(seq 1 20); do
		ss -Hltn "sport = :$sp" 2>/dev/null | grep -q . && break
		sleep 0.25
	done
	url=$(probe_url)
	code=000
	# 服务刚启动时第一次握手要等伪装网站，慢几秒，多试几次
	for i in 1 2 3 4; do
		code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 --socks5-hostname "127.0.0.1:$sp" "$url" 2>/dev/null)
		[[ $code != 000 ]] && break
		sleep 1
	done
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	rm -rf "$tmp"
	[[ $code != 000 ]]
}

# ───────────────────────────── 节点展示 ─────────────────────────────

host_for_link() { if [[ $ADDR == *:* ]]; then printf '[%s]' "$ADDR"; else printf '%s' "$ADDR"; fi; }

user_id() { jq -r --arg n "$1" '.inbounds[0].settings.clients[] | select(.email == $n) | .id' "$CONF"; }

user_link() {
	local id frag
	id=$(user_id "$1")
	frag=$(jq -rn --arg s "$LABEL-$1" '$s | @uri')
	printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s' \
		"$id" "$(host_for_link)" "$PORT" "$SNI" "$PBK" "$SID" "$frag"
}

clash_yaml() {
	cat <<EOF
- name: "$LABEL-$1"
  type: vless
  server: $ADDR
  port: $PORT
  uuid: $(user_id "$1")
  network: tcp
  udp: true
  tls: true
  flow: xtls-rprx-vision
  servername: $SNI
  client-fingerprint: chrome
  reality-opts:
    public-key: $PBK
    short-id: $SID
    support-x25519mlkem768: true
EOF
}

client_tips() {
	printf '  %s客户端提醒%s\n' "$BLD" "$RST"
	info "· 小火箭 / v2rayN / v2rayNG：扫二维码，或复制上面的链接导入"
	info "· Clash Verge / mihomo：用上面的配置，support-x25519mlkem768 那行别删"
	if ! newer 26.9.9 "$(xver)"; then
		info "· sing-box 系（Hiddify、NekoBox、sing-box App）暂时连不上新版 Xray"
	fi
}

show_node() {
	local n=$1 link
	link=$(user_link "$n")
	echo
	printf '  %s── %s 的节点 %s%s\n' "$BLD" "$n" "$(rep ─ 30)" "$RST"
	echo
	printf '  %s链接%s\n' "$BLD" "$RST"
	printf '  %s\n\n' "$link"
	if command -v qrencode >/dev/null 2>&1; then
		qrencode -t ansiutf8 -m 2 "$link" | sed 's/^/  /'
		echo
	fi
	printf '  %sClash / mihomo 配置%s %s（贴到 proxies: 下面）%s\n' "$BLD" "$RST" "$DIM" "$RST"
	clash_yaml "$n" | sed 's/^/  /'
	echo
	client_tips
}

# 选一个用户，名字打到 stdout（提示走终端）
choose_user() {
	local list=() i
	mapfile -t list < <(users)
	if ((${#list[@]} == 1)); then
		printf '%s' "${list[0]}"
		return 0
	fi
	echo >&2
	for i in "${!list[@]}"; do
		printf '    %s%d%s  %s\n' "$CYN" $((i + 1)) "$RST" "${list[i]}" >&2
	done
	echo >&2
	ask "  $1 [1-${#list[@]}]: " ''
	[[ $REPLY =~ ^[0-9]+$ ]] && ((REPLY >= 1 && REPLY <= ${#list[@]})) || return 1
	printf '%s' "${list[REPLY - 1]}"
}

view_node() {
	local n
	n=$(choose_user "看谁的节点") || return 0
	show_node "$n"
}

links_changed_note() { note "所有人的链接都变了，菜单 1 / 用户管理里重新发给大家"; }

# ───────────────────────────── 面板 ─────────────────────────────

latest_cached() {
	local f=$BASE/.latest tag ts
	if [[ -f $f ]]; then
		read -r tag ts <"$f"
		if [[ -n $ts ]] && (($(date +%s) - ts < 21600)); then
			printf '%s' "$tag"
			return
		fi
	fi
	tag=$(xray_latest 4) || tag=''
	[[ -n $tag ]] && echo "$tag $(date +%s)" >"$f"
	printf '%s' "$tag"
}

show_panel() {
	local st ver latest vtxt lines=()
	if systemctl is-active --quiet "$SVC"; then
		st="${GRN}运行中${RST}，$(uptime_txt)"
	else
		st="${RED}没在运行${RST}（菜单 5 可以启动）"
	fi
	ver=$(xver)
	latest=$(latest_cached)
	vtxt="Xray $ver"
	if [[ -n $latest ]]; then
		if [[ v$ver == "$latest" ]]; then
			vtxt+="${DIM}（最新）${RST}"
		elif newer "${latest#v}" "$ver"; then
			vtxt+="${YEL}（有新版 ${latest#v}）${RST}"
		fi
	fi
	lines+=("状态   $st")
	lines+=("内核   $vtxt")
	lines+=("端口   $(pad "$PORT" 10)伪装   $SNI")
	lines+=("用户   $(pad "$(user_count) 个" 10)今日   $(hb "$(traffic_today_total)")")
	case $FW in
	1panel) lines+=("${YEL}防火墙归 1Panel 管，要在面板放行 TCP $PORT${RST}") ;;
	nft) lines+=("${YEL}nftables 防火墙要手动放行 TCP $PORT${RST}") ;;
	esac
	box "REALITY 管理" "v$SCRIPT_VERSION" "${lines[@]}"
}

# ───────────────────────────── 菜单：用户 ─────────────────────────────

add_user() {
	local n new
	echo
	ask "  新用户的名字（中英文、数字都行，最多 20 个字）: " ''
	n=$REPLY
	[[ -n $n ]] || return 0
	valid_name "$n" || {
		bad "名字只能用中英文、数字和 _ . -，不能有空格"
		return 0
	}
	users | grep -qxF -- "$n" && {
		bad "已经有叫「$n」的用户了"
		return 0
	}
	new=$(mktemp --suffix=.json)
	jq --arg n "$n" --arg id "$("$BIN" uuid)" \
		'.inbounds[0].settings.clients += [{ id: $id, flow: "xtls-rprx-vision", email: $n }]' "$CONF" >"$new"
	apply_conf "$new" || return 0
	good "加好了「$n」"
	show_node "$n"
}

del_user() {
	local n new
	(($(user_count) > 1)) || {
		bad "只剩一个用户了，不能删（不想用了就卸载）"
		return 0
	}
	n=$(choose_user "删谁") || return 0
	confirm "确定删掉「$n」？他的链接会立刻失效" || return 0
	new=$(mktemp --suffix=.json)
	jq --arg n "$n" '.inbounds[0].settings.clients |= map(select(.email != $n))' "$CONF" >"$new"
	apply_conf "$new" || return 0
	[[ -s $TRAFFIC ]] && jq --arg n "$n" 'map_values(del(.[$n]))' "$TRAFFIC" >"$TRAFFIC.tmp" && mv -f "$TRAFFIC.tmp" "$TRAFFIC"
	good "已删掉「$n」，其他人不受影响"
}

users_menu() {
	local n t m
	while :; do
		[[ -t 1 ]] && clear
		load
		collect_traffic
		echo
		printf '  %s%s%s%s%s\n' "$BLD" "$(pad "用户（$(user_count) 个）" 24)" "$(pad "今天" 12)" "本月" "$RST"
		line 46
		while IFS=$'\t' read -r n t m; do
			printf '  %s%s%s\n' "$(pad "$n" 24)" "$(pad "$(hb "$t")" 12)" "$(hb "$m")"
		done < <(traffic_table)
		echo
		item 1 "加人"
		item 2 "删人"
		item 3 "看某人的节点"
		item 0 "返回"
		echo
		ask "  请选择: " ''
		case $REPLY in
		1) add_user && pause ;;
		2) del_user && pause ;;
		3) view_node && pause ;;
		*) return 0 ;;
		esac
	done
}

# ───────────────────────────── 菜单：端口 / 伪装 ─────────────────────────────

change_port() {
	local p old=$PORT new
	echo
	ask "  新端口（直接回车＝自动挑，优先 443）: " ''
	p=$REPLY
	if [[ -z $p ]]; then
		p=$(pick_port) || {
			bad "挑不到空闲端口"
			return 0
		}
	elif ! [[ $p =~ ^[0-9]+$ ]] || ((p < 1 || p > 65535)); then
		bad "端口要是 1-65535 之间的数字"
		return 0
	fi
	[[ $p == "$old" ]] && {
		info "跟现在一样，没改"
		return 0
	}
	port_busy "$p" && {
		bad "端口 $p 已经被别的程序占了"
		return 0
	}
	new=$(mktemp --suffix=.json)
	jq --argjson p "$p" '.inbounds[0].port = $p' "$CONF" >"$new"
	fw_open_port "$p"
	if apply_conf "$new"; then
		fw_close_port "$old"
		good "端口换成 $p 了"
		[[ $p != 443 ]] && note "Xray 官方建议用 443，别的端口更容易被盯上"
		fw_hints
		links_changed_note
	else
		fw_close_port "$p"
	fi
}

change_sni() {
	local d ms new r
	echo
	item 1 "自动重新挑一个"
	item 2 "自己输入"
	item 0 "返回"
	echo
	ask "  请选择: " ''
	case $REPLY in
	1)
		info "正在测候选网站，十几秒……"
		r=$(pick_sni "$BIN") || {
			bad "候选网站一个都不合格（可能这台访问外网有问题）"
			return 0
		}
		d=${r% *} ms=${r#* }
		;;
	2)
		ask "  伪装网站域名（例如 www.cisco.com）: " ''
		d=${REPLY,,}
		[[ $d =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || {
			bad "域名格式不对"
			return 0
		}
		if sni_bad_name "$d"; then
			note "Xray 官方不建议用带 apple / icloud / microsoft 或 .cn .ru .ir 的网站，更容易被封"
			confirm "还是要用 $d？" || return 0
		fi
		info "正在检测 $d ……"
		ms=$(sni_check "$d" "$BIN") || {
			bad "$d 不合格：要支持 TLS 1.3 + 抗量子密钥交换 + HTTP/2，而且不能走 Cloudflare"
			return 0
		}
		;;
	*) return 0 ;;
	esac
	[[ $d == "$SNI" ]] && {
		info "跟现在一样（$d），没改"
		return 0
	}
	new=$(mktemp --suffix=.json)
	jq --arg d "$d" '.inbounds[0].streamSettings.realitySettings |= (.target = ($d + ":443") | .serverNames = [$d])' "$CONF" >"$new"
	apply_conf "$new" || return 0
	good "伪装网站换成 $d 了（握手 ${ms}ms）"
	links_changed_note
}

change_label() {
	echo
	info "节点名显示成「前缀-用户名」，现在的前缀是：$LABEL"
	ask "  新前缀（最多 12 个字）: " ''
	[[ -n $REPLY ]] || return 0
	[[ $REPLY =~ ^[[:alnum:]_.-]{1,12}$ ]] || {
		bad "只能用中英文、数字和 _ . -"
		return 0
	}
	st_set label "$REPLY"
	LABEL=$REPLY
	good "前缀改成「$REPLY」了"
	links_changed_note
}

change_menu() {
	echo
	item 1 "换端口" "现在 $PORT"
	item 2 "换伪装网站" "现在 $SNI"
	item 3 "改节点名前缀" "现在 $LABEL"
	item 0 "返回"
	echo
	ask "  请选择: " ''
	case $REPLY in
	1) change_port ;;
	2) change_sni ;;
	3) change_label ;;
	*) return 0 ;;
	esac
	pause
}

# ───────────────────────────── 菜单：Xray 版本 ─────────────────────────────

core_warn() { # 跨过 26.9.9 往上升时提醒客户端
	local from=$1 to=$2
	if newer 26.9.9 "$from" && ! newer 26.9.9 "$to"; then
		note "提醒：Xray 26.9.9 起，服务端只认带抗量子密钥交换的客户端："
		info "  Clash / mihomo 要有 support-x25519mlkem768: true（本脚本给的配置都带了）"
		info "  sing-box 系（Hiddify、NekoBox）会连不上；老版本客户端要先升级"
	fi
}

switch_core() {
	local tag=$1 cur tmp
	cur=$(xver)
	[[ ${tag#v} == "$cur" ]] && {
		info "已经是 $cur 了"
		return 0
	}
	core_warn "$cur" "${tag#v}"
	confirm "把 Xray 从 $cur 换成 ${tag#v}？（换的时候断几秒）" || return 0
	tmp=$(mktemp -d)
	info "下载 Xray ${tag#v} 并核对官方校验码……"
	fetch_xray "$tag" "$tmp" || {
		bad "$FETCH_ERR"
		rm -rf "$tmp"
		return 0
	}
	"$tmp/xray" run -test -config "$CONF" >>"$LOG" 2>&1 || {
		bad "Xray ${tag#v} 不认现在的配置，没换"
		rm -rf "$tmp"
		return 0
	}
	collect_traffic
	cp -p "$BIN" "$BIN.prev"
	install -m 755 "$tmp/xray" "$BIN"
	rm -rf "$tmp"
	if svc_restart && selftest; then
		good "已换成 Xray ${tag#v}，自检通过（旧版 $cur 留着，可以一键回退）"
	else
		bad "换完自检没通过，已自动换回 $cur"
		install -m 755 "$BIN.prev" "$BIN"
		svc_restart
	fi
}

rollback_core() {
	local cur prev
	[[ -x $BIN.prev ]] || {
		bad "没有上一个版本可回退"
		return 0
	}
	cur=$(xver) prev=$(xver "$BIN.prev")
	confirm "把 Xray 从 $cur 换回 $prev？" || return 0
	collect_traffic
	mv -f "$BIN" "$BIN.swap" && mv -f "$BIN.prev" "$BIN" && mv -f "$BIN.swap" "$BIN.prev"
	if svc_restart && selftest; then
		good "已回退到 $prev（$cur 留着，可以再换回去）"
	else
		bad "回退后自检没通过，已换回 $cur"
		mv -f "$BIN" "$BIN.swap" && mv -f "$BIN.prev" "$BIN" && mv -f "$BIN.swap" "$BIN.prev"
		svc_restart
	fi
}

core_menu() {
	local cur latest prev
	cur=$(xver)
	info "正在查最新版……"
	latest=$(xray_latest 8) || latest=''
	[[ -n $latest ]] && echo "$latest $(date +%s)" >"$BASE/.latest"
	prev=''
	[[ -x $BIN.prev ]] && prev=$(xver "$BIN.prev")
	echo
	info "现在用的      Xray $cur"
	info "最新正式版    ${latest:+Xray ${latest#v}}${latest:-查不到（连不上 GitHub）}"
	[[ -n $prev ]] && info "上一个版本    Xray $prev（可回退）"
	echo
	item 1 "更新到最新正式版"
	item 2 "回退到上一个版本"
	item 3 "装指定版本"
	item 0 "返回"
	echo
	ask "  请选择: " ''
	case $REPLY in
	1) if [[ -n $latest ]]; then switch_core "$latest"; else bad "查不到最新版"; fi ;;
	2) rollback_core ;;
	3)
		ask "  版本号（例如 26.10.31）: " ''
		[[ $REPLY =~ ^v?[0-9]+(\.[0-9]+){1,3}$ ]] || {
			bad "版本号格式不对"
			pause
			return 0
		}
		switch_core "v${REPLY#v}"
		;;
	*) return 0 ;;
	esac
	pause
}

# ───────────────────────────── 菜单：服务 ─────────────────────────────

svc_menu() {
	echo
	item 1 "启动"
	item 2 "停止"
	item 3 "重启"
	item 4 "看最近的日志"
	item 5 "实时看日志" "Ctrl+C 退出"
	item 6 "自检" "本机当一次客户端，真连一遍"
	item 0 "返回"
	echo
	ask "  请选择: " ''
	case $REPLY in
	1) if systemctl start "$SVC" >>"$LOG" 2>&1 && svc_wait; then good "已启动"; else bad "启动失败，看看日志"; fi ;;
	2)
		confirm "停了以后所有人都连不上，确定？" || return 0
		collect_traffic
		systemctl stop "$SVC" >>"$LOG" 2>&1
		good "已停止（开机还会自动起来；要彻底不用就卸载）"
		;;
	3) if svc_restart; then good "已重启"; else bad "重启失败，看看日志"; fi ;;
	4) journalctl -u "$SVC" -n 50 --no-pager -o short-iso | sed 's/^/  /' ;;
	5)
		trap ':' INT
		journalctl -u "$SVC" -f -n 20 -o short-iso
		trap - INT
		;;
	6)
		info "自检中（最多半分钟）……"
		if selftest; then good "通了：本机当客户端连自己，成功访问外网"; else bad "没通：先看日志，或重启一下再试"; fi
		;;
	*) return 0 ;;
	esac
	pause
}

# ───────────────────────────── 更新脚本 / 卸载 ─────────────────────────────

self_update() {
	local tmp v
	echo
	info "正在下载最新脚本……"
	tmp=$(mktemp)
	if ! curl -fsSL --max-time 30 "$RAW_URL" -o "$tmp" 2>>"$LOG"; then
		rm -f "$tmp"
		bad "下载失败（这台连不上 GitHub）"
		info "也可以在自己电脑上运行 bash deploy.sh root@这台IP，会自动提示更新"
		return 0
	fi
	if ! bash -n "$tmp" 2>>"$LOG"; then
		rm -f "$tmp"
		bad "下载的脚本不完整，没换"
		return 0
	fi
	v=$(sed -n 's/^SCRIPT_VERSION="\([0-9.]*\)"$/\1/p' "$tmp" | head -n1)
	[[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
		rm -f "$tmp"
		bad "下载的脚本认不出版本号，没换"
		return 0
	}
	if [[ $v == "$SCRIPT_VERSION" ]]; then
		rm -f "$tmp"
		good "已经是最新（v$v）"
		return 0
	fi
	install -m 755 "$tmp" "$CMD.new" && mv -f "$CMD.new" "$CMD"
	rm -f "$tmp"
	good "脚本已更新：v$SCRIPT_VERSION → v$v"
	pause
	exec "$CMD" _post_update
}

post_update() {
	[[ -f $CONF ]] || return 0
	if write_units; then
		systemctl restart "$SVC" >/dev/null 2>&1
	fi
	return 0
}

uninstall() {
	local p ports uadd bbr pkgs
	echo
	note "卸载会删掉 REALITY 服务、所有账号和配置，所有人的链接立刻失效。"
	confirm "确定卸载？" || return 0
	ports=$(jq -r '(.fw_ours // [])[]' "$STATE" 2>/dev/null)
	uadd=$(st_get user_added) bbr=$(st_get bbr_added) pkgs=$(st_get pkgs)
	FW=$(st_get fw)
	systemctl disable --now reality-traffic.timer >/dev/null 2>&1
	systemctl disable --now "$SVC" >/dev/null 2>&1 # 停服务时会顺手删 iptables 放行
	fw_hook down
	for p in $ports; do fw_close_port "$p"; done
	rm -f "$UNIT" "$TUNIT_SVC" "$TUNIT_TIMER"
	systemctl daemon-reload
	systemctl reset-failed "$SVC" reality-traffic.service >/dev/null 2>&1
	[[ $bbr == true ]] && rm -f "$SYSCTL_FILE"
	rm -rf "$BASE"
	rm -f "$CMD"
	[[ $uadd == true ]] && userdel "$RUN_USER" >/dev/null 2>&1
	echo
	good "已卸载，删掉了："
	info "  · 服务 reality 和每小时的流量统计"
	info "  · $BASE（程序、配置、账号、流量记录）"
	info "  · 命令 $CMD"
	[[ -n $ports || $FW == iptables ]] && info "  · 防火墙里本脚本加的放行规则"
	[[ $uadd == true ]] && info "  · 系统用户 $RUN_USER"
	[[ $bbr == true ]] && info "  · BBR 设置文件（下次重启后恢复系统默认）"
	[[ -n $pkgs ]] && info "  留着没动：安装时补装的小工具（$pkgs），别的程序可能也在用"
	echo
	exit 0
}

# 已经装过、又拿一个新文件来跑 → 版本更新就提示升级
update_from_file() {
	local src=$0 v
	[[ -f $src && $src != /dev/* && $src != /proc/* && -f $CMD ]] || return 0
	[[ $(readlink -f "$src") == "$(readlink -f "$CMD")" ]] && return 0
	v=$(sed -n 's/^SCRIPT_VERSION="\([0-9.]*\)"$/\1/p' "$CMD" | head -n1)
	[[ $v == "$SCRIPT_VERSION" ]] && return 0
	if [[ -n $v ]] && ! newer "$SCRIPT_VERSION" "$v"; then
		note "这个文件（v$SCRIPT_VERSION）比已装的（v$v）旧，不动它"
		return 0
	fi
	echo
	note "这台已经装过（v${v:-?}），手上这个文件是 v$SCRIPT_VERSION"
	confirm_yes "更新到 v$SCRIPT_VERSION？" || return 0
	bash -n "$src" 2>/dev/null || die "这个文件不完整，没更新"
	install -m 755 "$src" "$CMD"
	post_update
	good "已更新到 v$SCRIPT_VERSION（账号、配置都没动）"
	sleep 1
}

# ───────────────────────────── 主菜单 ─────────────────────────────

menu() {
	{ : </dev/tty; } 2>/dev/null || die "管理菜单要在终端里打开（ssh 登录后直接输入 reality）"
	LOG=$BASE/last.log
	: >"$LOG"
	chmod 600 "$LOG"
	while :; do
		[[ -t 1 ]] && clear
		load
		collect_traffic
		echo
		show_panel
		echo
		item 1 "查看节点" "链接 / 二维码 / Clash 配置"
		item 2 "用户管理" "加人 / 删人 / 看每人流量"
		item 3 "换端口 / 伪装网站"
		item 4 "更新 / 回退 Xray"
		item 5 "启动 · 停止 · 重启 · 日志"
		item 6 "更新脚本"
		item 7 "卸载"
		item 0 "退出"
		echo
		ask "  请选择 [0-7]: " ''
		case $REPLY in
		1) view_node && pause ;;
		2) users_menu ;;
		3) change_menu ;;
		4) core_menu ;;
		5) svc_menu ;;
		6) self_update && pause ;;
		7) uninstall ;;
		0 | q | Q)
			echo
			exit 0
			;;
		esac
	done
}

# ───────────────────────────── 安装 ─────────────────────────────

STEP_I=0
STEP_N=6
step() {
	STEP_I=$((STEP_I + 1))
	local t="[$STEP_I/$STEP_N] $1 "
	printf '  %s%s%s%s%s ' "$t" "$DIM" "$(rep . $((30 - $(dw "$t"))))" "$RST" ""
}
step_ok() { printf '%s✓%s %s\n' "$GRN" "$RST" "$*"; }
step_warn() { printf '%s!%s %s\n' "$YEL" "$RST" "$*"; }
step_fail() {
	printf '%s✗%s %s\n' "$RED" "$RST" "$*"
	if [[ -s $LOG ]]; then
		echo
		tail -n 12 "$LOG" | sed 's/^/    /'
	fi
	install_abort
}

install_abort() {
	trap - INT TERM
	echo
	note "安装没完成，正在把装了一半的东西清掉……"
	systemctl disable --now reality-traffic.timer "$SVC" >/dev/null 2>&1
	rm -f "$UNIT" "$TUNIT_SVC" "$TUNIT_TIMER"
	systemctl daemon-reload >/dev/null 2>&1
	if [[ -n ${FW_OPENED:-} && -f $STATE ]]; then fw_close_port "$FW_OPENED"; fi
	[[ ${BBR_ADDED:-} == true ]] && rm -f "$SYSCTL_FILE"
	rm -rf "$BASE"
	rm -f "$CMD"
	[[ ${USER_ADDED:-} == true ]] && userdel "$RUN_USER" >/dev/null 2>&1
	info "已清干净。安装过程记录在 $LOG"
	exit 1
}

install_self() {
	local src=$0 tmp rc
	if [[ -f $src && $src != /dev/* && $src != /proc/* ]]; then
		install -m 755 "$src" "$CMD"
		return
	fi
	tmp=$(mktemp)
	curl -fsSL --max-time 30 "$RAW_URL" -o "$tmp" 2>>"$LOG" && bash -n "$tmp" 2>>"$LOG" && install -m 755 "$tmp" "$CMD"
	rc=$?
	rm -f "$tmp"
	return $rc
}

usage() {
	cat <<EOF

  REALITY 一键安装与管理  v$SCRIPT_VERSION

  安装：bash <(curl -fsSL $RAW_URL) [安装选项]
  管理：reality
  更新：管理界面里选「更新脚本」

  安装选项（都可以不填）：
    --port 端口       指定端口（默认优先 443，被占就随机挑）
    --sni 域名        指定伪装网站（默认自动挑最快的合格网站）
    --name 名字       第一个账号的名字（默认「主账号」）
    --label 前缀      节点显示名前缀（默认按机房国家，例如 US）
    --xray 版本       装指定版本 Xray（默认最新正式版）
    --offline 目录    用离线包安装（目录里放 Xray-linux-*.zip 和对应 .dgst）
    -y                遇到提问一律按默认走

EOF
}

install_flow() {
	local opt_port='' opt_sni='' opt_name='主账号' opt_label='' opt_xray='' other tag tmpd r ms id api clients
	while (($#)); do
		case $1 in
		--port) opt_port=${2:-} && shift ;;
		--sni) opt_sni=${2:-} && shift ;;
		--name) opt_name=${2:-} && shift ;;
		--label) opt_label=${2:-} && shift ;;
		--xray) opt_xray=${2:-} && shift ;;
		--offline) OFFLINE_DIR=${2:-} && shift ;;
		-y | --yes) ASSUME_YES=1 ;;
		-h | --help)
			usage
			exit 0
			;;
		*) die "不认识的选项：$1（--help 看用法）" ;;
		esac
		shift
	done

	echo
	printf '  %sREALITY 一键安装%s  %sv%s%s\n' "$BLD" "$RST" "$DIM" "$SCRIPT_VERSION" "$RST"
	line 46

	detect_os
	need_systemd
	# 不覆盖不是自己的东西
	[[ -e $BASE ]] && die "$BASE 已经存在但不是装好的状态（可能是上次没装完，或别的程序在用），先看一眼再处理"
	[[ -e $CMD ]] && die "$CMD 已经存在（别的程序？），先看一眼再处理"
	valid_name "$opt_name" || die "--name 只能用中英文、数字和 _ . -，最多 20 个字"
	[[ -z $opt_label || $opt_label =~ ^[[:alnum:]_.-]{1,12}$ ]] || die "--label 只能用中英文、数字和 _ . -，最多 12 个字"
	if [[ -n $opt_port ]]; then
		if ! [[ $opt_port =~ ^[0-9]+$ ]] || ((opt_port < 1 || opt_port > 65535)); then die "--port 要是 1-65535 之间的数字"; fi
	fi
	if [[ -n $OFFLINE_DIR && ! -d $OFFLINE_DIR ]]; then die "离线目录不存在：$OFFLINE_DIR"; fi

	other=$(other_proxy)
	if [[ -n $other ]]; then
		note "这台已经有别的梯子在跑（$other）。"
		info "  新装的用独立目录、独立端口、独立服务，跟它互不影响。"
		confirm_yes "继续装？" || exit 0
	fi

	LOG=$(mktemp /tmp/reality-install.XXXXXX)
	chmod 600 "$LOG"
	USER_ADDED=false BBR_ADDED=false FW_OPENED=''
	trap 'echo; install_abort' INT TERM
	echo

	# 1 系统
	step "检查系统"
	ensure_deps || step_fail "补装依赖失败（apt 出错）"
	detect_net
	VENDOR=$(detect_vendor)
	[[ -n $ADDR ]] || step_fail "查不到这台的公网 IP（访问不了外网？）"
	step_ok "$OS_NAME · $ARCH"

	# 2 Xray
	if [[ -n $OFFLINE_DIR ]]; then
		tag=offline
	elif [[ -n $opt_xray ]]; then
		tag=v${opt_xray#v}
	else
		tag=$(xray_latest 15) || {
			step "下载 Xray"
			step_fail "连不上 GitHub（国内机器常见）。可以用 --offline 离线包装"
		}
	fi
	step "下载 Xray ${tag#v}"
	mkdir -p "$BASE"
	tmpd=$(mktemp -d)
	fetch_xray "$tag" "$tmpd" || {
		rm -rf "$tmpd"
		step_fail "$FETCH_ERR"
	}
	install -m 755 "$tmpd/xray" "$BIN"
	rm -rf "$tmpd"
	if [[ $tag == offline ]]; then step_ok "Xray $(xver)，官方校验码对上"; else step_ok "官方校验码对上"; fi

	# 3 伪装网站
	step "挑伪装网站"
	if [[ -n $opt_sni ]]; then
		SNI=${opt_sni,,}
		ms=$(sni_check "$SNI" "$BIN") || step_fail "$SNI 不合格：要 TLS 1.3 + 抗量子密钥交换 + HTTP/2，且不能走 Cloudflare"
	else
		r=$(pick_sni "$BIN") || step_fail "候选网站一个都不合格（这台访问外网有问题？）"
		SNI=${r% *} ms=${r#* }
	fi
	step_ok "$SNI（握手 ${ms}ms）"

	# 4 密钥、账号、配置
	step "生成密钥和账号"
	if [[ -n $opt_port ]]; then
		port_busy "$opt_port" && step_fail "端口 $opt_port 已经被占了"
		PORT=$opt_port
	else
		PORT=$(pick_port) || step_fail "挑不到空闲端口"
	fi
	if ! id -u "$RUN_USER" >/dev/null 2>&1; then
		useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$RUN_USER" >>"$LOG" 2>&1 ||
			step_fail "建系统用户 $RUN_USER 失败"
		USER_ADDED=true
	fi
	gen_keys "$BIN" || step_fail "生成密钥失败"
	SID=$(new_sid)
	id=$("$BIN" uuid)
	api=$(pick_local_port) || step_fail "挑不到本机统计端口"
	clients=$(jq -nc --arg id "$id" --arg n "$opt_name" '[{ id: $id, flow: "xtls-rprx-vision", email: $n }]')
	build_config "$PORT" "$SNI" "$PRIV" "$SID" "$api" "$clients" >"$BASE/config.new.json"
	"$BIN" run -test -config "$BASE/config.new.json" >>"$LOG" 2>&1 || step_fail "生成的配置没通过 Xray 检查"
	chown root:"$RUN_USER" "$BASE"
	chmod 750 "$BASE"
	install -m 640 -o root -g "$RUN_USER" "$BASE/config.new.json" "$CONF"
	rm -f "$BASE/config.new.json"
	LABEL=${opt_label:-$LOC}
	[[ $LABEL == XX ]] && LABEL=VPS
	FW=$(fw_detect)
	jq -n --arg v "$SCRIPT_VERSION" --arg pbk "$PBK" --arg addr "$ADDR" --arg loc "$LOC" --arg label "$LABEL" \
		--argjson api "$api" --arg fw "$FW" --arg vendor "$VENDOR" --arg pkgs "$PKGS_ADDED" \
		--argjson ua "$USER_ADDED" --arg created "$(date +%F)" '{
		script: $v, pbk: $pbk, addr: $addr, loc: $loc, label: $label, api_port: $api,
		fw: $fw, fw_ours: [], vendor: $vendor, pkgs: $pkgs, user_added: $ua, bbr_added: false, created: $created
	}' >"$STATE"
	chmod 600 "$STATE"
	step_ok "端口 $PORT"

	# 5 防火墙 + 加速
	step "放行端口、开加速"
	if fw_open_port "$PORT"; then
		[[ $FW == ufw || $FW == firewalld ]] && FW_OPENED=$PORT
	else
		step_fail "防火墙放行失败（$FW）"
	fi
	enable_bbr
	st_setj bbr_added "$BBR_ADDED"
	case $FW in
	1panel | nft) step_warn "防火墙要手动放行（见下面）· $BBR_TXT" ;;
	*) step_ok "$(fw_label "$FW") · $BBR_TXT" ;;
	esac

	# 6 启动 + 自检
	step "启动并自检"
	install_self || step_fail "装管理命令 $CMD 失败（连不上 GitHub？可以把 install.sh 传到服务器上再运行）"
	write_units
	systemctl enable --now "$SVC" >>"$LOG" 2>&1 || step_fail "服务起不来"
	systemctl enable --now reality-traffic.timer >>"$LOG" 2>&1
	svc_wait || step_fail "服务起来了但没在端口 $PORT 上监听"
	selftest || step_fail "自检没通过：本机当客户端连不上自己"
	step_ok "本机当客户端连自己，成功"

	trap - INT TERM
	mv -f "$LOG" "$BASE/install.log"
	LOG=$BASE/install.log

	echo
	line 46
	good "${BLD}装好了！${RST}以后随时输入 ${CYN}reality${RST} 打开管理界面"
	[[ $PORT != 443 ]] && note "443 被占了，用的是 $PORT（Xray 官方建议 443，别的端口更容易被盯上）"
	fw_hints
	show_node "$opt_name"
	echo
}

# ───────────────────────────── 入口 ─────────────────────────────

main() {
	set_locale
	init_colors
	case ${1:-} in
	_fw_up)
		fw_hook up
		exit 0
		;;
	_fw_down)
		fw_hook down
		exit 0
		;;
	_collect)
		collect_traffic
		exit 0
		;;
	-h | --help)
		usage
		exit 0
		;;
	-v | --version)
		echo "$SCRIPT_VERSION"
		exit 0
		;;
	esac
	need_root
	local a
	for a in "$@"; do [[ $a == -y || $a == --yes ]] && ASSUME_YES=1; done
	if [[ ${1:-} == _post_update ]]; then
		post_update
		shift
	fi
	if [[ -f $CONF && -x $BIN && -f $STATE ]]; then
		command -v jq >/dev/null 2>&1 || die "缺 jq（apt install jq）"
		update_from_file
		menu
	else
		install_flow "$@"
	fi
}

# 测试时 REALITY_LIB=1 只加载函数不执行
[[ ${REALITY_LIB:-} == 1 ]] || main "$@"
