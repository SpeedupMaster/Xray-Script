#!/usr/bin/env bash

set -u
umask 022
export LC_ALL=C

SCRIPT_VERSION="1.1.0"
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
SCRIPT_USR_PATH="/usr/bin/xray"
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
  printf '\n按 Enter 键继续...'
  read -r _
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    log_error "请使用 root 权限运行此脚本。"
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

ensure_systemd() {
  if ! command_exists systemctl; then
    log_error "当前系统缺少 systemd，无法继续。"
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
    log_error "暂不支持当前系统的包管理器。"
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
      log_error "暂不支持当前系统架构：$(uname -m)"
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

  log_info "正在下载 Xray ${version}，架构：${XRAY_ARCH} ..."
  if ! curl -fL --retry 3 --connect-timeout 15 -o "$zip_file" "$download_url"; then
    rm -rf "$tmp_dir"
    log_error "Xray 安装包下载失败。"
    return 1
  fi

  if ! unzip -oq "$zip_file" -d "$tmp_dir"; then
    rm -rf "$tmp_dir"
    log_error "Xray 安装包解压失败。"
    return 1
  fi

  if [ ! -f "${tmp_dir}/xray" ]; then
    rm -rf "$tmp_dir"
    log_error "安装包内未找到 Xray 可执行文件。"
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

  if [ -r "$source_file" ] && cat "$source_file" >"$tmp_file"; then
    :
  elif [ -n "${DEFAULT_SCRIPT_UPDATE_URL:-}" ] && curl -fsSL --connect-timeout 15 -o "$tmp_file" "$DEFAULT_SCRIPT_UPDATE_URL"; then
    log_warn "当前脚本源文件不可直接读取，已改为从默认更新地址写入管理脚本。"
  else
    rm -f "$tmp_file"
    log_warn "无法写入管理脚本到 ${destination}。"
    return 1
  fi

  install -m 755 "$tmp_file" "$destination"
  rm -f "$tmp_file"
}

write_management_wrapper() {
  local wrapper_path="$1"
  local tmp_file

  tmp_file="$(mktemp)"
  cat >"$tmp_file" <<EOF
#!/usr/bin/env bash
exec bash "${SCRIPT_BACKUP_PATH}" "\$@"
EOF
  install -m 755 "$tmp_file" "$wrapper_path"
  rm -f "$tmp_file"
}

install_shortcuts() {
  ensure_dirs
  copy_running_script_to "$SCRIPT_BACKUP_PATH" || return 1
  write_management_wrapper "$SCRIPT_INSTALL_PATH"
  if [ -d /usr/bin ]; then
    ln -sf "$SCRIPT_INSTALL_PATH" "$SCRIPT_USR_PATH"
  fi
  ln -sf "$XRAY_BIN" "$XRAY_BIN_LINK"
}

remove_management_shortcuts() {
  rm -f "$SCRIPT_INSTALL_PATH" "$SCRIPT_USR_PATH"
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
      log_warn "请输入 1 到 65535 之间的有效端口。"
      continue
    fi

    if port_is_listening "$entered_port"; then
      log_warn "端口 ${entered_port} 已被占用，继续使用可能会与其他服务冲突。"
      tty_printf '仍然使用端口 %s 吗？[y/N]: ' "$entered_port"
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
    tty_printf 'Reality SNI 域名（直接回车使用随机值：%s）：' "$suggested"
    read_tty_line
    entered_domain="${REPLY:-$suggested}"

    if ! validate_domain_format "$entered_domain"; then
      log_warn "域名格式不正确，请重新输入。"
      continue
    fi

    if ! validate_domain_resolution "$entered_domain"; then
      tty_printf '当前服务器无法解析该域名，是否仍然继续？[y/N]: '
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
    log_warn "xray x25519 生成密钥失败，已自动回退到 OpenSSL。原始输出：${XRAY_X25519_ERROR_OUTPUT}"
  else
    log_warn "xray x25519 生成密钥失败，已自动回退到 OpenSSL。"
  fi

  if generate_x25519_keys_with_openssl; then
    return 0
  fi

  log_error "生成 REALITY 密钥失败。"
  return 1
}

generate_uuid() {
  local uuid
  uuid="$("$XRAY_BIN" uuid 2>/dev/null | tr -d '\r\n')"
  if [ -z "$uuid" ]; then
    log_error "生成 UUID 失败。"
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

  log_error "Xray 配置校验失败。"
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
    log_info "Xray 服务运行正常。"
    return 0
  fi

  systemctl status xray --no-pager || true
  log_error "Xray 服务启动失败。"
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
    bbr_status="已启用"
  else
    bbr_status="未启用"
  fi

  if [ "$current_qdisc" = "fq" ]; then
    fq_status="已启用"
  else
    fq_status="未启用"
  fi

  if lsmod 2>/dev/null | awk '/^tcp_bbr/ {found=1} END {exit !found}'; then
    bbr_module_status="可见"
  else
    bbr_module_status="未显示或已内置"
  fi

  cat <<EOF
内核版本：$(uname -r)
当前拥塞控制：${current_cc} (${bbr_status})
当前队列调度：${current_qdisc} (${fq_status})
可用拥塞控制：${available_cc}
tcp_bbr 模块状态：${bbr_module_status}
配置文件：${BBR_SYSCTL_FILE}
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
    log_error "未找到安装状态文件。"
    return 1
  fi

  host="$(get_public_ip || true)"
  host="${host:-${SERVER_IP:-<your_server_ip>}}"
  service_state="$(systemctl is-active xray 2>/dev/null || printf 'inactive')"
  xray_version="$(current_xray_version || true)"
  xray_version="${xray_version:-unknown}"

  {
    echo "Xray 管理脚本"
    echo "脚本版本：${SCRIPT_VERSION}"
    echo "Xray 版本：${xray_version}"
    echo "服务状态：${service_state}"
    echo "服务器 IP：${host}"
    echo

    if [ "${INSTALL_VLESS:-no}" = "yes" ]; then
      echo "[VLESS + REALITY]"
      echo "地址：${host}"
      echo "端口：${REALITY_PORT}"
      echo "UUID: ${REALITY_UUID}"
      echo "Flow：xtls-rprx-vision"
      echo "安全类型：reality"
      echo "SNI: ${REALITY_SNI}"
      echo "公钥：${REALITY_PUBLIC_KEY}"
      echo "Short ID：${REALITY_SHORT_ID}"
      echo "指纹：chrome"
      echo "分享链接："
      build_vless_link "$host"
      echo
    fi

    if [ "${INSTALL_SS:-no}" = "yes" ]; then
      echo "[Shadowsocks]"
      echo "地址：${host}"
      echo "端口：${SS_PORT}"
      echo "加密方式：${SS_METHOD}"
      echo "密码：${SS_PASSWORD}"
      echo "分享链接："
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
请选择安装协议：
  1) 仅安装 VLESS + REALITY
  2) 仅安装 Shadowsocks
  3) 同时安装两者
EOF
    printf '请输入选项 [3]: '
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
        log_warn "输入无效，请重新选择。"
        ;;
    esac
  done
}

install_flow() {
  local latest_version installed_version skip_existing_prompt

  require_root
  ensure_systemd
  install_dependencies
  ensure_dirs

  skip_existing_prompt="${1:-}"

  if [ "$skip_existing_prompt" != "skip-existing-check" ] && [ -f "$STATE_FILE" ]; then
    printf '检测到已有安装记录，是否备份后覆盖安装？[y/N]: '
    read -r overwrite_answer
    case "${overwrite_answer:-n}" in
      y|Y|yes|YES)
        backup_current_files
        ;;
      *)
        log_info "已取消安装。"
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
    REALITY_PORT="$(prompt_port 'Reality 监听端口' "$DEFAULT_REALITY_PORT")"
    REALITY_SNI="$(prompt_sni_domain)"
  fi

  if [ "$INSTALL_SS" = "yes" ]; then
    SS_PORT="$(prompt_port 'Shadowsocks 监听端口' "$DEFAULT_SS_PORT")"
  fi

  if [ "$INSTALL_VLESS" = "yes" ] && [ "$INSTALL_SS" = "yes" ] && [ "$REALITY_PORT" = "$SS_PORT" ]; then
    log_error "Reality 与 Shadowsocks 不能使用同一个监听端口。"
    return 1
  fi

  latest_version="$(get_latest_release_tag || true)"
  if [ -z "$latest_version" ]; then
    log_error "获取最新 Xray 版本失败。"
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
  if ! install_shortcuts; then
    log_error "安装快捷管理命令失败。"
    return 1
  fi
  if ! write_state_file; then
    log_error "写入状态文件失败。"
    return 1
  fi

  if ! restart_xray_service; then
    return 1
  fi

  log_info "安装完成。"
  log_info "管理快捷命令：xray"
  log_info "若当前会话仍提示找不到 xray，请重新登录终端后再试。"
  echo
  show_bbr_fq_status
  echo
  generate_node_info
}

restart_flow() {
  require_root
  ensure_systemd

  if [ ! -f "$SERVICE_FILE" ]; then
    log_error "未找到 Xray 服务文件。"
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
    log_error "当前未安装 Xray。"
    return 1
  fi

  current_version="$(current_xray_version || true)"
  latest_version="$(get_latest_release_tag || true)"

  if [ -z "$latest_version" ]; then
    log_error "获取最新 Xray 版本失败。"
    return 1
  fi

  if [ "$current_version" = "$latest_version" ]; then
    log_info "当前 Xray 已是最新版本（${current_version}）。"
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
  log_info "Xray 已从 ${current_version:-unknown} 更新到 ${latest_version}。"
}

change_sni_flow() {
  require_root

  if ! load_state; then
    log_error "未找到安装状态文件。"
    return 1
  fi

  if [ "${INSTALL_VLESS:-no}" != "yes" ]; then
    log_error "当前未安装 VLESS + REALITY。"
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

remove_xray_components() {
  local keep_manager="${1:-no}"

  stop_xray_service
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload || true

  rm -rf "$INSTALL_DIR"
  rm -f "$XRAY_BIN_LINK"
  rm -rf "$CONFIG_DIR"
  rm -f "$BBR_SYSCTL_FILE" "$BBR_MODULE_FILE"
  try_restore_network_defaults

  if [ "$keep_manager" = "yes" ]; then
    rm -f "$STATE_FILE" "$NODE_INFO_FILE"
    mkdir -p "${STATE_DIR}/backups"
  else
    remove_management_shortcuts
    rm -rf "$STATE_DIR"
  fi
}

reinstall_flow() {
  require_root
  ensure_systemd

  if [ ! -f "$STATE_FILE" ] && [ ! -x "$XRAY_BIN" ] && [ ! -f "$CONFIG_FILE" ]; then
    log_warn "当前未检测到已安装的 Xray 环境，将直接进入安装流程。"
    install_flow
    return $?
  fi

  printf '将重新安装 Xray、配置与节点信息，是否继续？[y/N]: '
  read -r reinstall_answer
  case "${reinstall_answer:-n}" in
    y|Y|yes|YES)
      ;;
    *)
      log_info "已取消重新安装。"
      return 0
      ;;
  esac

  backup_current_files
  remove_xray_components "yes"
  install_flow "skip-existing-check"
}

uninstall_flow() {
  require_root
  ensure_systemd

  printf '将卸载 Xray、配置、服务、快捷命令以及脚本写入的 BBR/FQ 配置，是否继续？[y/N]: '
  read -r remove_answer
  case "${remove_answer:-n}" in
    y|Y|yes|YES)
      ;;
    *)
      log_info "已取消卸载。"
      return 0
      ;;
  esac

  remove_xray_components

  log_info "卸载完成。"
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

  printf '请输入脚本更新地址'
  if [ -n "$current_url" ]; then
    printf ' [%s]' "$current_url"
  fi
  printf ': '
  read -r input_url
  input_url="${input_url:-$current_url}"

  if [ -z "$input_url" ]; then
    log_error "未提供脚本更新地址。"
    return 1
  fi

  tmp_file="$(mktemp)"
  if ! curl -fL --retry 3 --connect-timeout 15 -o "$tmp_file" "$input_url"; then
    rm -f "$tmp_file"
    log_error "从 ${input_url} 下载脚本失败。"
    return 1
  fi

  if ! grep -q 'SCRIPT_VERSION=' "$tmp_file"; then
    rm -f "$tmp_file"
    log_error "下载的文件不是有效的 xray 管理脚本。"
    return 1
  fi

  install -m 755 "$tmp_file" "$SCRIPT_BACKUP_PATH"
  write_management_wrapper "$SCRIPT_INSTALL_PATH"
  if [ -d /usr/bin ]; then
    ln -sf "$SCRIPT_INSTALL_PATH" "$SCRIPT_USR_PATH"
  fi
  rm -f "$tmp_file"

  if load_state; then
    SCRIPT_UPDATE_URL="$input_url"
    write_state_file
  fi

  log_info "脚本更新完成。请重新执行 xray 命令使用新版本。"
}

show_info_flow() {
  generate_node_info
}

print_help() {
  cat <<EOF
用法：
  $(basename "$0")                打开交互式菜单
  $(basename "$0") install        安装 Xray 与代理协议
  $(basename "$0") reinstall      重新安装 Xray 与代理协议
  $(basename "$0") uninstall      卸载 Xray 与脚本生成的文件
  $(basename "$0") update         更新 Xray 内核
  $(basename "$0") restart        重启 Xray 服务
  $(basename "$0") info           查看节点信息
  $(basename "$0") change-sni     更换 Reality SNI 域名
  $(basename "$0") check-bbr      检查 BBR + FQ 状态
  $(basename "$0") update-script  更新管理脚本
  $(basename "$0") help           显示帮助信息
EOF
}

main_menu() {
  while true; do
    clear 2>/dev/null || true
    cat <<EOF
========================================
 Xray 管理脚本 ${SCRIPT_VERSION}
========================================
 1) 安装
 2) 重新安装
 3) 卸载
 4) 更新 Xray 内核
 5) 重启 Xray
 6) 查看节点信息
 7) 更换 Reality SNI
 8) 检查 BBR + FQ 状态
  9) 更新脚本
  0) 退出
========================================
EOF
    printf '请选择功能：'

    local choice
    read -r choice

    echo
    case "$choice" in
      1)
        install_flow
        ;;
      2)
        reinstall_flow
        ;;
      3)
        uninstall_flow
        ;;
      4)
        update_xray_flow
        ;;
      5)
        restart_flow
        ;;
      6)
        show_info_flow
        ;;
      7)
        change_sni_flow
        ;;
      8)
        check_bbr_flow
        ;;
      9)
        update_script_flow
        ;;
      0)
        exit 0
        ;;
      *)
        log_warn "菜单选项无效，请重新输入。"
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
    reinstall)
      reinstall_flow
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
      log_error "未知命令：$1"
      print_help
      exit 1
      ;;
  esac
}

main "$@"
