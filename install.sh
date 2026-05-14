#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="hysteria2-onekey"
HYSTERIA_INSTALL_URL="${HYSTERIA_INSTALL_URL:-https://get.hy2.sh/}"
CONFIG_DIR="${CONFIG_DIR:-/etc/hysteria}"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/config.yaml}"
CERT_FILE="${CERT_FILE:-$CONFIG_DIR/server.crt}"
KEY_FILE="${KEY_FILE:-$CONFIG_DIR/server.key}"
PORT="${PORT:-443}"
SNI="${SNI:-www.bing.com}"
MASQUERADE_URL="${MASQUERADE_URL:-https://www.bing.com/}"
SERVER_HOST="${SERVER_HOST:-}"
AUTH_PASS="${AUTH_PASS:-}"
OBFS_PASS="${OBFS_PASS:-}"
ENABLE_OBFS="${ENABLE_OBFS:-1}"
TAG="${TAG:-hysteria2}"
OPEN_FIREWALL="${OPEN_FIREWALL:-1}"
INSTALL_DEPS="${INSTALL_DEPS:-1}"
ENABLE_PANEL="${ENABLE_PANEL:-0}"
PANEL_BIND="${PANEL_BIND:-0.0.0.0}"
PANEL_PORT="${PANEL_PORT:-8080}"
PANEL_ADMIN_USER="${PANEL_ADMIN_USER:-admin}"
PANEL_ADMIN_PASS="${PANEL_ADMIN_PASS:-}"
PANEL_OPEN_FIREWALL="${PANEL_OPEN_FIREWALL:-1}"
PANEL_DIR="${PANEL_DIR:-/opt/hysteria2-onekey}"
PANEL_APP="${PANEL_APP:-$PANEL_DIR/panel.py}"
PANEL_ENV="${PANEL_ENV:-$CONFIG_DIR/panel.env}"
PANEL_SOURCE_URL="${PANEL_SOURCE_URL:-https://raw.githubusercontent.com/1660667086/hysteria2-onekey/main/panel.py}"
USERS_FILE="${USERS_FILE:-$CONFIG_DIR/users.json}"
SERVER_META_FILE="${SERVER_META_FILE:-$CONFIG_DIR/server.json}"
INITIAL_USER="${INITIAL_USER:-user1}"
INITIAL_USER_PASS="${INITIAL_USER_PASS:-}"
INTERACTIVE="${INTERACTIVE:-auto}"

red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
log() { printf '[%s] %s\n' "$SCRIPT_NAME" "$*"; }
die() { red "错误：$*"; exit 1; }

prompt_enabled() {
  local value
  value="$(printf '%s' "$INTERACTIVE" | tr '[:upper:]' '[:lower:]')"

  case "$value" in
    1|true|yes|y|on)
      return 0
      ;;
    0|false|no|n|off)
      return 1
      ;;
    auto|"")
      [[ -r /dev/tty && -w /dev/tty ]]
      ;;
    *)
      die "INTERACTIVE 必须是 auto、1 或 0"
      ;;
  esac
}

prompt_value() {
  local var_name="$1"
  local label="$2"
  local current="$3"
  local default_label="${4:-$current}"
  local answer=""

  printf '%s [%s]: ' "$label" "$default_label" >/dev/tty
  read -r answer </dev/tty || answer=""

  if [[ -n "$answer" ]]; then
    printf -v "$var_name" '%s' "$answer"
  else
    printf -v "$var_name" '%s' "$current"
  fi
}

prompt_secret_optional() {
  local var_name="$1"
  local label="$2"
  local answer=""

  printf '%s [自动，输入时不会显示]: ' "$label" >/dev/tty
  read -r -s answer </dev/tty || answer=""
  printf '\n' >/dev/tty

  if [[ -n "$answer" ]]; then
    printf -v "$var_name" '%s' "$answer"
  fi
}

prompt_yes_no() {
  local var_name="$1"
  local label="$2"
  local current="$3"
  local answer=""
  local normalized=""
  local hint="y/N"

  [[ "$current" == "1" ]] && hint="Y/n"

  while true; do
    printf '%s [%s]: ' "$label" "$hint" >/dev/tty
    read -r answer </dev/tty || answer=""

    if [[ -z "$answer" ]]; then
      printf -v "$var_name" '%s' "$current"
      return 0
    fi

    normalized="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
    case "$normalized" in
      1|true|yes|y|on|enable|enabled)
        printf -v "$var_name" '1'
        return 0
        ;;
      0|false|no|n|off|disable|disabled)
        printf -v "$var_name" '0'
        return 0
        ;;
      *)
        printf '请输入 y 或 n。\n' >/dev/tty
        ;;
    esac
  done
}

normalize_bool_var() {
  local var_name="$1"
  local value="${!var_name}"
  local normalized

  normalized="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  case "$normalized" in
    1|true|yes|y|on|enable|enabled)
      printf -v "$var_name" '1'
      ;;
    0|false|no|n|off|disable|disabled)
      printf -v "$var_name" '0'
      ;;
    *)
      die "$var_name 必须是 1 或 0"
      ;;
  esac
}

normalize_bool_vars() {
  normalize_bool_var ENABLE_OBFS
  normalize_bool_var OPEN_FIREWALL
  normalize_bool_var INSTALL_DEPS
  normalize_bool_var ENABLE_PANEL
  normalize_bool_var PANEL_OPEN_FIREWALL
}

configure_interactive() {
  prompt_enabled || return 0

  local panel_public="1"

  printf '\nHysteria 2 安装向导。直接按回车会使用括号里的默认值。\n\n' >/dev/tty

  prompt_value SERVER_HOST "导入链接里的服务器地址，留空表示自动检测公网 IPv4" "$SERVER_HOST" "自动"
  prompt_value PORT "Hysteria UDP 端口" "$PORT"
  prompt_yes_no OPEN_FIREWALL "是否放行服务器系统防火墙里的这个 UDP 端口" "$OPEN_FIREWALL"
  prompt_yes_no ENABLE_OBFS "是否开启 Salamander 混淆" "$ENABLE_OBFS"
  if [[ "$ENABLE_OBFS" == "1" ]]; then
    prompt_secret_optional OBFS_PASS "Salamander 混淆密码，留空表示随机生成"
  fi
  prompt_value SNI "TLS SNI / 证书名称" "$SNI"
  prompt_value MASQUERADE_URL "伪装站目标 URL" "$MASQUERADE_URL"
  prompt_value TAG "导入链接备注名称" "$TAG"
  prompt_yes_no ENABLE_PANEL "是否开启多用户 Web 管理面板" "$ENABLE_PANEL"

  if [[ "$ENABLE_PANEL" == "1" ]]; then
    prompt_value PANEL_PORT "Web 面板 TCP 端口" "$PANEL_PORT"
    if [[ "$PANEL_BIND" == "127.0.0.1" || "$PANEL_BIND" == "localhost" ]]; then
      panel_public="0"
    fi
    prompt_yes_no panel_public "是否允许 Web 面板公网访问" "$panel_public"
    if [[ "$panel_public" == "1" ]]; then
      PANEL_BIND="0.0.0.0"
      PANEL_OPEN_FIREWALL="1"
    else
      PANEL_BIND="127.0.0.1"
      PANEL_OPEN_FIREWALL="0"
    fi
    prompt_value PANEL_ADMIN_USER "Web 面板管理员账号" "$PANEL_ADMIN_USER"
    prompt_secret_optional PANEL_ADMIN_PASS "Web 面板管理员密码，留空表示随机生成或沿用现有密码"
    prompt_value INITIAL_USER "初始 Hysteria 用户名" "$INITIAL_USER"
    prompt_secret_optional INITIAL_USER_PASS "初始 Hysteria 用户密码，留空表示随机生成"
  else
    prompt_secret_optional AUTH_PASS "Hysteria 认证密码，留空表示随机生成"
  fi

  printf '\n' >/dev/tty
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "请使用 root 用户运行"
  fi
}

require_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "未找到 systemctl；此脚本需要 systemd"
}

validate_port() {
  [[ "$PORT" =~ ^[0-9]+$ ]] || die "PORT 必须是数字"
  (( PORT >= 1 && PORT <= 65535 )) || die "PORT 必须在 1 到 65535 之间"

  if [[ "$ENABLE_PANEL" == "1" ]]; then
    [[ "$PANEL_PORT" =~ ^[0-9]+$ ]] || die "PANEL_PORT 必须是数字"
    (( PANEL_PORT >= 1 && PANEL_PORT <= 65535 )) || die "PANEL_PORT 必须在 1 到 65535 之间"
    [[ "$INITIAL_USER" =~ ^[A-Za-z0-9_.@-]{1,64}$ ]] || die "INITIAL_USER 必须是 1-64 个字符，只能包含字母、数字、_ . @ -"
  fi
}

install_packages() {
  [[ "$INSTALL_DEPS" == "1" ]] || return 0

  local packages=(curl openssl iptables)
  [[ "$ENABLE_PANEL" == "1" ]] && packages+=(python3)

  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "${packages[@]}" ca-certificates
    if ! command -v netfilter-persistent >/dev/null 2>&1; then
      apt-get install -y netfilter-persistent iptables-persistent || true
    fi
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${packages[@]}" ca-certificates
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${packages[@]}" ca-certificates
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install "${packages[@]}" ca-certificates
  else
    yellow "未找到支持的包管理器；将假设 curl、openssl 和 iptables 已经存在。"
  fi
}

ensure_commands() {
  local missing=()
  local cmd

  for cmd in curl openssl iptables; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if [[ "$ENABLE_PANEL" == "1" ]]; then
    command -v python3 >/dev/null 2>&1 || missing+=(python3)
  fi

  if ((${#missing[@]} > 0)); then
    die "缺少必要命令：${missing[*]}"
  fi
}

random_hex() {
  openssl rand -hex 16
}

detect_public_ip() {
  if [[ -n "$SERVER_HOST" ]]; then
    printf '%s\n' "$SERVER_HOST"
    return 0
  fi

  local ip=""
  local url
  for url in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://checkip.amazonaws.com"; do
    ip="$(curl -4fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
  done

  ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "$ip" ]] || die "无法检测公网 IP；请使用 SERVER_HOST=你的域名或IP 重新运行"
  printf '%s\n' "$ip"
}

install_hysteria() {
  log "正在通过官方脚本安装或升级 Hysteria 2..."
  bash <(curl -fsSL "$HYSTERIA_INSTALL_URL")
  command -v hysteria >/dev/null 2>&1 || die "hysteria 程序未安装成功"
}

json_escape() {
  python3 - "$1" <<'PY'
import json
import sys

print(json.dumps(sys.argv[1]))
PY
}

reuse_existing_panel_password() {
  [[ -z "$PANEL_ADMIN_PASS" ]] || return 0
  [[ -f "$PANEL_ENV" ]] || return 0

  local existing
  existing="$(awk -F= '$1 == "PANEL_ADMIN_PASS" {print substr($0, index($0, "=") + 1)}' "$PANEL_ENV" | tail -1)"
  [[ -n "$existing" ]] || return 0
  PANEL_ADMIN_PASS="$existing"
}

write_panel_state() {
  local host="$1"
  local created
  local enable_obfs_json

  PANEL_ADMIN_PASS="${PANEL_ADMIN_PASS:-$(random_hex)}"
  INITIAL_USER_PASS="${INITIAL_USER_PASS:-$(random_hex)}"
  created="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  [[ "$ENABLE_OBFS" == "1" ]] && enable_obfs_json="true" || enable_obfs_json="false"

  mkdir -p "$CONFIG_DIR"

  if [[ ! -f "$USERS_FILE" ]]; then
    {
      printf '{\n'
      printf '  "users": [\n'
      printf '    {\n'
      printf '      "name": %s,\n' "$(json_escape "$INITIAL_USER")"
      printf '      "password": %s,\n' "$(json_escape "$INITIAL_USER_PASS")"
      printf '      "enabled": true,\n'
      printf '      "created_at": %s\n' "$(json_escape "$created")"
      printf '    }\n'
      printf '  ]\n'
      printf '}\n'
    } >"$USERS_FILE"
  fi

  {
    printf '{\n'
    printf '  "host": %s,\n' "$(json_escape "$host")"
    printf '  "port": %s,\n' "$PORT"
    printf '  "sni": %s,\n' "$(json_escape "$SNI")"
    printf '  "masquerade_url": %s,\n' "$(json_escape "$MASQUERADE_URL")"
    printf '  "enable_obfs": %s,\n' "$enable_obfs_json"
    printf '  "obfs_pass": %s,\n' "$(json_escape "$OBFS_PASS")"
    printf '  "tag": %s,\n' "$(json_escape "$TAG")"
    printf '  "cert_file": %s,\n' "$(json_escape "$CERT_FILE")"
    printf '  "key_file": %s\n' "$(json_escape "$KEY_FILE")"
    printf '}\n'
  } >"$SERVER_META_FILE"

  {
    printf 'CONFIG_DIR=%s\n' "$CONFIG_DIR"
    printf 'CONFIG_FILE=%s\n' "$CONFIG_FILE"
    printf 'USERS_FILE=%s\n' "$USERS_FILE"
    printf 'SERVER_META_FILE=%s\n' "$SERVER_META_FILE"
    printf 'CERT_FILE=%s\n' "$CERT_FILE"
    printf 'KEY_FILE=%s\n' "$KEY_FILE"
    printf 'PANEL_BIND=%s\n' "$PANEL_BIND"
    printf 'PANEL_PORT=%s\n' "$PANEL_PORT"
    printf 'PANEL_ADMIN_USER=%s\n' "$PANEL_ADMIN_USER"
    printf 'PANEL_ADMIN_PASS=%s\n' "$PANEL_ADMIN_PASS"
  } >"$PANEL_ENV"

  chmod 600 "$USERS_FILE" "$SERVER_META_FILE" "$PANEL_ENV"
}

install_panel() {
  [[ "$ENABLE_PANEL" == "1" ]] || return 0

  log "正在安装 Hysteria Web 管理面板..."
  mkdir -p "$PANEL_DIR"

  local script_dir=""
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd || true)"
  if [[ -n "$script_dir" && -f "$script_dir/panel.py" ]]; then
    cp "$script_dir/panel.py" "$PANEL_APP"
  else
    curl -fsSL "$PANEL_SOURCE_URL" -o "$PANEL_APP"
  fi

  chmod 755 "$PANEL_APP"

  cat >/etc/systemd/system/hysteria-panel.service <<EOF
[Unit]
Description=Hysteria 2 Web Panel
After=network-online.target hysteria-server.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$PANEL_ENV
ExecStart=/usr/bin/env python3 $PANEL_APP
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/hysteria-expire-users.service <<EOF
[Unit]
Description=Expire Hysteria 2 panel users
After=network-online.target hysteria-server.service
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$PANEL_ENV
ExecStart=/usr/bin/env python3 $PANEL_APP --expire-users
EOF

  cat >/etc/systemd/system/hysteria-expire-users.timer <<EOF
[Unit]
Description=Check Hysteria 2 user expiry times

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

run_panel_cli() {
  CONFIG_DIR="$CONFIG_DIR" \
  CONFIG_FILE="$CONFIG_FILE" \
  USERS_FILE="$USERS_FILE" \
  SERVER_META_FILE="$SERVER_META_FILE" \
  CERT_FILE="$CERT_FILE" \
  KEY_FILE="$KEY_FILE" \
  PANEL_ADMIN_USER="$PANEL_ADMIN_USER" \
  PANEL_ADMIN_PASS="$PANEL_ADMIN_PASS" \
  python3 "$PANEL_APP" "$@"
}

write_config() {
  local host="$1"

  AUTH_PASS="${AUTH_PASS:-$(random_hex)}"
  OBFS_PASS="${OBFS_PASS:-$(random_hex)}"

  mkdir -p "$CONFIG_DIR"

  log "正在为 SNI $SNI 生成自签证书..."
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -subj "/CN=$SNI" \
    -addext "subjectAltName=DNS:$SNI" >/dev/null 2>&1

  if [[ "$ENABLE_PANEL" == "1" ]]; then
    reuse_existing_panel_password
    write_panel_state "$host"
    install_panel
    log "正在写入多用户 Hysteria 服务端配置：$CONFIG_FILE"
    run_panel_cli --render >/dev/null
  else
    log "正在写入 Hysteria 服务端配置：$CONFIG_FILE"
    {
      printf 'listen: :%s\n\n' "$PORT"
      printf 'tls:\n'
      printf '  cert: %s\n' "$CERT_FILE"
      printf '  key: %s\n' "$KEY_FILE"
      printf '  sniGuard: disable\n\n'
      printf 'auth:\n'
      printf '  type: password\n'
      printf '  password: %s\n\n' "$AUTH_PASS"
      if [[ "$ENABLE_OBFS" == "1" ]]; then
        printf 'obfs:\n'
        printf '  type: salamander\n'
        printf '  salamander:\n'
        printf '    password: %s\n\n' "$OBFS_PASS"
      fi
      printf 'masquerade:\n'
      printf '  type: proxy\n'
      printf '  proxy:\n'
      printf '    url: %s\n' "$MASQUERADE_URL"
      printf '    rewriteHost: true\n'
    } >"$CONFIG_FILE"
  fi

  if id hysteria >/dev/null 2>&1; then
    chown hysteria:hysteria "$CERT_FILE" "$KEY_FILE"
    chown root:hysteria "$CONFIG_FILE"
  fi

  chmod 600 "$KEY_FILE"
  chmod 644 "$CERT_FILE"
  chmod 640 "$CONFIG_FILE"
}

iptables_insert_accept() {
  local bin="$1"
  iptables_insert_accept_rule "$bin" udp "$PORT"
}

iptables_insert_accept_rule() {
  local bin="$1"
  local proto="$2"
  local port="$3"
  local chain="INPUT"

  "$bin" -C "$chain" -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 && return 0

  local first_block_line=""
  first_block_line="$("$bin" -L "$chain" --line-numbers 2>/dev/null \
    | awk '/REJECT|DROP/ {print $1; exit}' || true)"

  if [[ "$first_block_line" =~ ^[0-9]+$ ]]; then
    "$bin" -I "$chain" "$first_block_line" -p "$proto" --dport "$port" -j ACCEPT
  else
    "$bin" -A "$chain" -p "$proto" --dport "$port" -j ACCEPT
  fi
}

save_iptables() {
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save || true
  elif command -v service >/dev/null 2>&1 && service iptables status >/dev/null 2>&1; then
    service iptables save || true
  elif [[ -d /etc/iptables ]] && command -v iptables-save >/dev/null 2>&1; then
    iptables-save >/etc/iptables/rules.v4 || true
    if command -v ip6tables-save >/dev/null 2>&1; then
      ip6tables-save >/etc/iptables/rules.v6 || true
    fi
  else
    yellow "无法自动持久化 iptables 规则；当前运行时防火墙已经更新。"
  fi
}

open_firewall() {
  [[ "$OPEN_FIREWALL" == "1" ]] || return 0

  log "正在放行 UDP 端口 $PORT..."

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    ufw allow "$PORT/udp"
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$PORT/udp"
    firewall-cmd --reload
  fi

  iptables_insert_accept iptables

  if command -v ip6tables >/dev/null 2>&1; then
    iptables_insert_accept ip6tables || true
  fi

  save_iptables
}

open_panel_firewall() {
  [[ "$ENABLE_PANEL" == "1" ]] || return 0
  [[ "$PANEL_OPEN_FIREWALL" == "1" ]] || return 0
  [[ "$PANEL_BIND" != "127.0.0.1" && "$PANEL_BIND" != "localhost" ]] || {
    yellow "已请求放行面板端口，但 PANEL_BIND=$PANEL_BIND 仅允许本机访问。"
    return 0
  }

  log "正在放行 Web 面板 TCP 端口 $PANEL_PORT..."

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    ufw allow "$PANEL_PORT/tcp"
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$PANEL_PORT/tcp"
    firewall-cmd --reload
  fi

  iptables_insert_accept_rule iptables tcp "$PANEL_PORT"

  if command -v ip6tables >/dev/null 2>&1; then
    iptables_insert_accept_rule ip6tables tcp "$PANEL_PORT" || true
  fi

  save_iptables
}

start_service() {
  log "正在启动 Hysteria 服务..."
  systemctl daemon-reload
  systemctl enable --now hysteria-server.service
  systemctl restart hysteria-server.service
  sleep 2
  systemctl is-active --quiet hysteria-server.service || {
    systemctl --no-pager --full status hysteria-server.service || true
    die "hysteria-server.service 未正常运行"
  }
}

start_panel_service() {
  [[ "$ENABLE_PANEL" == "1" ]] || return 0

  log "正在启动 Hysteria Web 管理面板..."
  systemctl daemon-reload
  systemctl enable --now hysteria-panel.service
  systemctl restart hysteria-panel.service
  systemctl enable --now hysteria-expire-users.timer
  sleep 1
  systemctl is-active --quiet hysteria-panel.service || {
    systemctl --no-pager --full status hysteria-panel.service || true
    die "hysteria-panel.service 未正常运行"
  }
  systemctl is-active --quiet hysteria-expire-users.timer || {
    systemctl --no-pager --full status hysteria-expire-users.timer || true
    die "hysteria-expire-users.timer 未正常运行"
  }
}

build_uri() {
  local host="$1"
  local user="${2:-}"
  local pass="${3:-$AUTH_PASS}"
  local fingerprint
  local uri
  local auth

  fingerprint="$(openssl x509 -noout -fingerprint -sha256 -in "$CERT_FILE" | cut -d= -f2)"
  if [[ -n "$user" ]]; then
    auth="${user}:${pass}"
  else
    auth="$pass"
  fi
  uri="hysteria2://${auth}@${host}:${PORT}/?insecure=1"

  if [[ "$ENABLE_OBFS" == "1" ]]; then
    uri="${uri}&obfs=salamander&obfs-password=${OBFS_PASS}"
  fi

  uri="${uri}&pinSHA256=${fingerprint}&sni=${SNI}#${TAG}"
  printf '%s\n' "$uri"
}

detect_cloud_provider() {
  local provider=""

  if curl -fsS --max-time 1 http://100.100.100.200/latest/meta-data/instance-id >/dev/null 2>&1; then
    provider="Alibaba Cloud"
  elif curl -fsS --max-time 1 http://169.254.169.254/opc/v1/instance/ >/dev/null 2>&1; then
    provider="Oracle Cloud"
  elif curl -fsS --max-time 1 -H "Metadata-Flavor: Google" \
    http://169.254.169.254/computeMetadata/v1/instance/id >/dev/null 2>&1; then
    provider="Google Cloud"
  elif curl -fsS --max-time 1 http://169.254.169.254/latest/meta-data/instance-id >/dev/null 2>&1; then
    provider="AWS-compatible cloud"
  fi

  printf '%s\n' "$provider"
}

print_cloud_firewall_notice() {
  local provider="$1"

  printf '\n'
  yellow "防火墙提示："
  printf '  服务器系统防火墙已经放行 UDP %s。\n' "$PORT"
  if [[ -n "$provider" ]]; then
    printf '  检测到 %s。你可能还需要在云安全组/云防火墙里放行 UDP %s。\n' "$provider" "$PORT"
  else
    printf '  如果客户端连接超时，请同时在云厂商安全组/防火墙里放行 UDP %s。\n' "$PORT"
  fi
}

print_summary() {
  local host="$1"
  local uri="$2"
  local provider="$3"

  green "Hysteria 2 已安装并正在运行。"
  printf '\n'
  printf '服务器：%s:%s/udp\n' "$host" "$PORT"
  printf '配置文件：%s\n' "$CONFIG_FILE"
  printf '服务：hysteria-server.service\n'
  printf '\n'
  printf '导入链接：\n'
  printf '%s\n' "$uri"
  if [[ "$ENABLE_PANEL" == "1" ]]; then
    printf '\n'
    printf 'Web 管理面板：\n'
    if [[ "$PANEL_BIND" == "127.0.0.1" || "$PANEL_BIND" == "localhost" ]]; then
      printf '  URL: http://127.0.0.1:%s\n' "$PANEL_PORT"
      printf '  SSH 隧道：ssh -L %s:127.0.0.1:%s root@%s\n' "$PANEL_PORT" "$PANEL_PORT" "$host"
    else
      printf '  URL: http://%s:%s\n' "$host" "$PANEL_PORT"
      printf '  安全组/防火墙：如果需要公网访问，请放行 TCP %s。\n' "$PANEL_PORT"
    fi
    printf '  用户名：%s\n' "$PANEL_ADMIN_USER"
    printf '  密码：%s\n' "$PANEL_ADMIN_PASS"
  fi
  printf '\n'
  printf '常用命令：\n'
  printf '  systemctl status hysteria-server.service\n'
  printf '  journalctl --no-pager -u hysteria-server.service -n 80\n'
  if [[ "$ENABLE_PANEL" == "1" ]]; then
    printf '  systemctl status hysteria-panel.service\n'
    printf '  systemctl status hysteria-expire-users.timer\n'
  fi
  print_cloud_firewall_notice "$provider"
}

main() {
  need_root
  require_systemd
  normalize_bool_vars
  configure_interactive
  normalize_bool_vars
  validate_port
  install_packages
  ensure_commands
  install_hysteria

  local host uri provider
  host="$(detect_public_ip)"

  write_config "$host"
  open_firewall
  open_panel_firewall
  start_service
  start_panel_service

  if [[ "$ENABLE_PANEL" == "1" ]]; then
    uri="$(run_panel_cli --print-uri "$INITIAL_USER" 2>/dev/null || true)"
    [[ -n "$uri" ]] || uri="$(build_uri "$host" "$INITIAL_USER" "$INITIAL_USER_PASS")"
  else
    uri="$(build_uri "$host")"
  fi
  provider="$(detect_cloud_provider)"
  print_summary "$host" "$uri" "$provider"
}

main "$@"
