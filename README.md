# Hysteria 2 一键安装脚本

一条命令在 Linux VPS 上安装 Hysteria 2，生成服务端配置，放行 UDP 端口，设置 systemd 开机自启，并输出客户端导入链接。

默认配置：

- 端口：`443/udp`
- TLS：自签证书，客户端链接带 `insecure=1` 和 `pinSHA256`
- 混淆：`salamander`
- 认证密码：自动随机生成
- 伪装站：`https://www.bing.com/`
- 服务：`hysteria-server.service`
- 可选：多用户 Web 管理面板

## 一键安装

直接运行会进入交互式安装向导。每一项都带默认值，直接按回车就会使用默认配置：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/hysteria2-onekey/main/install.sh)
```

安装时可以选择：

- 导入链接里的服务器地址：默认自动探测公网 IPv4
- Hysteria UDP 端口：默认 `443`
- 是否放行系统防火墙 UDP 端口：默认开启
- 是否开启 Salamander 混淆：默认开启
- Salamander 混淆密码：默认自动随机生成
- SNI / 证书名称：默认 `www.bing.com`
- 伪装站：默认 `https://www.bing.com/`
- 是否开启多用户 Web 面板：默认关闭
- Web 面板端口、公网访问、管理账号和管理密码
- 初始 Hysteria 用户名和密码

单用户安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/hysteria2-onekey/main/install.sh)
```

多用户 + Web 面板安装：

```bash
ENABLE_PANEL=1 \
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/hysteria2-onekey/main/install.sh)
```

默认 Web 面板监听公网 `0.0.0.0:8080`，脚本会自动放行服务器系统防火墙里的 `TCP 8080`。安装完成后浏览器打开：

```text
http://服务器IP:8080
```

管理账号默认是 `admin`，管理密码默认自动随机生成并在安装结果里输出。

如果要自己指定管理账号和密码：

```bash
ENABLE_PANEL=1 \
PANEL_ADMIN_USER=myadmin \
PANEL_ADMIN_PASS='换成你的强密码' \
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/hysteria2-onekey/main/install.sh)
```

如果服务器不能访问 `raw.githubusercontent.com`，可以先拉仓库再运行：

```bash
git clone https://github.com/1660667086/hysteria2-onekey.git
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
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/hysteria2-onekey/main/install.sh)
```

常用变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `INTERACTIVE` | `auto` | 有终端时显示交互向导；设为 `0` 可全自动无提示安装 |
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

全自动无提示安装示例：

```bash
INTERACTIVE=0 \
ENABLE_PANEL=1 \
PANEL_ADMIN_USER=admin \
PANEL_ADMIN_PASS='换成你的强密码' \
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/hysteria2-onekey/main/install.sh)
```

Web 面板变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `ENABLE_PANEL` | `0` | 设为 `1` 启用多用户 Web 面板 |
| `PANEL_BIND` | `0.0.0.0` | 面板监听地址，默认公网；只想本机访问可设为 `127.0.0.1` |
| `PANEL_PORT` | `8080` | 面板 TCP 端口 |
| `PANEL_ADMIN_USER` | `admin` | 面板登录用户名 |
| `PANEL_ADMIN_PASS` | 自动随机 | 面板登录密码 |
| `PANEL_OPEN_FIREWALL` | `1` | 默认放行面板 TCP 端口；设为 `0` 可跳过 |
| `INITIAL_USER` | `user1` | 初始 Hysteria 用户名 |
| `INITIAL_USER_PASS` | 自动随机 | 初始 Hysteria 用户密码 |

两种管理账号密码方式：

- 默认：不填 `PANEL_ADMIN_USER` / `PANEL_ADMIN_PASS`，账号为 `admin`，密码自动随机生成
- 自定义：安装时填写 `PANEL_ADMIN_USER` / `PANEL_ADMIN_PASS`

如果你想把面板改回只允许 SSH 隧道访问：

```bash
ENABLE_PANEL=1 \
PANEL_BIND=127.0.0.1 \
PANEL_OPEN_FIREWALL=0 \
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/hysteria2-onekey/main/install.sh)
```

公网面板一定要使用强密码，并在云安全组中放行 `TCP 8080`。更安全的做法是在云安全组中只允许自己的 IP 访问 `PANEL_PORT`。

## Web 面板功能

启用 `ENABLE_PANEL=1` 后，脚本会额外安装并启动：

- `hysteria-panel.service`
- `/opt/hysteria2-onekey/panel.py`
- `/etc/hysteria/users.json`
- `/etc/hysteria/server.json`

面板支持：

- 新增用户
- 删除用户
- 启用/停用用户
- 重置用户密码
- 自动生成每个用户的 Hysteria2 导入链接
- 自动重写 `/etc/hysteria/config.yaml`
- 自动重启 `hysteria-server.service`

## 云安全组

脚本能自动处理服务器系统里的 `ufw`、`firewalld`、`iptables` 规则，但不能替你修改云平台安全组。

如果客户端连接超时，请在云厂商控制台手动放行：

- 入站协议：`UDP`
- 端口：脚本使用的 `PORT`，默认 `443`
- 来源：`0.0.0.0/0`

阿里云 ECS 的常见路径：

1. 进入 ECS 实例详情
2. 打开安全组
3. 入方向添加规则
4. 协议类型选 `UDP`
5. 端口范围填 `443/443`，授权对象填 `0.0.0.0/0`

## 管理命令

```bash
systemctl status hysteria-server.service
journalctl --no-pager -u hysteria-server.service -n 80
nano /etc/hysteria/config.yaml
systemctl restart hysteria-server.service
systemctl status hysteria-panel.service
```

## 卸载 Hysteria

官方卸载脚本：

```bash
bash <(curl -fsSL https://get.hy2.sh/) --remove
```
