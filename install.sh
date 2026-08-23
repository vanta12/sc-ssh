#!/usr/bin/env bash
# ============================================================
# VPN SSH AUTO INSTALLER
# Bootstrap remote modules, then run setup 01 through 06.
# ============================================================

set -euo pipefail
IFS=$'\n\t'
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none

# BASH_SOURCE is unset when this file is interpreted from stdin by curl | bash.
SCRIPT_SOURCE="${BASH_SOURCE[0]-}"
if [ -z "$SCRIPT_SOURCE" ]; then
    SCRIPT_SOURCE="${0:-install.sh}"
fi
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" 2>/dev/null && pwd || printf '%s' /tmp)"
AUTOSCRIPT_ROOT="${AUTOSCRIPT_ROOT:-/opt/autoscript}"
case "$AUTOSCRIPT_ROOT" in
    /opt/autoscript) ;;
    *) printf '[ERROR] AUTOSCRIPT_ROOT harus /opt/autoscript\n' >&2; exit 1 ;;
esac
REPO_REF="8c5840bfd9a5f009ef73118eb052add87a2e75fc"
REPO_RAW_BASE="https://raw.githubusercontent.com/vanta12/sc-ssh/${REPO_REF}"
RUNTIME_DIR="${AUTOSCRIPT_ROOT}/runtime"
LIB_DIR="${RUNTIME_DIR}/lib"
SRC_DIR="${RUNTIME_DIR}/src"
BIN_DIR="${RUNTIME_DIR}/bin"
BADVPN_SHA256="428be8f53df491db903a9e22e52e7b58d658aeb07e98f044057cd0c38aec9211"

bootstrap_die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

bootstrap_download() {
    local remote_path="$1"
    local destination="$2"
    mkdir -p "$(dirname "$destination")"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --connect-timeout 15 \
            "${REPO_RAW_BASE}/${remote_path}" -o "$destination" ||
            bootstrap_die "Gagal mengunduh ${remote_path}"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --tries=3 --timeout=15 \
            "${REPO_RAW_BASE}/${remote_path}" -O "$destination" ||
            bootstrap_die "Gagal mengunduh ${remote_path}"
    else
        bootstrap_die "Butuh curl atau wget untuk mengunduh installer dari GitHub"
    fi

    [ -s "$destination" ] || bootstrap_die "File unduhan kosong: ${remote_path}"
}

bootstrap_runtime() {
    printf '[INFO] Downloading installer runtime to %s\n' "$RUNTIME_DIR"
    mkdir -p "$LIB_DIR" "$SRC_DIR" "$BIN_DIR"

    bootstrap_download "SHA256SUMS" "${RUNTIME_DIR}/SHA256SUMS"
    bootstrap_download "lib/common.sh" "${LIB_DIR}/common.sh"
    bootstrap_download "lib/01-dropbear.sh" "${LIB_DIR}/01-dropbear.sh"
    bootstrap_download "lib/02-badvpn.sh" "${LIB_DIR}/02-badvpn.sh"
    bootstrap_download "lib/03-haproxy.sh" "${LIB_DIR}/03-haproxy.sh"
    bootstrap_download "lib/04-ws-tunnel.sh" "${LIB_DIR}/04-ws-tunnel.sh"
    bootstrap_download "lib/05-firewall.sh" "${LIB_DIR}/05-firewall.sh"
    bootstrap_download "lib/06-users.sh" "${LIB_DIR}/06-users.sh"
    bootstrap_download "src/ws-tunnel.py" "${SRC_DIR}/ws-tunnel.py"
    bootstrap_download "src/haproxy.cfg.tpl" "${SRC_DIR}/haproxy.cfg.tpl"
    bootstrap_download "bin/badvpn-udpgw" "${BIN_DIR}/badvpn-udpgw"

    chmod 755 "${LIB_DIR}"/*.sh "${SRC_DIR}/ws-tunnel.py" "${BIN_DIR}/badvpn-udpgw"
    chmod 644 "${SRC_DIR}/haproxy.cfg.tpl"

    (cd "$RUNTIME_DIR" && sha256sum -c --strict SHA256SUMS) ||
        bootstrap_die "Checksum runtime tidak cocok"

    case "$(uname -m)" in
        x86_64|amd64) ;;
        *) bootstrap_die "Binary badvpn-udpgw tersedia untuk x86_64/amd64 saja" ;;
    esac

    local actual_sha256
    actual_sha256="$(sha256sum "${BIN_DIR}/badvpn-udpgw" | awk '{print $1}')"
    [ "$actual_sha256" = "$BADVPN_SHA256" ] ||
        bootstrap_die "Checksum badvpn-udpgw tidak cocok"

    printf '[INFO] Runtime download complete\n'
}

if [ "${EUID}" -ne 0 ]; then
    bootstrap_die "Jalankan sebagai root: sudo bash install.sh"
fi

bootstrap_runtime
export AUTOSCRIPT_BADVPN_BINARY="${BIN_DIR}/badvpn-udpgw"
export AUTOSCRIPT_WS_SOURCE="${SRC_DIR}/ws-tunnel.py"
export AUTOSCRIPT_HAPROXY_TEMPLATE="${SRC_DIR}/haproxy.cfg.tpl"
export AUTOSCRIPT_USER_HELPER="${LIB_DIR}/06-users.sh"
export AUTOSCRIPT_COMMON_HELPER="${LIB_DIR}/common.sh"

cleanup_runtime() {
    local exit_code=$?
    if [ "$exit_code" -ne 0 ] && [ "${AUTOSCRIPT_INSTALL_ACTIVE:-false}" = true ]; then
        rollback_install || true
    fi
    cleanup
    exit "$exit_code"
}

export AUTOSCRIPT_ROOT
source "${LIB_DIR}/common.sh"
trap cleanup_runtime EXIT

DROPBEAR_PORT=143
BADVPN_START=7300
WS_PORT=8880
HAPROXY_PORT_80=80
HAPROXY_PORT_443=443
DOMAIN=""

must_be_root
setup_log
acquire_lock
AUTOSCRIPT_INSTALL_ACTIVE=true
check_internet || warn "Tidak ada internet — beberapa fitur mungkin gagal"
detect_os

DOMAIN=""
if [ -r /dev/tty ]; then
    read -rp "Domain (kosong = self-signed): " DOMAIN </dev/tty || DOMAIN=""
fi
if [ -n "$DOMAIN" ] && ! validate_fqdn "$DOMAIN"; then
    warn "Format domain tidak valid; memakai self-signed certificate"
    DOMAIN=""
fi
if [ -n "$DOMAIN" ]; then
    mkdir -p "${AUTOSCRIPT_ROOT}/data"
    chmod 700 "${AUTOSCRIPT_ROOT}/data"
    local_domain_file="${AUTOSCRIPT_ROOT}/data/certificate-domain"
    track_file_before_write "$local_domain_file"
    printf '%s\n' "$DOMAIN" > "$local_domain_file"
    chmod 600 "$local_domain_file"
fi

section "FULL INSTALL"
source "${LIB_DIR}/01-dropbear.sh"
source "${LIB_DIR}/02-badvpn.sh"
source "${LIB_DIR}/03-haproxy.sh"
source "${LIB_DIR}/04-ws-tunnel.sh"
source "${LIB_DIR}/05-firewall.sh"
source "${LIB_DIR}/06-users.sh"

log "[01/06] Initializing user database"
users_init
log "[02/06] Updating package indexes"
apt-get update -qq

log "[03/06] Installing Dropbear"
dropbear_install "$DROPBEAR_PORT"
log "[04/06] Installing BadVPN"
badvpn_install "$BADVPN_START"
log "[05/06] Installing HAProxy"
haproxy_install "$DOMAIN" "$WS_PORT" "$DROPBEAR_PORT" "$HAPROXY_PORT_80" "$HAPROXY_PORT_443"
log "[06/06] Installing WebSocket tunnel and firewall"
ws_tunnel_install "$WS_PORT" "127.0.0.1" "$DROPBEAR_PORT"
firewall_setup "$DROPBEAR_PORT" "$WS_PORT" "$BADVPN_START" "$BADVPN_START"

log "Semua komponen selesai dipasang: 01 sampai 06"
log "Port masuk diatur lewat portal web provider VPS; UFW tidak digunakan"

vps_ip=$(get_public_ip)
echo ""
echo "INSTALL SELESAI"
echo "IP: ${vps_ip}"
echo "Dropbear SSH: ${DROPBEAR_PORT}"
echo "BadVPN UDP: ${BADVPN_START}"
echo "WS tunnel: ${WS_PORT}"
echo "HAProxy: ${HAPROXY_PORT_80}, ${HAPROXY_PORT_443}"
echo "Log: ${LOG_FILE}"
AUTOSCRIPT_INSTALL_ACTIVE=false
