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
PANEL_BIND="${PANEL_BIND:-127.0.0.1}"
PANEL_PORT="${PANEL_PORT:-8080}"
PANEL_ADMIN_USER="${PANEL_ADMIN_USER:-admin}"
PANEL_ADMIN_PASS="${PANEL_ADMIN_PASS:-}"
PANEL_OPEN_FIREWALL="${PANEL_OPEN_FIREWALL:-0}"
PANEL_DIR="${PANEL_DIR:-/opt/hysteria2-onekey}"
PANEL_APP="${PANEL_APP:-$PANEL_DIR/panel.py}"
PANEL_ENV="${PANEL_ENV:-$CONFIG_DIR/panel.env}"
PANEL_SOURCE_URL="${PANEL_SOURCE_URL:-https://raw.githubusercontent.com/1660667086/hysteria2-onekey/main/panel.py}"
USERS_FILE="${USERS_FILE:-$CONFIG_DIR/users.json}"
SERVER_META_FILE="${SERVER_META_FILE:-$CONFIG_DIR/server.json}"
INITIAL_USER="${INITIAL_USER:-user1}"
INITIAL_USER_PASS="${INITIAL_USER_PASS:-}"

red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
log() { printf '[%s] %s\n' "$SCRIPT_NAME" "$*"; }
die() { red "ERROR: $*"; exit 1; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "please run as root"
  fi
}

require_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found; this installer requires systemd"
}

validate_port() {
  [[ "$PORT" =~ ^[0-9]+$ ]] || die "PORT must be a number"
  (( PORT >= 1 && PORT <= 65535 )) || die "PORT must be between 1 and 65535"

  if [[ "$ENABLE_PANEL" == "1" ]]; then
    [[ "$PANEL_PORT" =~ ^[0-9]+$ ]] || die "PANEL_PORT must be a number"
    (( PANEL_PORT >= 1 && PANEL_PORT <= 65535 )) || die "PANEL_PORT must be between 1 and 65535"
    [[ "$INITIAL_USER" =~ ^[A-Za-z0-9_.@-]{1,64}$ ]] || die "INITIAL_USER must be 1-64 chars: letters, numbers, _ . @ -"
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
    yellow "No supported package manager found; assuming curl, openssl and iptables already exist."
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
    die "missing required command(s): ${missing[*]}"
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
  [[ -n "$ip" ]] || die "could not detect public IP; rerun with SERVER_HOST=your.domain.or.ip"
  printf '%s\n' "$ip"
}

install_hysteria() {
  log "Installing or upgrading Hysteria 2 from official script..."
  bash <(curl -fsSL "$HYSTERIA_INSTALL_URL")
  command -v hysteria >/dev/null 2>&1 || die "hysteria binary was not installed"
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

  log "Installing Hysteria web panel..."
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

  log "Generating self-signed certificate for SNI $SNI..."
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -subj "/CN=$SNI" \
    -addext "subjectAltName=DNS:$SNI" >/dev/null 2>&1

  if [[ "$ENABLE_PANEL" == "1" ]]; then
    reuse_existing_panel_password
    write_panel_state "$host"
    install_panel
    log "Writing multi-user Hysteria server config to $CONFIG_FILE..."
    run_panel_cli --render >/dev/null
  else
    log "Writing Hysteria server config to $CONFIG_FILE..."
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
    yellow "Could not persist iptables automatically. The current runtime firewall was updated."
  fi
}

open_firewall() {
  [[ "$OPEN_FIREWALL" == "1" ]] || return 0

  log "Opening UDP port $PORT..."

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
    yellow "Panel firewall was requested, but PANEL_BIND=$PANEL_BIND is local-only."
    return 0
  }

  log "Opening TCP panel port $PANEL_PORT..."

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
  log "Starting Hysteria service..."
  systemctl daemon-reload
  systemctl enable --now hysteria-server.service
  systemctl restart hysteria-server.service
  sleep 2
  systemctl is-active --quiet hysteria-server.service || {
    systemctl --no-pager --full status hysteria-server.service || true
    die "hysteria-server.service is not active"
  }
}

start_panel_service() {
  [[ "$ENABLE_PANEL" == "1" ]] || return 0

  log "Starting Hysteria web panel..."
  systemctl daemon-reload
  systemctl enable --now hysteria-panel.service
  systemctl restart hysteria-panel.service
  sleep 1
  systemctl is-active --quiet hysteria-panel.service || {
    systemctl --no-pager --full status hysteria-panel.service || true
    die "hysteria-panel.service is not active"
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
  yellow "Firewall note:"
  printf '  The server OS firewall has been opened for UDP %s.\n' "$PORT"
  if [[ -n "$provider" ]]; then
    printf '  Detected %s. You may still need to open UDP %s in the cloud security group/firewall.\n' "$provider" "$PORT"
  else
    printf '  If clients time out, also open UDP %s in your cloud provider security group/firewall.\n' "$PORT"
  fi
}

print_summary() {
  local host="$1"
  local uri="$2"
  local provider="$3"

  green "Hysteria 2 is installed and running."
  printf '\n'
  printf 'Server: %s:%s/udp\n' "$host" "$PORT"
  printf 'Config: %s\n' "$CONFIG_FILE"
  printf 'Service: hysteria-server.service\n'
  printf '\n'
  printf 'Import link:\n'
  printf '%s\n' "$uri"
  if [[ "$ENABLE_PANEL" == "1" ]]; then
    printf '\n'
    printf 'Web panel:\n'
    if [[ "$PANEL_BIND" == "127.0.0.1" || "$PANEL_BIND" == "localhost" ]]; then
      printf '  URL: http://127.0.0.1:%s\n' "$PANEL_PORT"
      printf '  SSH tunnel: ssh -L %s:127.0.0.1:%s root@%s\n' "$PANEL_PORT" "$PANEL_PORT" "$host"
    else
      printf '  URL: http://%s:%s\n' "$host" "$PANEL_PORT"
      printf '  Security group/firewall: open TCP %s if accessing from the internet.\n' "$PANEL_PORT"
    fi
    printf '  Username: %s\n' "$PANEL_ADMIN_USER"
    printf '  Password: %s\n' "$PANEL_ADMIN_PASS"
  fi
  printf '\n'
  printf 'Useful commands:\n'
  printf '  systemctl status hysteria-server.service\n'
  printf '  journalctl --no-pager -u hysteria-server.service -n 80\n'
  if [[ "$ENABLE_PANEL" == "1" ]]; then
    printf '  systemctl status hysteria-panel.service\n'
  fi
  print_cloud_firewall_notice "$provider"
}

main() {
  need_root
  require_systemd
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
