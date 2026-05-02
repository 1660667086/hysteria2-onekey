# Hysteria 2 一键安装脚本

一条命令在 Linux VPS 上安装 Hysteria 2，生成服务端配置，放行 UDP 端口，设置 systemd 开机自启，并输出客户端导入链接。

默认配置：

- 端口：`443/udp`
- TLS：自签证书，客户端链接带 `insecure=1` 和 `pinSHA256`
- 混淆：`salamander`
- 认证密码：自动随机生成
- 伪装站：`https://www.bing.com/`
- 服务：`hysteria-server.service`

## 一键安装

发布到 GitHub 后，把命令里的 `<your-github-user>` 换成你的 GitHub 用户名：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<your-github-user>/hysteria2-onekey/main/install.sh)
```

如果服务器不能访问 `raw.githubusercontent.com`，可以先拉仓库再运行：

```bash
git clone https://github.com/<your-github-user>/hysteria2-onekey.git
cd hysteria2-onekey
bash install.sh
```

## 自定义参数

所有参数都可以用环境变量覆盖：

```bash
PORT=8443 \
SNI=www.bing.com \
MASQUERADE_URL=https://www.bing.com/ \
TAG=my-hy2 \
bash <(curl -fsSL https://raw.githubusercontent.com/<your-github-user>/hysteria2-onekey/main/install.sh)
```

常用变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PORT` | `443` | Hysteria 监听端口，脚本会放行 `UDP` |
| `SERVER_HOST` | 自动探测公网 IPv4 | 导入链接里的服务器地址，可填域名或 IP |
| `SNI` | `www.bing.com` | TLS SNI 和自签证书 CN/SAN |
| `MASQUERADE_URL` | `https://www.bing.com/` | 伪装代理目标 |
| `AUTH_PASS` | 自动随机 | Hysteria 认证密码 |
| `OBFS_PASS` | 自动随机 | Salamander 混淆密码 |
| `ENABLE_OBFS` | `1` | 设为 `0` 可关闭混淆 |
| `TAG` | `hysteria2` | 导入链接备注 |
| `OPEN_FIREWALL` | `1` | 设为 `0` 跳过系统防火墙放行 |
| `INSTALL_DEPS` | `1` | 设为 `0` 跳过依赖安装 |

## 云安全组

脚本能自动处理服务器系统里的 `ufw`、`firewalld`、`iptables` 规则，但不能替你修改云平台安全组。

如果客户端连接超时，请在云厂商控制台手动放行：

- 入站协议：`UDP`
- 端口：脚本使用的 `PORT`，默认 `443`
- 来源：`0.0.0.0/0`

## 管理命令

```bash
systemctl status hysteria-server.service
journalctl --no-pager -u hysteria-server.service -n 80
nano /etc/hysteria/config.yaml
systemctl restart hysteria-server.service
```

## 卸载 Hysteria

官方卸载脚本：

```bash
bash <(curl -fsSL https://get.hy2.sh/) --remove
```

