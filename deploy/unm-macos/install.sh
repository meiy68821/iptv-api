#!/bin/bash
# UnblockNeteaseMusic/server 一键安装脚本（macOS）
#
# 用法（在“终端”中以普通用户身份运行，不要加 sudo）：
#   curl -fsSL https://raw.githubusercontent.com/meiy68821/iptv-api/claude/unm-server-mac-deployment-vo8ry4/deploy/unm-macos/install.sh | bash
#
# 脚本做的事：
#   1. 检查 Node.js（>= 18），没有则从 nodejs.org 官方下载安装包，校验 SHA256 后安装
#   2. 用 npm 安装 @unblockneteasemusic/server 到 ~/.unm
#   3. 在本机生成一套自签 CA 与服务器证书（私钥只留在本机）
#   4. 询问是否把 CA 加入系统钥匙串并设为信任（新版网易云 macOS 客户端需要）
#   5. 注册 launchd 服务，开机自动在后台运行
#   6. 询问是否为当前网络设置 PAC 自动代理（只有网易云的域名走 UNM）
#
# 可以重复运行：重复运行即升级 UNM，已有证书和配置会保留。

set -euo pipefail

# ---------- 可通过环境变量覆盖的参数 ----------
NODE_VERSION="${NODE_VERSION:-v24.21.0}"     # 只在本机没有可用 Node.js 时才下载
UNM_HOME="${UNM_HOME:-$HOME/.unm}"
LABEL="com.unblockneteasemusic.server"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
NPM_REGISTRY="${NPM_REGISTRY:-}"             # 留空使用 npm 默认源

# ---------- 输出工具 ----------
info()  { printf '\033[1;34m[UNM]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[完成]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[注意]\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

# 通过 curl | bash 运行时 stdin 被占用，从 /dev/tty 读用户输入
ask_yes() {
	local prompt="$1" default="${2:-N}" reply=""
	if [ -r /dev/tty ]; then
		read -r -p "$prompt " reply </dev/tty || true
	fi
	reply="${reply:-$default}"
	case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# ---------- 0. 环境检查 ----------
[ "$(uname -s)" = "Darwin" ] || die "本脚本只适用于 macOS。"
[ "$(id -u)" -ne 0 ] || die "请不要用 sudo 运行本脚本，需要管理员权限的步骤会单独提示输入密码。"
command -v curl >/dev/null || die "缺少 curl。"
command -v openssl >/dev/null || die "缺少 openssl。"

info "安装目录：$UNM_HOME"
info "接下来部分步骤需要管理员密码（安装 Node.js、信任证书、注册开机服务）。"
sudo -v || die "未获得管理员权限。"

mkdir -p "$UNM_HOME"/{cert,logs}

# ---------- 1. Node.js ----------
find_node() {
	local candidate
	for candidate in "$(command -v node 2>/dev/null || true)" /usr/local/bin/node /opt/homebrew/bin/node; do
		[ -n "$candidate" ] && [ -x "$candidate" ] || continue
		local major
		major="$("$candidate" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
		if [ "$major" -ge 18 ] 2>/dev/null; then
			echo "$candidate"
			return 0
		fi
	done
	return 1
}

if NODE_BIN="$(find_node)"; then
	ok "已检测到 Node.js $("$NODE_BIN" -v)：$NODE_BIN"
else
	info "未检测到 Node.js 18 及以上版本，开始从 nodejs.org 下载官方安装包 ${NODE_VERSION}……"
	tmpdir="$(mktemp -d)"
	pkg="node-${NODE_VERSION}.pkg"
	curl -fL --progress-bar -o "$tmpdir/$pkg" "https://nodejs.org/dist/${NODE_VERSION}/${pkg}"
	curl -fsSL -o "$tmpdir/SHASUMS256.txt" "https://nodejs.org/dist/${NODE_VERSION}/SHASUMS256.txt"
	expected="$(awk -v f="$pkg" '$2 == f { print $1 }' "$tmpdir/SHASUMS256.txt")"
	actual="$(shasum -a 256 "$tmpdir/$pkg" | awk '{ print $1 }')"
	[ -n "$expected" ] && [ "$expected" = "$actual" ] || die "Node.js 安装包校验失败（期望 ${expected}，实际 ${actual}），已中止。"
	ok "安装包 SHA256 校验通过。"
	sudo installer -pkg "$tmpdir/$pkg" -target /
	rm -rf "$tmpdir"
	NODE_BIN="$(find_node)" || die "Node.js 安装后仍找不到可用的 node。"
	ok "Node.js $("$NODE_BIN" -v) 安装完成。"
fi
NPM_BIN="$(dirname "$NODE_BIN")/npm"
[ -x "$NPM_BIN" ] || NPM_BIN="$(command -v npm || true)"
[ -n "$NPM_BIN" ] || die "找不到 npm。"

# ---------- 2. UNM 本体 ----------
info "安装 / 升级 @unblockneteasemusic/server……"
[ -f "$UNM_HOME/package.json" ] || printf '{ "private": true }\n' > "$UNM_HOME/package.json"
npm_args=(install --prefix "$UNM_HOME" --no-fund --no-audit @unblockneteasemusic/server@latest)
[ -n "$NPM_REGISTRY" ] && npm_args+=(--registry "$NPM_REGISTRY")
PATH="$(dirname "$NODE_BIN"):$PATH" "$NPM_BIN" "${npm_args[@]}"
APP_JS="$UNM_HOME/node_modules/@unblockneteasemusic/server/precompiled/app.js"
[ -f "$APP_JS" ] || die "安装后找不到 ${APP_JS}。"
UNM_VERSION="$("$NODE_BIN" -p "require('$UNM_HOME/node_modules/@unblockneteasemusic/server/package.json').version")"
ok "UNM $UNM_VERSION 已安装。"

# ---------- 3. 证书 ----------
CERT_DIR="$UNM_HOME/cert"
if [ -f "$CERT_DIR/ca.crt" ] && [ -f "$CERT_DIR/server.crt" ] && [ -f "$CERT_DIR/server.key" ]; then
	ok "沿用已有证书：$CERT_DIR"
else
	info "生成本机专用证书……"
	(
		cd "$CERT_DIR"
		umask 077
		CA_CN="UNM Local CA ($(scutil --get LocalHostName 2>/dev/null || hostname -s) $(date +%Y%m%d))"
		openssl genrsa -out ca.key 2048 2>/dev/null
		openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt \
			-subj "/C=CN/O=UnblockNeteaseMusic/CN=${CA_CN}"
		openssl genrsa -out server.key 2048 2>/dev/null
		openssl req -new -sha256 -key server.key -out server.csr \
			-subj "/C=CN/L=Hangzhou/O=NetEase (Hangzhou) Network Co., Ltd/OU=IT Dept./CN=*.music.163.com"
		printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:music.163.com,DNS:*.music.163.com\n' > server.ext
		# macOS 要求自签服务器证书有效期不超过 825 天
		openssl x509 -req -sha256 -days 825 -in server.csr -CA ca.crt -CAkey ca.key \
			-CAcreateserial -extfile server.ext -out server.crt 2>/dev/null
		rm -f server.csr server.ext ca.srl
		chmod 644 ca.crt server.crt
	)
	ok "证书已生成：$CERT_DIR"
fi
CA_SHA1="$(openssl x509 -in "$CERT_DIR/ca.crt" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"

# ---------- 4. 信任 CA ----------
if security find-certificate -a -Z /Library/Keychains/System.keychain 2>/dev/null | grep -qi "$CA_SHA1"; then
	ok "CA 证书已在系统钥匙串中。"
else
	echo
	warn "新版网易云音乐 macOS 客户端需要信任 UNM 的 CA 证书才能解锁。"
	warn "信任后，持有该 CA 私钥（$CERT_DIR/ca.key）的程序可以伪造任意网站证书，请勿外传此文件。"
	if ask_yes "是否把 CA 加入系统钥匙串并设为信任？[y/N]" N; then
		sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$CERT_DIR/ca.crt"
		ok "已信任 CA 证书。"
	else
		warn "已跳过。之后可手动运行：sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain \"$CERT_DIR/ca.crt\""
	fi
fi

# ---------- 5. 配置与启动脚本 ----------
CONF="$UNM_HOME/unm.conf"
if [ ! -f "$CONF" ]; then
	cat > "$CONF" <<'EOF'
# UNM 运行参数。修改后执行以下命令重启生效：
#   sudo launchctl kickstart -k system/com.unblockneteasemusic.server

# 监听地址：127.0.0.1 仅本机可用；0.0.0.0 允许局域网其他设备使用
LISTEN_ADDRESS=127.0.0.1
# HTTP 端口:HTTPS 端口
PORTS=8080:8081
# 音源顺序，留空用默认（参见项目 README 的“音源清单”）
SOURCES=""
# 严格模式：只代理网易云音乐的域名（1 开启，0 关闭）
STRICT=1
# 其他命令行参数，如 "-u http://上游代理:端口"
EXTRA_ARGS=""
EOF
fi

ENV_FILE="$UNM_HOME/.env"
if [ ! -f "$ENV_FILE" ]; then
	cat > "$ENV_FILE" <<'EOF'
# UNM 环境变量（项目 README “环境变量”一节列出全部可选项）
ENABLE_FLAC=true
SELECT_MAX_BR=true
DISABLE_UPGRADE_CHECK=true
EOF
fi

START="$UNM_HOME/start.sh"
cat > "$START" <<EOF
#!/bin/bash
# 由 install.sh 生成，launchd 通过它启动 UNM。参数请改 unm.conf。
cd "$UNM_HOME"
. "$CONF"
export SIGN_CERT="$CERT_DIR/server.crt"
export SIGN_KEY="$CERT_DIR/server.key"
args=(-p "\$PORTS" -a "\$LISTEN_ADDRESS")
[ "\$STRICT" = "1" ] && args+=(-s)
[ -n "\$SOURCES" ] && args+=(-o \$SOURCES)
exec "$NODE_BIN" "$APP_JS" "\${args[@]}" \$EXTRA_ARGS
EOF
chmod 755 "$START"

# ---------- 6. launchd 开机服务 ----------
info "注册开机服务 ${LABEL}……"
tmp_plist="$(mktemp)"
cat > "$tmp_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>UserName</key>
	<string>$(id -un)</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${START}</string>
	</array>
	<key>WorkingDirectory</key>
	<string>${UNM_HOME}</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>10</integer>
	<key>StandardOutPath</key>
	<string>${UNM_HOME}/logs/unm.log</string>
	<key>StandardErrorPath</key>
	<string>${UNM_HOME}/logs/unm.err.log</string>
</dict>
</plist>
EOF
sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
sudo install -m 644 -o root -g wheel "$tmp_plist" "$PLIST"
rm -f "$tmp_plist"
sudo launchctl bootstrap system "$PLIST"
sudo launchctl enable "system/$LABEL"

. "$CONF"
HTTP_PORT="${PORTS%%:*}"
info "等待服务启动……"
started=0
for _ in $(seq 1 20); do
	if curl -fs --max-time 2 "http://127.0.0.1:${HTTP_PORT}/proxy.pac" 2>/dev/null | grep -q FindProxyForURL; then
		started=1
		break
	fi
	sleep 1
done
if [ "$started" = 1 ]; then
	ok "UNM 已在后台运行，端口 ${PORTS}。"
else
	warn "未能确认服务启动，请查看日志：$UNM_HOME/logs/unm.err.log"
fi

# ---------- 7. PAC 自动代理 ----------
PAC_URL="http://127.0.0.1:${HTTP_PORT}/proxy.pac"
active_service() {
	local dev
	dev="$(route -n get default 2>/dev/null | awk '/interface:/ { print $2 }')"
	[ -n "$dev" ] || return 1
	networksetup -listnetworkserviceorder | awk -v dev="$dev" '
		/^\([0-9]+\)/ { sub(/^\([0-9]+\) /, ""); name = $0 }
		$0 ~ "Device: " dev "\\)" { print name; exit }'
}
echo
SERVICE="$(active_service || true)"
if [ -n "$SERVICE" ]; then
	info "当前联网的网络服务：$SERVICE"
	if ask_yes "是否为“${SERVICE}”设置自动代理 ${PAC_URL}（只有网易云域名走 UNM）？[y/N]" N; then
		sudo networksetup -setautoproxyurl "$SERVICE" "$PAC_URL"
		sudo networksetup -setautoproxystate "$SERVICE" on
		printf '%s\n' "$SERVICE" > "$UNM_HOME/.pac_service"
		ok "已设置自动代理。"
	else
		warn "已跳过。可在“系统设置 > 网络 > $SERVICE > 详细信息 > 代理 > 自动代理配置”中填入：$PAC_URL"
	fi
else
	warn "未识别到当前联网的网络服务，请手动在系统设置中配置自动代理：$PAC_URL"
fi

echo
ok "全部完成。"
cat <<EOF

  UNM 版本     ：$UNM_VERSION
  安装目录     ：$UNM_HOME
  运行参数     ：$CONF
  环境变量     ：$ENV_FILE
  日志         ：$UNM_HOME/logs/
  PAC 地址     ：$PAC_URL
  重启服务     ：sudo launchctl kickstart -k system/$LABEL
  升级         ：重新运行本安装命令
  卸载         ：curl -fsSL https://raw.githubusercontent.com/meiy68821/iptv-api/claude/unm-server-mac-deployment-vo8ry4/deploy/unm-macos/uninstall.sh | bash

  设置完成后请彻底退出网易云音乐（Command+Q）再重新打开。
EOF
