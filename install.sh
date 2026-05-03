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
}

install_packages() {
  [[ "$INSTALL_DEPS" == "1" ]] || return 0

  local packages=(curl openssl iptables)

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

write_config() {
  AUTH_PASS="${AUTH_PASS:-$(random_hex)}"
  OBFS_PASS="${OBFS_PASS:-$(random_hex)}"

  mkdir -p "$CONFIG_DIR"

  log "Generating self-signed certificate for SNI $SNI..."
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -subj "/CN=$SNI" \
    -addext "subjectAltName=DNS:$SNI" >/dev/null 2>&1

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
  local chain="INPUT"

  "$bin" -C "$chain" -p udp --dport "$PORT" -j ACCEPT >/dev/null 2>&1 && return 0

  local first_block_line=""
  first_block_line="$("$bin" -L "$chain" --line-numbers 2>/dev/null \
    | awk '/REJECT|DROP/ {print $1; exit}' || true)"

  if [[ "$first_block_line" =~ ^[0-9]+$ ]]; then
    "$bin" -I "$chain" "$first_block_line" -p udp --dport "$PORT" -j ACCEPT
  else
    "$bin" -A "$chain" -p udp --dport "$PORT" -j ACCEPT
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

build_uri() {
  local host="$1"
  local fingerprint
  local uri

  fingerprint="$(openssl x509 -noout -fingerprint -sha256 -in "$CERT_FILE" | cut -d= -f2)"
  uri="hysteria2://${AUTH_PASS}@${host}:${PORT}/?insecure=1"

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
  printf '\n'
  printf 'Useful commands:\n'
  printf '  systemctl status hysteria-server.service\n'
  printf '  journalctl --no-pager -u hysteria-server.service -n 80\n'
  print_cloud_firewall_notice "$provider"
}

main() {
  need_root
  require_systemd
  validate_port
  install_packages
  ensure_commands
  install_hysteria
  write_config
  open_firewall
  start_service

  local host uri provider
  host="$(detect_public_ip)"
  uri="$(build_uri "$host")"
  provider="$(detect_cloud_provider)"
  print_summary "$host" "$uri" "$provider"
}

main "$@"
