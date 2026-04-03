#!/usr/bin/env bash

set -u
umask 022
export LC_ALL=C

SCRIPT_VERSION="1.0.2"
DEFAULT_SCRIPT_UPDATE_URL="${XRAY_SCRIPT_URL:-https://raw.githubusercontent.com/SpeedupMaster/Xray-Script/main/xray-manager.sh}"

INSTALL_DIR="/usr/local/xray"
XRAY_BIN="${INSTALL_DIR}/xray"
XRAY_BIN_LINK="/usr/local/bin/xray-core"
CONFIG_DIR="/etc/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
STATE_DIR="/etc/xray-manager"
STATE_FILE="${STATE_DIR}/agent.conf"
NODE_INFO_FILE="${STATE_DIR}/node-info.txt"
SCRIPT_INSTALL_PATH="/usr/local/bin/xray"
SCRIPT_BACKUP_PATH="${STATE_DIR}/xray-manager.sh"
SERVICE_FILE="/etc/systemd/system/xray.service"
BBR_SYSCTL_FILE="/etc/sysctl.d/99-xray-bbr-fq.conf"
BBR_MODULE_FILE="/etc/modules-load.d/xray-bbr.conf"
LOG_DIR="/var/log/xray"

DEFAULT_REALITY_PORT="443"
DEFAULT_SS_PORT="8388"
DEFAULT_SS_METHOD="2022-blake3-aes-256-gcm"
STATE_MARKER="managed-by-xray-manager"

DEFAULT_SNI_DOMAINS=(
  "gateway.icloud.com"
  "itunes.apple.com"
  "swdist.apple.com"
  "swcdn.apple.com"
  "updates.cdn-apple.com"
  "mensura.cdn-apple.com"
  "osxapps.itunes.apple.com"
  "aod.itunes.apple.com"
  "download-installer.cdn.mozilla.net"
  "addons.mozilla.org"
  "s0.awsstatic.com"
  "d1.awsstatic.com"
  "cdn-dynmedia-1.microsoft.com"
  "www.cloudflare.com"
  "images-na.ssl-images-amazon.com"
  "m.media-amazon.com"
  "dl.google.com"
  "www.google-analytics.com"
  "www.microsoft.com"
  "software.download.prss.microsoft.com"
  "player.live-video.net"
  "one-piece.com"
  "lol.secure.dyn.riotcdn.net"
  "www.lovelive-anime.jp"
  "www.swift.com"
  "academy.nvidia.com"
  "www.cisco.com"
  "www.samsung.com"
  "www.amd.com"
)

log_info() {
  printf '[INFO] %s\n' "$*"
}

log_warn() {
  printf '[WARN] %s\n' "$*" >&2
}

log_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

tty_printf() {
  if [ -e /dev/tty ] && [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf "$@" >/dev/tty
  else
    printf "$@" >&2
  fi
}

read_tty_line() {
  if [ -e /dev/tty ] && [ -r /dev/tty ]; then
    IFS= read -r REPLY </dev/tty
  else
    IFS= read -r REPLY
  fi
}

pause_screen() {
  printf '\nPress Enter to continue...'
  read -r _
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    log_error "Please run this script as root."
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

ensure_systemd() {
  if ! command_exists systemctl; then
    log_error "systemd is required."
    exit 1
  fi
}

detect_package_manager() {
  if command_exists apt-get; then
    PKG_MANAGER="apt"
  elif command_exists dnf; then
    PKG_MANAGER="dnf"
  elif command_exists yum; then
    PKG_MANAGER="yum"
  elif command_exists zypper; then
    PKG_MANAGER="zypper"
  elif command_exists pacman; then
    PKG_MANAGER="pacman"
  else
    log_error "Unsupported package manager."
    exit 1
  fi
}

install_dependencies() {
  detect_package_manager
  case "$PKG_MANAGER" in
    apt)
      apt-get update
      apt-get install -y --no-install-recommends curl unzip openssl ca-certificates iproute2 procps coreutils sed grep gawk
      ;;
    dnf)
      dnf -y install curl unzip openssl ca-certificates iproute procps-ng coreutils sed grep gawk
      ;;
    yum)
      yum -y install curl unzip openssl ca-certificates iproute procps-ng coreutils sed grep gawk
      ;;
    zypper)
      zypper --non-interactive install curl unzip openssl ca-certificates iproute2 procps coreutils sed grep gawk
      ;;
    pacman)
      pacman -Sy --noconfirm curl unzip openssl ca-certificates iproute2 procps-ng coreutils sed grep gawk
      ;;
  esac
}

ensure_dirs() {
  mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR" "${STATE_DIR}/backups"
}

detect_arch() {
  case "$(uname -m)" in
    i386|i686)
      XRAY_ARCH="32"
      ;;
    amd64|x86_64)
      XRAY_ARCH="64"
      ;;
    armv5tel)
      XRAY_ARCH="arm32-v5"
      ;;
    armv6l)
      XRAY_ARCH="arm32-v6"
      ;;
    armv7|armv7l)
      XRAY_ARCH="arm32-v7a"
      ;;
    armv8|aarch64)
      XRAY_ARCH="arm64-v8a"
      ;;
    mips)
      XRAY_ARCH="mips32"
      ;;
    mipsle)
      XRAY_ARCH="mips32le"
      ;;
    mips64)
      if command_exists lscpu && lscpu | grep -q "Little Endian"; then
        XRAY_ARCH="mips64le"
      else
        XRAY_ARCH="mips64"
      fi
      ;;
    mips64le)
      XRAY_ARCH="mips64le"
      ;;
    ppc64)
      XRAY_ARCH="ppc64"
      ;;
    ppc64le)
      XRAY_ARCH="ppc64le"
      ;;
    riscv64)
      XRAY_ARCH="riscv64"
      ;;
    s390x)
      XRAY_ARCH="s390x"
      ;;
    *)
      log_error "Unsupported architecture: $(uname -m)"
      exit 1
      ;;
  esac
}

version_lt() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" != "$2" ]
}

get_latest_release_tag() {
  local effective_url tag
  effective_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/XTLS/Xray-core/releases/latest 2>/dev/null || true)"
  tag="${effective_url##*/}"
  if [[ "$tag" =~ ^v[0-9] ]]; then
    printf '%s\n' "$tag"
    return 0
  fi

  tag="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  if [[ "$tag" =~ ^v[0-9] ]]; then
    printf '%s\n' "$tag"
    return 0
  fi

  return 1
}

current_xray_version() {
  local version
  if [ -x "$XRAY_BIN" ]; then
    version="$("$XRAY_BIN" version 2>/dev/null | awk 'NR==1 {print $2}')"
    if [ -n "$version" ]; then
      printf 'v%s\n' "${version#v}"
    fi
  fi
}

download_and_install_xray() {
  local version="$1"
  local tmp_dir zip_file download_url

  detect_arch
  ensure_dirs
  tmp_dir="$(mktemp -d)"
  zip_file="${tmp_dir}/xray.zip"
  download_url="https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${XRAY_ARCH}.zip"

  log_info "Downloading Xray ${version} for ${XRAY_ARCH}..."
  if ! curl -fL --retry 3 --connect-timeout 15 -o "$zip_file" "$download_url"; then
    rm -rf "$tmp_dir"
    log_error "Failed to download Xray package."
    return 1
  fi

  if ! unzip -oq "$zip_file" -d "$tmp_dir"; then
    rm -rf "$tmp_dir"
    log_error "Failed to extract Xray package."
    return 1
  fi

  if [ ! -f "${tmp_dir}/xray" ]; then
    rm -rf "$tmp_dir"
    log_error "Xray binary was not found in the package."
    return 1
  fi

  install -m 755 "${tmp_dir}/xray" "$XRAY_BIN"
  if [ -f "${tmp_dir}/geoip.dat" ]; then
    install -m 644 "${tmp_dir}/geoip.dat" "${INSTALL_DIR}/geoip.dat"
  fi
  if [ -f "${tmp_dir}/geosite.dat" ]; then
    install -m 644 "${tmp_dir}/geosite.dat" "${INSTALL_DIR}/geosite.dat"
  fi

  ln -sf "$XRAY_BIN" "$XRAY_BIN_LINK"
  rm -rf "$tmp_dir"
  return 0
}

copy_running_script_to() {
  local destination="$1"
  local tmp_file source_file

  source_file="${BASH_SOURCE[0]}"
  tmp_file="$(mktemp)"

  if ! cat "$source_file" >"$tmp_file"; then
    rm -f "$tmp_file"
    log_warn "Unable to copy the running script to ${destination}."
    return 1
  fi

  install -m 755 "$tmp_file" "$destination"
  rm -f "$tmp_file"
}

install_shortcuts() {
  ensure_dirs
  copy_running_script_to "$SCRIPT_INSTALL_PATH" || true
  copy_running_script_to "$SCRIPT_BACKUP_PATH" || true
  ln -sf "$XRAY_BIN" "$XRAY_BIN_LINK"
}

backup_current_files() {
  local backup_dir timestamp
  timestamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="${STATE_DIR}/backups/${timestamp}"

  mkdir -p "$backup_dir"
  [ -f "$CONFIG_FILE" ] && cp -a "$CONFIG_FILE" "${backup_dir}/config.json"
  [ -f "$STATE_FILE" ] && cp -a "$STATE_FILE" "${backup_dir}/agent.conf"
  [ -f "$SERVICE_FILE" ] && cp -a "$SERVICE_FILE" "${backup_dir}/xray.service"
  [ -x "$XRAY_BIN" ] && cp -a "$XRAY_BIN" "${backup_dir}/xray.bin"
}

safe_write_kv() {
  printf '%s=%q\n' "$1" "$2"
}

load_state() {
  local runtime_script_version runtime_state_marker

  if [ ! -f "$STATE_FILE" ]; then
    return 1
  fi

  runtime_script_version="$SCRIPT_VERSION"
  runtime_state_marker="$STATE_MARKER"

  # shellcheck disable=SC1090
  source "$STATE_FILE"
  SCRIPT_VERSION="$runtime_script_version"
  STATE_MARKER="$runtime_state_marker"
  return 0
}

write_state_file() {
  ensure_dirs
  {
    safe_write_kv MANAGER_MARKER "$STATE_MARKER"
    safe_write_kv INSTALLED_SCRIPT_VERSION "$SCRIPT_VERSION"
    safe_write_kv SCRIPT_UPDATE_URL "${SCRIPT_UPDATE_URL:-}"
    safe_write_kv XRAY_VERSION "${XRAY_VERSION:-}"
    safe_write_kv SERVER_IP "${SERVER_IP:-}"
    safe_write_kv INSTALL_MODE "${INSTALL_MODE:-}"
    safe_write_kv INSTALL_VLESS "${INSTALL_VLESS:-no}"
    safe_write_kv INSTALL_SS "${INSTALL_SS:-no}"
    safe_write_kv REALITY_PORT "${REALITY_PORT:-}"
    safe_write_kv REALITY_SNI "${REALITY_SNI:-}"
    safe_write_kv REALITY_UUID "${REALITY_UUID:-}"
    safe_write_kv REALITY_PRIVATE_KEY "${REALITY_PRIVATE_KEY:-}"
    safe_write_kv REALITY_PUBLIC_KEY "${REALITY_PUBLIC_KEY:-}"
    safe_write_kv REALITY_SHORT_ID "${REALITY_SHORT_ID:-}"
    safe_write_kv SS_PORT "${SS_PORT:-}"
    safe_write_kv SS_METHOD "${SS_METHOD:-}"
    safe_write_kv SS_PASSWORD "${SS_PASSWORD:-}"
    safe_write_kv INSTALLED_AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

port_is_valid() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

port_is_listening() {
  local port="$1"
  if ! command_exists ss; then
    return 1
  fi
  ss -lntupH 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}$"
}

prompt_port() {
  local prompt_text="$1"
  local default_port="$2"
  local entered_port reuse_answer

  while true; do
    tty_printf '%s [%s]: ' "$prompt_text" "$default_port"
    read_tty_line
    entered_port="${REPLY:-$default_port}"

    if ! port_is_valid "$entered_port"; then
      log_warn "Please enter a valid port between 1 and 65535."
      continue
    fi

    if port_is_listening "$entered_port"; then
      log_warn "Port ${entered_port} is already in use. Reusing it may fail if another service owns it."
      tty_printf 'Continue with port %s? [y/N]: ' "$entered_port"
      read_tty_line
      reuse_answer="${REPLY:-}"
      case "${reuse_answer:-n}" in
        y|Y|yes|YES)
          printf '%s\n' "$entered_port"
          return 0
          ;;
      esac
      continue
    fi

    printf '%s\n' "$entered_port"
    return 0
  done
}

get_random_sni() {
  local idx
  idx=$((RANDOM % ${#DEFAULT_SNI_DOMAINS[@]}))
  printf '%s\n' "${DEFAULT_SNI_DOMAINS[$idx]}"
}

validate_domain_format() {
  local domain="$1"
  [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] && [[ "$domain" == *.* ]]
}

validate_domain_resolution() {
  local domain="$1"
  if command_exists getent; then
    getent ahosts "$domain" >/dev/null 2>&1
  else
    return 0
  fi
}

prompt_sni_domain() {
  local suggested entered_domain resolve_answer
  suggested="$(get_random_sni)"

  while true; do
    tty_printf 'Reality SNI domain (press Enter for random: %s): ' "$suggested"
    read_tty_line
    entered_domain="${REPLY:-$suggested}"

    if ! validate_domain_format "$entered_domain"; then
      log_warn "Invalid domain format."
      continue
    fi

    if ! validate_domain_resolution "$entered_domain"; then
      tty_printf 'The domain does not appear to resolve on this server. Continue anyway? [y/N]: '
      read_tty_line
      resolve_answer="${REPLY:-}"
      case "${resolve_answer:-n}" in
        y|Y|yes|YES)
          printf '%s\n' "$entered_domain"
          return 0
          ;;
        *)
          suggested="$(get_random_sni)"
          continue
          ;;
      esac
    fi

    printf '%s\n' "$entered_domain"
    return 0
  done
}

is_valid_x25519_key() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{43}$ ]]
}

base64url_encode_file() {
  openssl base64 -A <"$1" | tr '+/' '-_' | tr -d '=\r\n'
}

generate_x25519_keys_with_xray() {
  local output status private_key public_key

  output="$("$XRAY_BIN" x25519 2>&1)"
  status=$?
  private_key="$(printf '%s\n' "$output" | awk -F':[[:space:]]*' 'tolower($1) ~ /private key/ {print $2; exit}' | tr -d '\r\n')"
  public_key="$(printf '%s\n' "$output" | awk -F':[[:space:]]*' 'tolower($1) ~ /public key/ {print $2; exit}' | tr -d '\r\n')"

  if [ "$status" -ne 0 ]; then
    XRAY_X25519_ERROR_OUTPUT="$output"
    return 1
  fi

  if ! is_valid_x25519_key "$private_key" || ! is_valid_x25519_key "$public_key"; then
    XRAY_X25519_ERROR_OUTPUT="$output"
    return 1
  fi

  REALITY_PRIVATE_KEY="$private_key"
  REALITY_PUBLIC_KEY="$public_key"
  return 0
}

generate_x25519_keys_with_openssl() {
  local tmp_dir private_pem private_raw public_raw private_key public_key

  tmp_dir="$(mktemp -d)" || return 1
  private_pem="${tmp_dir}/x25519.pem"
  private_raw="${tmp_dir}/x25519.private.raw"
  public_raw="${tmp_dir}/x25519.public.raw"

  if ! openssl genpkey -algorithm X25519 -out "$private_pem" >/dev/null 2>&1; then
    rm -rf "$tmp_dir"
    return 1
  fi

  if ! openssl pkey -in "$private_pem" -outform DER 2>/dev/null | tail -c 32 >"$private_raw"; then
    rm -rf "$tmp_dir"
    return 1
  fi

  if ! openssl pkey -in "$private_pem" -pubout -outform DER 2>/dev/null | tail -c 32 >"$public_raw"; then
    rm -rf "$tmp_dir"
    return 1
  fi

  if [ "$(wc -c <"$private_raw" | tr -d '[:space:]')" != "32" ] || [ "$(wc -c <"$public_raw" | tr -d '[:space:]')" != "32" ]; then
    rm -rf "$tmp_dir"
    return 1
  fi

  private_key="$(base64url_encode_file "$private_raw")"
  public_key="$(base64url_encode_file "$public_raw")"
  rm -rf "$tmp_dir"

  if ! is_valid_x25519_key "$private_key" || ! is_valid_x25519_key "$public_key"; then
    return 1
  fi

  REALITY_PRIVATE_KEY="$private_key"
  REALITY_PUBLIC_KEY="$public_key"
  return 0
}

generate_x25519_keys() {
  XRAY_X25519_ERROR_OUTPUT=""

  if generate_x25519_keys_with_xray; then
    return 0
  fi

  if [ -n "${XRAY_X25519_ERROR_OUTPUT:-}" ]; then
    log_warn "xray x25519 failed, falling back to OpenSSL. Raw output: ${XRAY_X25519_ERROR_OUTPUT}"
  else
    log_warn "xray x25519 failed, falling back to OpenSSL."
  fi

  if generate_x25519_keys_with_openssl; then
    return 0
  fi

  log_error "Failed to generate REALITY keys."
  return 1
}

generate_uuid() {
  local uuid
  uuid="$("$XRAY_BIN" uuid 2>/dev/null | tr -d '\r\n')"
  if [ -z "$uuid" ]; then
    log_error "Failed to generate UUID."
    return 1
  fi
  REALITY_UUID="$uuid"
}

generate_short_id() {
  REALITY_SHORT_ID="$(openssl rand -hex 8 | tr -d '\r\n')"
}

generate_ss_password() {
  SS_PASSWORD="$(openssl rand -base64 32 | tr -d '\r\n')"
}

urlencode_userinfo() {
  local input="$1"
  local i char encoded=""

  for ((i=0; i<${#input}; i++)); do
    char="${input:i:1}"
    case "$char" in
      [a-zA-Z0-9.~_-])
        encoded+="$char"
        ;;
      *)
        printf -v encoded '%s%%%02X' "$encoded" "'$char"
        ;;
    esac
  done

  printf '%s\n' "$encoded"
}

build_vless_inbound() {
  cat <<EOF
{
  "tag": "vless-reality",
  "listen": "0.0.0.0",
  "port": ${REALITY_PORT},
  "protocol": "vless",
  "settings": {
    "clients": [
      {
        "id": "${REALITY_UUID}",
        "flow": "xtls-rprx-vision",
        "email": "vless-reality@xray"
      }
    ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "raw",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "target": "${REALITY_SNI}:443",
      "xver": 0,
      "serverNames": [
        "${REALITY_SNI}"
      ],
      "privateKey": "${REALITY_PRIVATE_KEY}",
      "shortIds": [
        "${REALITY_SHORT_ID}"
      ]
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": [
      "http",
      "tls",
      "quic"
    ]
  }
}
EOF
}

build_ss_inbound() {
  cat <<EOF
{
  "tag": "ss-2022",
  "listen": "0.0.0.0",
  "port": ${SS_PORT},
  "protocol": "shadowsocks",
  "settings": {
    "network": "tcp,udp",
    "method": "${SS_METHOD}",
    "password": "${SS_PASSWORD}"
  },
  "sniffing": {
    "enabled": true,
    "destOverride": [
      "http",
      "tls",
      "quic"
    ]
  }
}
EOF
}

write_config() {
  ensure_dirs
  {
    echo '{'
    echo '  "log": {'
    echo '    "loglevel": "warning"'
    echo '  },'
    echo '  "inbounds": ['

    local first=1

    if [ "${INSTALL_VLESS:-no}" = "yes" ]; then
      if [ "$first" -eq 0 ]; then
        echo '    ,'
      fi
      build_vless_inbound | sed 's/^/    /'
      first=0
    fi

    if [ "${INSTALL_SS:-no}" = "yes" ]; then
      if [ "$first" -eq 0 ]; then
        echo '    ,'
      fi
      build_ss_inbound | sed 's/^/    /'
      first=0
    fi

    echo '  ],'
    echo '  "outbounds": ['
    echo '    {'
    echo '      "tag": "direct",'
    echo '      "protocol": "freedom"'
    echo '    },'
    echo '    {'
    echo '      "tag": "block",'
    echo '      "protocol": "blackhole"'
    echo '    }'
    echo '  ]'
    echo '}'
  } >"$CONFIG_FILE"
}

validate_config() {
  if "$XRAY_BIN" -test -config "$CONFIG_FILE" >/dev/null 2>&1; then
    return 0
  fi

  if "$XRAY_BIN" run -test -config "$CONFIG_FILE" >/dev/null 2>&1; then
    return 0
  fi

  log_error "Xray configuration validation failed."
  return 1
}

write_service_file() {
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Xray Service managed by xray-manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=${XRAY_BIN} run -config ${CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3
LimitNOFILE=51200
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
}

restart_xray_service() {
  systemctl daemon-reload
  if systemctl is-enabled xray >/dev/null 2>&1; then
    systemctl restart xray
  else
    systemctl enable --now xray
  fi

  if systemctl is-active --quiet xray; then
    log_info "Xray service is running."
    return 0
  fi

  systemctl status xray --no-pager || true
  log_error "Xray service failed to start."
  return 1
}

stop_xray_service() {
  systemctl disable --now xray >/dev/null 2>&1 || true
}

apply_bbr_fq() {
  cat >"$BBR_MODULE_FILE" <<'EOF'
tcp_bbr
sch_fq
EOF

  cat >"$BBR_SYSCTL_FILE" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

  modprobe sch_fq >/dev/null 2>&1 || true
  modprobe tcp_bbr >/dev/null 2>&1 || true
  sysctl --system >/dev/null 2>&1 || sysctl -p "$BBR_SYSCTL_FILE" >/dev/null 2>&1 || true
}

show_bbr_fq_status() {
  local current_cc current_qdisc available_cc bbr_status fq_status bbr_module_status

  current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 'unknown')"
  current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || printf 'unknown')"
  available_cc="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || printf 'unknown')"

  if [ "$current_cc" = "bbr" ]; then
    bbr_status="enabled"
  else
    bbr_status="disabled"
  fi

  if [ "$current_qdisc" = "fq" ]; then
    fq_status="enabled"
  else
    fq_status="disabled"
  fi

  if lsmod 2>/dev/null | awk '/^tcp_bbr/ {found=1} END {exit !found}'; then
    bbr_module_status="yes"
  else
    bbr_module_status="no or built-in"
  fi

  cat <<EOF
Kernel: $(uname -r)
Current congestion control: ${current_cc} (${bbr_status})
Current qdisc: ${current_qdisc} (${fq_status})
Available congestion control: ${available_cc}
tcp_bbr module visible: ${bbr_module_status}
Config file: ${BBR_SYSCTL_FILE}
EOF
}

try_restore_network_defaults() {
  local available_cc
  available_cc="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if printf '%s\n' "$available_cc" | grep -qw cubic; then
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
  fi
  sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true
}

is_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

get_public_ip() {
  local ip url
  for url in \
    "https://api64.ipify.org" \
    "https://ipv4.icanhazip.com" \
    "https://ifconfig.me/ip"
  do
    ip="$(curl -4fsSL --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if is_ipv4 "$ip"; then
      printf '%s\n' "$ip"
      return 0
    fi
  done

  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if is_ipv4 "$ip"; then
    printf '%s\n' "$ip"
    return 0
  fi

  return 1
}

build_vless_link() {
  local host="$1"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#XRAY-VLESS-REALITY\n' \
    "$REALITY_UUID" "$host" "$REALITY_PORT" "$REALITY_SNI" "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID"
}

build_ss_link() {
  local host="$1"
  local userinfo

  if [[ "$SS_METHOD" == 2022-* ]]; then
    userinfo="$(urlencode_userinfo "${SS_METHOD}:${SS_PASSWORD}")"
  else
    userinfo="$(printf '%s' "${SS_METHOD}:${SS_PASSWORD}" | base64 | tr -d '\r\n' | tr '+/' '-_' | tr -d '=')"
  fi

  printf 'ss://%s@%s:%s#XRAY-SS-2022\n' "$userinfo" "$host" "$SS_PORT"
}

generate_node_info() {
  local host service_state xray_version

  if ! load_state; then
    log_error "No installation state was found."
    return 1
  fi

  host="$(get_public_ip || true)"
  host="${host:-${SERVER_IP:-<your_server_ip>}}"
  service_state="$(systemctl is-active xray 2>/dev/null || printf 'inactive')"
  xray_version="$(current_xray_version || true)"
  xray_version="${xray_version:-unknown}"

  {
    echo "Xray Manager"
    echo "Script version: ${SCRIPT_VERSION}"
    echo "Xray version: ${xray_version}"
    echo "Service status: ${service_state}"
    echo "Server IP: ${host}"
    echo

    if [ "${INSTALL_VLESS:-no}" = "yes" ]; then
      echo "[VLESS + REALITY]"
      echo "Address: ${host}"
      echo "Port: ${REALITY_PORT}"
      echo "UUID: ${REALITY_UUID}"
      echo "Flow: xtls-rprx-vision"
      echo "Security: reality"
      echo "SNI: ${REALITY_SNI}"
      echo "Public Key: ${REALITY_PUBLIC_KEY}"
      echo "Short ID: ${REALITY_SHORT_ID}"
      echo "Fingerprint: chrome"
      echo "Share Link:"
      build_vless_link "$host"
      echo
    fi

    if [ "${INSTALL_SS:-no}" = "yes" ]; then
      echo "[Shadowsocks]"
      echo "Address: ${host}"
      echo "Port: ${SS_PORT}"
      echo "Method: ${SS_METHOD}"
      echo "Password: ${SS_PASSWORD}"
      echo "Share Link:"
      build_ss_link "$host"
      echo
    fi
  } | tee "$NODE_INFO_FILE"

  return 0
}

choose_install_mode() {
  local choice

  while true; do
    cat <<'EOF'
Select install mode:
  1) VLESS + REALITY
  2) Shadowsocks
  3) Both
EOF
    printf 'Choice [3]: '
    read -r choice
    choice="${choice:-3}"

    case "$choice" in
      1|vless|VLESS)
        INSTALL_MODE="vless"
        INSTALL_VLESS="yes"
        INSTALL_SS="no"
        return 0
        ;;
      2|ss|SS)
        INSTALL_MODE="ss"
        INSTALL_VLESS="no"
        INSTALL_SS="yes"
        return 0
        ;;
      3|both|BOTH)
        INSTALL_MODE="both"
        INSTALL_VLESS="yes"
        INSTALL_SS="yes"
        return 0
        ;;
      *)
        log_warn "Invalid choice."
        ;;
    esac
  done
}

install_flow() {
  local latest_version installed_version

  require_root
  ensure_systemd
  install_dependencies
  ensure_dirs

  if [ -f "$STATE_FILE" ]; then
    printf 'An existing xray-manager installation was found. Backup and overwrite it? [y/N]: '
    read -r overwrite_answer
    case "${overwrite_answer:-n}" in
      y|Y|yes|YES)
        backup_current_files
        ;;
      *)
        log_info "Installation cancelled."
        return 0
        ;;
    esac
  fi

  choose_install_mode

  REALITY_PORT=""
  REALITY_SNI=""
  REALITY_UUID=""
  REALITY_PRIVATE_KEY=""
  REALITY_PUBLIC_KEY=""
  REALITY_SHORT_ID=""
  SS_PORT=""
  SS_METHOD="$DEFAULT_SS_METHOD"
  SS_PASSWORD=""

  if [ "$INSTALL_VLESS" = "yes" ]; then
    REALITY_PORT="$(prompt_port 'Reality listen port' "$DEFAULT_REALITY_PORT")"
    REALITY_SNI="$(prompt_sni_domain)"
  fi

  if [ "$INSTALL_SS" = "yes" ]; then
    SS_PORT="$(prompt_port 'Shadowsocks listen port' "$DEFAULT_SS_PORT")"
  fi

  if [ "$INSTALL_VLESS" = "yes" ] && [ "$INSTALL_SS" = "yes" ] && [ "$REALITY_PORT" = "$SS_PORT" ]; then
    log_error "Reality and Shadowsocks cannot listen on the same port."
    return 1
  fi

  latest_version="$(get_latest_release_tag || true)"
  if [ -z "$latest_version" ]; then
    log_error "Failed to detect the latest Xray version."
    return 1
  fi

  if ! download_and_install_xray "$latest_version"; then
    return 1
  fi

  installed_version="$(current_xray_version || true)"
  XRAY_VERSION="${installed_version:-$latest_version}"
  SERVER_IP="$(get_public_ip || true)"
  SCRIPT_UPDATE_URL="${DEFAULT_SCRIPT_UPDATE_URL:-}"

  if [ "$INSTALL_VLESS" = "yes" ]; then
    generate_x25519_keys || return 1
    generate_uuid || return 1
    generate_short_id
  fi

  if [ "$INSTALL_SS" = "yes" ]; then
    generate_ss_password
  fi

  write_config
  if ! validate_config; then
    return 1
  fi

  write_service_file
  apply_bbr_fq
  install_shortcuts
  if ! write_state_file; then
    log_error "Failed to write state file."
    return 1
  fi

  if ! restart_xray_service; then
    return 1
  fi

  log_info "Installation completed."
  echo
  show_bbr_fq_status
  echo
  generate_node_info
}

restart_flow() {
  require_root
  ensure_systemd

  if [ ! -f "$SERVICE_FILE" ]; then
    log_error "Xray service file was not found."
    return 1
  fi

  restart_xray_service
}

update_xray_flow() {
  local current_version latest_version

  require_root
  ensure_systemd
  install_dependencies

  if [ ! -x "$XRAY_BIN" ]; then
    log_error "Xray is not installed."
    return 1
  fi

  current_version="$(current_xray_version || true)"
  latest_version="$(get_latest_release_tag || true)"

  if [ -z "$latest_version" ]; then
    log_error "Failed to detect the latest Xray version."
    return 1
  fi

  if [ "$current_version" = "$latest_version" ]; then
    log_info "Xray is already up to date (${current_version})."
    return 0
  fi

  backup_current_files
  if ! download_and_install_xray "$latest_version"; then
    return 1
  fi

  if load_state; then
    XRAY_VERSION="$(current_xray_version || true)"
    write_state_file
  fi

  if [ -f "$CONFIG_FILE" ] && ! validate_config; then
    return 1
  fi

  restart_xray_service
  log_info "Xray updated from ${current_version:-unknown} to ${latest_version}."
}

change_sni_flow() {
  require_root

  if ! load_state; then
    log_error "No installation state was found."
    return 1
  fi

  if [ "${INSTALL_VLESS:-no}" != "yes" ]; then
    log_error "VLESS + REALITY is not installed."
    return 1
  fi

  backup_current_files
  REALITY_SNI="$(prompt_sni_domain)"
  write_config

  if ! validate_config; then
    return 1
  fi

  write_state_file
  restart_xray_service || return 1
  generate_node_info
}

check_bbr_flow() {
  show_bbr_fq_status
}

uninstall_flow() {
  require_root
  ensure_systemd

  printf 'This will remove Xray, config, service, shortcuts and BBR/FQ config written by this script. Continue? [y/N]: '
  read -r remove_answer
  case "${remove_answer:-n}" in
    y|Y|yes|YES)
      ;;
    *)
      log_info "Uninstall cancelled."
      return 0
      ;;
  esac

  stop_xray_service
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload || true

  rm -rf "$INSTALL_DIR"
  rm -f "$XRAY_BIN_LINK"
  rm -rf "$CONFIG_DIR"
  rm -f "$BBR_SYSCTL_FILE" "$BBR_MODULE_FILE"
  try_restore_network_defaults
  rm -f "$SCRIPT_INSTALL_PATH"
  rm -rf "$STATE_DIR"

  log_info "Uninstall completed."
}

update_script_flow() {
  local current_url input_url tmp_file

  require_root
  ensure_dirs

  if load_state; then
    current_url="${SCRIPT_UPDATE_URL:-${DEFAULT_SCRIPT_UPDATE_URL:-}}"
  else
    current_url="${DEFAULT_SCRIPT_UPDATE_URL:-}"
  fi

  printf 'Raw script URL for update'
  if [ -n "$current_url" ]; then
    printf ' [%s]' "$current_url"
  fi
  printf ': '
  read -r input_url
  input_url="${input_url:-$current_url}"

  if [ -z "$input_url" ]; then
    log_error "No script update URL was provided."
    return 1
  fi

  tmp_file="$(mktemp)"
  if ! curl -fL --retry 3 --connect-timeout 15 -o "$tmp_file" "$input_url"; then
    rm -f "$tmp_file"
    log_error "Failed to download the script from ${input_url}."
    return 1
  fi

  if ! grep -q 'SCRIPT_VERSION=' "$tmp_file"; then
    rm -f "$tmp_file"
    log_error "Downloaded file does not look like a valid xray-manager script."
    return 1
  fi

  install -m 755 "$tmp_file" "$SCRIPT_INSTALL_PATH"
  install -m 755 "$tmp_file" "$SCRIPT_BACKUP_PATH"
  rm -f "$tmp_file"

  if load_state; then
    SCRIPT_UPDATE_URL="$input_url"
    write_state_file
  fi

  log_info "Script updated successfully. Run 'xray' again to use the new version."
}

show_info_flow() {
  generate_node_info
}

print_help() {
  cat <<EOF
Usage:
  $(basename "$0")                Open interactive menu
  $(basename "$0") install        Install Xray and proxy protocols
  $(basename "$0") uninstall      Remove Xray and generated files
  $(basename "$0") update         Update Xray core
  $(basename "$0") restart        Restart Xray service
  $(basename "$0") info           Show node information
  $(basename "$0") change-sni     Change Reality SNI domain
  $(basename "$0") check-bbr      Check BBR + FQ status
  $(basename "$0") update-script  Update this management script
  $(basename "$0") help           Show this help
EOF
}

main_menu() {
  while true; do
    clear 2>/dev/null || true
    cat <<EOF
========================================
 Xray Manager ${SCRIPT_VERSION}
========================================
 1) Install
 2) Uninstall
 3) Update Xray core
 4) Restart Xray
 5) Show node info
 6) Change Reality SNI
 7) Check BBR + FQ status
 8) Update script
 0) Exit
========================================
EOF
    printf 'Select an option: '

    local choice
    read -r choice

    echo
    case "$choice" in
      1)
        install_flow
        ;;
      2)
        uninstall_flow
        ;;
      3)
        update_xray_flow
        ;;
      4)
        restart_flow
        ;;
      5)
        show_info_flow
        ;;
      6)
        change_sni_flow
        ;;
      7)
        check_bbr_flow
        ;;
      8)
        update_script_flow
        ;;
      0)
        exit 0
        ;;
      *)
        log_warn "Invalid option."
        ;;
    esac

    echo
    pause_screen
  done
}

main() {
  case "${1:-menu}" in
    install)
      install_flow
      ;;
    uninstall|remove)
      uninstall_flow
      ;;
    update)
      update_xray_flow
      ;;
    restart)
      restart_flow
      ;;
    info)
      show_info_flow
      ;;
    change-sni)
      change_sni_flow
      ;;
    check-bbr|bbr)
      check_bbr_flow
      ;;
    update-script)
      update_script_flow
      ;;
    help|-h|--help)
      print_help
      ;;
    menu)
      main_menu
      ;;
    *)
      log_error "Unknown command: $1"
      print_help
      exit 1
      ;;
  esac
}

main "$@"
