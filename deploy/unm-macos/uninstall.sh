#!/bin/bash
# UnblockNeteaseMusic/server 卸载脚本（macOS），撤销 install.sh 所做的改动。
#
# 用法（普通用户身份运行，不要加 sudo）：
#   curl -fsSL https://raw.githubusercontent.com/meiy68821/iptv-api/claude/unm-server-mac-deployment-vo8ry4/deploy/unm-macos/uninstall.sh | bash
#
# Node.js 不会被卸载（其他程序可能在用）。

set -euo pipefail

UNM_HOME="${UNM_HOME:-$HOME/.unm}"
LABEL="com.unblockneteasemusic.server"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"

info() { printf '\033[1;34m[UNM]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[完成]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[注意]\033[0m %s\n' "$*"; }

ask_yes() {
	local prompt="$1" default="${2:-N}" reply=""
	if [ -r /dev/tty ]; then
		read -r -p "$prompt " reply </dev/tty || true
	fi
	reply="${reply:-$default}"
	case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

[ "$(id -u)" -ne 0 ] || { echo "请不要用 sudo 运行本脚本。" >&2; exit 1; }
sudo -v

# 1. 停止并移除开机服务
sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
sudo rm -f "$PLIST"
ok "已停止并移除开机服务。"

# 2. 关闭安装时设置的自动代理
if [ -f "$UNM_HOME/.pac_service" ]; then
	SERVICE="$(cat "$UNM_HOME/.pac_service")"
	sudo networksetup -setautoproxystate "$SERVICE" off || true
	ok "已关闭“$SERVICE”的自动代理。"
fi

# 3. 从系统钥匙串移除 CA
if [ -f "$UNM_HOME/cert/ca.crt" ]; then
	CA_SHA1="$(openssl x509 -in "$UNM_HOME/cert/ca.crt" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
	if security find-certificate -a -Z /Library/Keychains/System.keychain 2>/dev/null | grep -qi "$CA_SHA1"; then
		sudo security remove-trusted-cert -d "$UNM_HOME/cert/ca.crt" 2>/dev/null || true
		sudo security delete-certificate -Z "$CA_SHA1" /Library/Keychains/System.keychain
		ok "已从系统钥匙串移除 UNM 的 CA 证书。"
	fi
fi

# 4. 删除安装目录
if [ -d "$UNM_HOME" ]; then
	if ask_yes "是否删除安装目录 $UNM_HOME（含证书、配置和日志）？[y/N]" N; then
		rm -rf "$UNM_HOME"
		ok "已删除 $UNM_HOME。"
	else
		warn "已保留 $UNM_HOME。"
	fi
fi

ok "卸载完成。请彻底退出网易云音乐后重新打开。"
