#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="hysteria2-uninstall"
HYSTERIA_INSTALL_URL="${HYSTERIA_INSTALL_URL:-https://get.hy2.sh/}"
CONFIG_DIR="${CONFIG_DIR:-/etc/hysteria}"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/config.yaml}"
SERVER_META_FILE="${SERVER_META_FILE:-$CONFIG_DIR/server.json}"
PANEL_ENV="${PANEL_ENV:-$CONFIG_DIR/panel.env}"
PANEL_DIR="${PANEL_DIR:-/opt/hysteria2-onekey}"
INTERACTIVE="${INTERACTIVE:-auto}"
YES="${YES:-0}"
PURGE_CONFIG="${PURGE_CONFIG:-0}"
REMOVE_FIREWALL="${REMOVE_FIREWALL:-1}"
RUN_OFFICIAL_REMOVE="${RUN_OFFICIAL_REMOVE:-1}"
CONFIG_BACKUP_DIR=""

red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
log() { printf '[%s] %s\n' "$SCRIPT_NAME" "$*"; }
die() { red "错误：$*"; exit 1; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "请使用 root 用户运行"
  fi
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

bool_value() {
  local value
  value="$(lower "$1")"
  case "$value" in
    1|true|yes|y|on|enable|enabled)
      printf '1\n'
      ;;
    0|false|no|n|off|disable|disabled)
      printf '0\n'
      ;;
    *)
      return 1
      ;;
  esac
}

normalize_bool_vars() {
  YES="$(bool_value "$YES")" || die "YES 必须是 1 或 0"
  PURGE_CONFIG="$(bool_value "$PURGE_CONFIG")" || die "PURGE_CONFIG 必须是 1 或 0"
  REMOVE_FIREWALL="$(bool_value "$REMOVE_FIREWALL")" || die "REMOVE_FIREWALL 必须是 1 或 0"
  RUN_OFFICIAL_REMOVE="$(bool_value "$RUN_OFFICIAL_REMOVE")" || die "RUN_OFFICIAL_REMOVE 必须是 1 或 0"
}

prompt_enabled() {
  local value
  value="$(lower "$INTERACTIVE")"
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

    normalized="$(lower "$answer")"
    case "$normalized" in
      1|true|yes|y|on)
        printf -v "$var_name" '1'
        return 0
        ;;
      0|false|no|n|off)
        printf -v "$var_name" '0'
        return 0
        ;;
      *)
        printf '请输入 y 或 n。\n' >/dev/tty
        ;;
    esac
  done
}

confirm_uninstall() {
  if [[ "$YES" == "1" ]]; then
    return 0
  fi

  prompt_enabled || die "非交互模式下请设置 YES=1 才能卸载"

  printf '\n此脚本将卸载 Hysteria 2，并停止 Web 面板和到期检查定时器。\n' >/dev/tty
  printf '默认会保留 %s 里的配置、证书和用户数据。\n\n' "$CONFIG_DIR" >/dev/tty

  local confirm="0"
  prompt_yes_no confirm "确认继续卸载" "$confirm"
  [[ "$confirm" == "1" ]] || die "已取消卸载"

  prompt_yes_no PURGE_CONFIG "是否同时删除配置、证书和用户数据目录 $CONFIG_DIR" "$PURGE_CONFIG"
  prompt_yes_no REMOVE_FIREWALL "是否删除脚本添加的系统防火墙端口规则" "$REMOVE_FIREWALL"
}

backup_config_if_needed() {
  [[ "$PURGE_CONFIG" == "0" ]] || return 0
  [[ -d "$CONFIG_DIR" ]] || return 0

  CONFIG_BACKUP_DIR="$(mktemp -d)"
  cp -a "$CONFIG_DIR" "$CONFIG_BACKUP_DIR/hysteria"
}

restore_config_backup() {
  [[ -n "$CONFIG_BACKUP_DIR" ]] || return 0
  [[ -d "$CONFIG_BACKUP_DIR/hysteria" ]] || return 0

  rm -rf "$CONFIG_DIR"
  cp -a "$CONFIG_BACKUP_DIR/hysteria" "$CONFIG_DIR"
  rm -rf "$CONFIG_BACKUP_DIR"
  CONFIG_BACKUP_DIR=""
}

read_panel_port() {
  [[ -f "$PANEL_ENV" ]] || return 0
  awk -F= '$1 == "PANEL_PORT" {print $2; exit}' "$PANEL_ENV" 2>/dev/null || true
}

read_hysteria_port() {
  if [[ -f "$SERVER_META_FILE" ]]; then
    awk -F: '/"port"[[:space:]]*:/ {gsub(/[^0-9]/, "", $2); print $2; exit}' "$SERVER_META_FILE" 2>/dev/null || true
    return 0
  fi

  if [[ -f "$CONFIG_FILE" ]]; then
    awk '$1 == "listen:" {gsub(/^:/, "", $2); gsub(/[^0-9]/, "", $2); print $2; exit}' "$CONFIG_FILE" 2>/dev/null || true
  fi
}

stop_services() {
  log "正在停止并禁用服务..."
  systemctl disable --now hysteria-expire-users.timer >/dev/null 2>&1 || true
  systemctl disable --now hysteria-expire-users.service >/dev/null 2>&1 || true
  systemctl disable --now hysteria-panel.service >/dev/null 2>&1 || true
  systemctl disable --now hysteria-server.service >/dev/null 2>&1 || true
}

remove_official_hysteria() {
  [[ "$RUN_OFFICIAL_REMOVE" == "1" ]] || return 0

  log "正在调用 Hysteria 官方卸载脚本..."
  if command -v curl >/dev/null 2>&1; then
    bash <(curl -fsSL "$HYSTERIA_INSTALL_URL") --remove || yellow "官方卸载脚本执行失败，继续清理本脚本安装的文件。"
  else
    yellow "未找到 curl，跳过官方卸载脚本。"
  fi
}

remove_systemd_units() {
  log "正在删除 systemd 单元..."
  rm -f \
    /etc/systemd/system/hysteria-panel.service \
    /etc/systemd/system/hysteria-expire-users.service \
    /etc/systemd/system/hysteria-expire-users.timer

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed >/dev/null 2>&1 || true
}

remove_iptables_rule() {
  local bin="$1"
  local proto="$2"
  local port="$3"

  command -v "$bin" >/dev/null 2>&1 || return 0
  [[ -n "$port" ]] || return 0

  while "$bin" -C INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1; do
    "$bin" -D INPUT -p "$proto" --dport "$port" -j ACCEPT || break
  done
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
  fi
}

remove_firewall_rules() {
  [[ "$REMOVE_FIREWALL" == "1" ]] || return 0

  local hysteria_port="$1"
  local panel_port="$2"

  log "正在删除系统防火墙端口规则..."

  if [[ -n "$hysteria_port" ]] && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    ufw --force delete allow "$hysteria_port/udp" >/dev/null 2>&1 || true
  fi
  if [[ -n "$panel_port" ]] && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    ufw --force delete allow "$panel_port/tcp" >/dev/null 2>&1 || true
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    [[ -n "$hysteria_port" ]] && firewall-cmd --permanent --remove-port="$hysteria_port/udp" >/dev/null 2>&1 || true
    [[ -n "$panel_port" ]] && firewall-cmd --permanent --remove-port="$panel_port/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi

  remove_iptables_rule iptables udp "$hysteria_port"
  remove_iptables_rule iptables tcp "$panel_port"
  remove_iptables_rule ip6tables udp "$hysteria_port"
  remove_iptables_rule ip6tables tcp "$panel_port"
  save_iptables
}

remove_files() {
  log "正在删除面板程序目录..."
  rm -rf "$PANEL_DIR"

  if [[ "$PURGE_CONFIG" == "1" ]]; then
    log "正在删除配置目录：$CONFIG_DIR"
    rm -rf "$CONFIG_DIR"
  else
    yellow "已保留配置目录：$CONFIG_DIR"
  fi
}

print_summary() {
  green "卸载完成。"
  printf '\n'
  if [[ "$PURGE_CONFIG" == "1" ]]; then
    printf '配置目录已删除：%s\n' "$CONFIG_DIR"
  else
    printf '配置目录已保留：%s\n' "$CONFIG_DIR"
    printf '如需彻底删除，可重新运行：PURGE_CONFIG=1 YES=1 bash uninstall.sh\n'
  fi
  printf '提示：云厂商安全组规则无法由脚本删除，需要在云控制台手动检查。\n'
}

main() {
  need_root
  normalize_bool_vars
  confirm_uninstall

  local hysteria_port panel_port
  hysteria_port="$(read_hysteria_port | tail -1)"
  panel_port="$(read_panel_port | tail -1)"

  backup_config_if_needed
  stop_services
  remove_official_hysteria
  restore_config_backup
  remove_systemd_units
  remove_firewall_rules "$hysteria_port" "$panel_port"
  remove_files
  print_summary
}

main "$@"
