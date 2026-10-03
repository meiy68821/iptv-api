# 在 macOS（Mac mini）上一键部署 UnblockNeteaseMusic/server

上游项目：<https://github.com/UnblockNeteaseMusic/server>（LGPL-3.0）。
上游 README 写明“macOS 因为签名问题，暂时不提供可运行文件”，所以这里用 Node.js + npm 包的方式部署。

## 安装

打开“终端”（应用程序 > 实用工具 > 终端），粘贴下面这行后回车。**不要加 sudo**，需要密码时脚本会提示：

```bash
curl -fsSL https://raw.githubusercontent.com/meiy68821/iptv-api/claude/unm-server-mac-deployment-vo8ry4/deploy/unm-macos/install.sh | bash
```

运行过程中会问两个问题，默认都是“否”，要输入 `y` 回车才执行：

1. **是否信任 CA 证书**：新版网易云 macOS 客户端（726 版以上）必须选 `y`，否则解锁不生效。
2. **是否设置自动代理（PAC）**：选 `y` 后只有网易云的域名经过 UNM，其他上网流量不受影响。

完成后，用 Command+Q 彻底退出网易云音乐，再重新打开。

## 脚本做了什么

| 步骤 | 内容 | 位置 |
| --- | --- | --- |
| Node.js | 本机没有 18 及以上版本时，从 nodejs.org 下载官方安装包 v24.21.0（`node-v24.21.0.pkg`，约 89 MB），校验 SHA256 后安装 | `/usr/local/bin/node` |
| UNM | 安装 npm 包 `@unblockneteasemusic/server` 的最新版 | `~/.unm/node_modules/` |
| 证书 | 在本机新生成一套 CA 和服务器证书，不使用项目自带的公共证书 | `~/.unm/cert/` |
| 开机服务 | 注册 launchd 服务，开机即运行（无需登录），崩溃后自动重启 | `/Library/LaunchDaemons/com.unblockneteasemusic.server.plist` |
| 自动代理 | 可选，PAC 地址 `http://127.0.0.1:8080/proxy.pac` | 系统设置 > 网络 |

## 配置

- `~/.unm/unm.conf`：监听地址、端口、音源顺序、严格模式。
  - 默认只监听 `127.0.0.1`，即只有这台 Mac 自己能用。要让局域网里其他设备也用，改成 `LISTEN_ADDRESS=0.0.0.0`，再在其他设备上设置代理 `http://<Mac mini 的 IP>:8080/proxy.pac`。如果开启了 macOS 防火墙，还需要允许 node 接收传入连接。
- `~/.unm/.env`：环境变量。默认开启了无损音质（`ENABLE_FLAC`）、最高码率（`SELECT_MAX_BR`），关闭了更新检测。全部可选项见上游 README 的“环境变量”一节。

修改后重启服务：

```bash
sudo launchctl kickstart -k system/com.unblockneteasemusic.server
```

## 常用命令

```bash
# 查看运行状态
sudo launchctl print system/com.unblockneteasemusic.server | grep -E "state|pid"
# 查看日志
tail -f ~/.unm/logs/unm.log ~/.unm/logs/unm.err.log
# 升级：重新运行安装命令即可，证书和配置会保留
```

## 卸载

```bash
curl -fsSL https://raw.githubusercontent.com/meiy68821/iptv-api/claude/unm-server-mac-deployment-vo8ry4/deploy/unm-macos/uninstall.sh | bash
```

卸载会停止并移除服务、关闭安装时设置的自动代理、从钥匙串移除 CA，最后询问是否删除 `~/.unm`。Node.js 不会被卸载。

## 注意事项

- `~/.unm/cert/ca.key` 是 CA 私钥。CA 被信任后，持有这个私钥的人可以伪造任何网站的证书，请勿外传或上传。
- 通过 SSH 远程运行时，macOS 可能拒绝在没有图形界面确认的情况下写入证书信任设置。遇到报错就在 Mac mini 本机的“终端”里运行。
- 服务器证书有效期 825 天（macOS 对自签证书的上限），到期前先运行卸载命令（会移除旧 CA，删除目录时选 `y`），再重新运行安装命令，即可换上新证书。
- 默认音源里的 `ytdlp` 需要另外安装 yt-dlp，不装也不影响其他音源。
