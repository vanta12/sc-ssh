#!/usr/bin/env bash
# ============================================================
#  VPN SSH AUTO INSTALLER v1.0
#  SSH + Dropbear + BadVPN + HAProxy + Custom Python WS
#
#  Usage:
#    sudo bash install.sh                     # interactive
#    sudo bash install.sh --full-auto ...     # non-interactive
#    sudo bash install.sh --component <name>  # single component
# ============================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_RAW_BASE="${AUTOSCRIPT_REPO_RAW_BASE:-https://raw.githubusercontent.com/vanta12/sc-ssh/main}"
RUNTIME_DIR="${AUTOSCRIPT_RUNTIME_DIR:-$(mktemp -d /tmp/autoscript-runtime.XXXXXX)}"
LIB_DIR="${RUNTIME_DIR}/lib"
SRC_DIR="${RUNTIME_DIR}/src"
BIN_DIR="${RUNTIME_DIR}/bin"
BADVPN_SHA256="428be8f53df491db903a9e22e52e7b58d658aeb07e98f044057cd0c38aec9211"

bootstrap_die() {
    printf '[ERROR] %s\\n' "$*" >&2
    exit 1
}

bootstrap_download() {
    local remote_path="$1"
    local destination="$2"
    local destination_dir
    destination_dir="$(dirname "$destination")"
    mkdir -p "$destination_dir"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --connect-timeout 15 "${REPO_RAW_BASE}/${remote_path}" -o "$destination" || \
            bootstrap_die "Gagal mengunduh ${remote_path}"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --tries=3 --timeout=15 "${REPO_RAW_BASE}/${remote_path}" -O "$destination" || \
            bootstrap_die "Gagal mengunduh ${remote_path}"
    else
        bootstrap_die "Butuh curl atau wget untuk mengunduh installer dari GitHub"
    fi

    [ -s "$destination" ] || bootstrap_die "File unduhan kosong: ${remote_path}"
}

bootstrap_runtime() {
    mkdir -p "$LIB_DIR" "$SRC_DIR" "$BIN_DIR"

    bootstrap_download "lib/common.sh" "${LIB_DIR}/common.sh"
    bootstrap_download "lib/01-openssh.sh" "${LIB_DIR}/01-openssh.sh"
    bootstrap_download "lib/02-dropbear.sh" "${LIB_DIR}/02-dropbear.sh"
    bootstrap_download "lib/03-badvpn.sh" "${LIB_DIR}/03-badvpn.sh"
    bootstrap_download "lib/04-haproxy.sh" "${LIB_DIR}/04-haproxy.sh"
    bootstrap_download "lib/05-ws-tunnel.sh" "${LIB_DIR}/05-ws-tunnel.sh"
    bootstrap_download "lib/06-firewall.sh" "${LIB_DIR}/06-firewall.sh"
    bootstrap_download "lib/07-users.sh" "${LIB_DIR}/07-users.sh"
    bootstrap_download "src/ws-tunnel.py" "${SRC_DIR}/ws-tunnel.py"
    bootstrap_download "bin/badvpn-udpgw" "${BIN_DIR}/badvpn-udpgw"

    chmod 755 "${LIB_DIR}"/*.sh "${SRC_DIR}/ws-tunnel.py" "${BIN_DIR}/badvpn-udpgw"

    case "$(uname -m)" in
        x86_64|amd64) ;;
        *) bootstrap_die "Binary badvpn-udpgw tersedia untuk x86_64/amd64 saja" ;;
    esac

    local actual_sha256
    actual_sha256="$(sha256sum "${BIN_DIR}/badvpn-udpgw" | awk '{print $1}')"
    [ "$actual_sha256" = "$BADVPN_SHA256" ] || \
        bootstrap_die "Checksum badvpn-udpgw tidak cocok"
}

if [ "${EUID}" -ne 0 ]; then
    bootstrap_die "Jalankan sebagai root: sudo bash install.sh"
fi

bootstrap_runtime
export AUTOSCRIPT_BADVPN_BINARY="${BIN_DIR}/badvpn-udpgw"
export AUTOSCRIPT_WS_SOURCE="${SRC_DIR}/ws-tunnel.py"

cleanup_runtime() {
    case "$RUNTIME_DIR" in
        /tmp/autoscript-runtime.*) rm -rf "$RUNTIME_DIR" ;;
    esac
}
trap cleanup_runtime EXIT

# ── Source downloaded common ───────────────────────────────
source "${LIB_DIR}/common.sh"

# ── Default Config ────────────────────────────────────────
SSH_PORT=22
DROPBEAR_PORT=143
BADVPN_START=7300
WS_PORT=8880
HAPROXY_PORT_80=80
HAPROXY_PORT_443=443
ALLOW_ROOT="yes"
ALLOW_PASSWORD="yes"
DOMAIN=""
FULL_AUTO=false
INSTALL_COMPONENT=""

# ── Parse CLI ─────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --full-auto) FULL_AUTO=true ;;
        --ssh-port) SSH_PORT="$2"; shift ;;
        --dropbear-port) DROPBEAR_PORT="$2"; shift ;;
        --badvpn-start) BADVPN_START="$2"; shift ;;
        --ws-port) WS_PORT="$2"; shift ;;
        --haproxy-port-80) HAPROXY_PORT_80="$2"; shift ;;
        --haproxy-port-443) HAPROXY_PORT_443="$2"; shift ;;
        --allow-root) ALLOW_ROOT="$2"; shift ;;
        --allow-password) ALLOW_PASSWORD="$2"; shift ;;
        --domain) DOMAIN="$2"; shift ;;
        --component) INSTALL_COMPONENT="$2"; shift ;;
        --force) FORCE=true ;;
        --dry-run) DRY_RUN=true ;;
        --help|-h)
            echo "Usage: sudo bash install.sh [OPTIONS]"
            echo ""
            echo "Modes:"
            echo "  (none)              Interactive menu"
            echo "  --full-auto         Non-interactive full install"
            echo "  --component <name>  Install: ssh | dropbear | badvpn | haproxy | ws-tunnel | firewall"
            echo ""
            echo "Options:"
            echo "  --ssh-port N        SSH port (default 22)"
            echo "  --dropbear-port N   Dropbear port (default 143)"
            echo "  --badvpn-start N    BadVPN start port (default 7300)"
            echo "  --ws-port N         WS tunnel port (default 8880)"
            echo "  --domain DOMAIN     Domain untuk Let's Encrypt"
            echo "  --allow-root yes/no Root login"
            echo "  --allow-password yes/no Password auth"
            echo "  --force             Skip prompts"
            echo "  --dry-run           Simulate only"
            echo ""
            exit 0
            ;;
        *) warn "Unknown: $1"; exit 1 ;;
    esac
    shift
done

# ── Entry Point ───────────────────────────────────────────
must_be_root
setup_log
acquire_lock
check_internet || warn "Tidak ada internet — beberapa fitur mungkin gagal"
detect_os

# ── Single Component Mode ─────────────────────────────────
if [ -n "$INSTALL_COMPONENT" ]; then
    case "$INSTALL_COMPONENT" in
        ssh)       source "${LIB_DIR}/01-openssh.sh";  openssh_install "$SSH_PORT" "$ALLOW_ROOT" "$ALLOW_PASSWORD" ;;
        dropbear)  source "${LIB_DIR}/02-dropbear.sh"; dropbear_install "$DROPBEAR_PORT" ;;
        badvpn)    source "${LIB_DIR}/03-badvpn.sh";   badvpn_install "$BADVPN_START" ;;
        haproxy)   source "${LIB_DIR}/04-haproxy.sh";  source "${LIB_DIR}/01-openssh.sh"
                   haproxy_install "$DOMAIN" "$WS_PORT" "$SSH_PORT" "$DROPBEAR_PORT" "$HAPROXY_PORT_80" "$HAPROXY_PORT_443" ;;
        ws-tunnel) source "${LIB_DIR}/05-ws-tunnel.sh"; ws_tunnel_install "$WS_PORT" "127.0.0.1" "$SSH_PORT" ;;
        firewall)  source "${LIB_DIR}/06-firewall.sh"; firewall_setup "$SSH_PORT" "$DROPBEAR_PORT" "$WS_PORT" "$BADVPN_START" $((BADVPN_START+99)) ;;
        *)
            err "Component unknown: $INSTALL_COMPONENT"
            echo "Available: ssh, dropbear, badvpn, haproxy, ws-tunnel, firewall"
            exit 1
            ;;
    esac
    exit 0
fi

# ── Full Auto Mode ────────────────────────────────────────
if $FULL_AUTO; then
    section "FULL AUTO INSTALL"

    source "${LIB_DIR}/01-openssh.sh"
    source "${LIB_DIR}/02-dropbear.sh"
    source "${LIB_DIR}/03-badvpn.sh"
    source "${LIB_DIR}/04-haproxy.sh"
    source "${LIB_DIR}/05-ws-tunnel.sh"
    source "${LIB_DIR}/06-firewall.sh"
    source "${LIB_DIR}/07-users.sh"

    apt-get update -qq
    openssh_install "$SSH_PORT" "$ALLOW_ROOT" "$ALLOW_PASSWORD"
    dropbear_install "$DROPBEAR_PORT"
    badvpn_install "$BADVPN_START"
    haproxy_install "$DOMAIN" "$WS_PORT" "$SSH_PORT" "$DROPBEAR_PORT" "$HAPROXY_PORT_80" "$HAPROXY_PORT_443"
    ws_tunnel_install "$WS_PORT" "127.0.0.1" "$SSH_PORT"
    firewall_setup "$SSH_PORT" "$DROPBEAR_PORT" "$WS_PORT" "$BADVPN_START" $((BADVPN_START+99))

    # Final summary
    show_summary
    exit 0
fi

# ── Interactive Mode ──────────────────────────────────────
while true; do
    clear
    banner
    echo ""
    echo -e "${BOLD}${CYAN}  MAIN MENU${NC}"
    echo ""
    echo "  [1] Full Install (Semua Komponen)"
    echo "  [2] Install Per-Komponen"
    echo "  [3] User Management"
    echo "  [4] Service Status"
    echo "  [5] Uninstall"
    echo "  [6] Exit"
    echo ""
    read -rp "  Pilih [1-6]: " main_choice

    case "$main_choice" in
        1)  # ── Full Install ─────────────────────────────
            section "FULL INSTALL"

            # Get config
            echo -e "${CYAN}Konfigurasi (Enter untuk default):${NC}"
            echo ""
            read -rp "  SSH Port              [22]: " input; SSH_PORT="${input:-$SSH_PORT}"
            read -rp "  Dropbear Port         [143]: " input; DROPBEAR_PORT="${input:-$DROPBEAR_PORT}"
            read -rp "  BadVPN UDPGW Start    [7300]: " input; BADVPN_START="${input:-$BADVPN_START}"
            read -rp "  WS Tunnel Port        [8880]: " input; WS_PORT="${input:-$WS_PORT}"
            read -rp "  Allow Root Login      [yes]: " input; ALLOW_ROOT="${input:-$ALLOW_ROOT}"
            read -rp "  Allow Password Auth   [yes]: " input; ALLOW_PASSWORD="${input:-$ALLOW_PASSWORD}"

            echo ""
            read -rp "  Ada domain? [y/N]: " has_domain
            if [[ "$has_domain" =~ ^[Yy] ]]; then
                while true; do
                    read -rp "  Masukkan domain: " DOMAIN
                    if validate_fqdn "$DOMAIN"; then
                        break
                    else
                        warn "Format domain tidak valid. Contoh: vpn.example.com"
                    fi
                done
            fi

            echo ""
            echo -e "${BOLD}Konfigurasi:${NC}"
            echo "  SSH         : ${CYAN}port $SSH_PORT${NC} (root=$ALLOW_ROOT, pass=$ALLOW_PASSWORD)"
            echo "  Dropbear    : ${CYAN}port $DROPBEAR_PORT${NC}"
            echo "  BadVPN      : ${CYAN}port $BADVPN_START${NC}"
            echo "  WS Tunnel   : ${CYAN}port $WS_PORT${NC}"
            echo "  HAProxy     : ${CYAN}port 80 + 443${NC}"
            echo "  Domain      : ${CYAN}${DOMAIN:-'(tidak ada — self-signed)'}${NC}"
            echo ""

            confirm "Lanjutkan install?" || { warn "Dibatalkan."; continue; }

            # Source all modules in numbered installation order
            source "${LIB_DIR}/01-openssh.sh"
            source "${LIB_DIR}/02-dropbear.sh"
            source "${LIB_DIR}/03-badvpn.sh"
            source "${LIB_DIR}/04-haproxy.sh"
            source "${LIB_DIR}/05-ws-tunnel.sh"
            source "${LIB_DIR}/06-firewall.sh"
            source "${LIB_DIR}/07-users.sh"
            users_init

            # Update packages
            confirm "apt update + upgrade? [Y/n]" && {
                log "Updating packages..."
                apt-get update -qq
                apt-get upgrade -y -qq 2>&1 | tee -a "$LOG_FILE" || true
            }

            # Execute
            openssh_install "$SSH_PORT" "$ALLOW_ROOT" "$ALLOW_PASSWORD"
            dropbear_install "$DROPBEAR_PORT"
            badvpn_install "$BADVPN_START"
            haproxy_install "$DOMAIN" "$WS_PORT" "$SSH_PORT" "$DROPBEAR_PORT" "$HAPROXY_PORT_80" "$HAPROXY_PORT_443"
            ws_tunnel_install "$WS_PORT" "127.0.0.1" "$SSH_PORT"
            firewall_setup "$SSH_PORT" "$DROPBEAR_PORT" "$WS_PORT" "$BADVPN_START" $((BADVPN_START+99))

            # Offer to create trial user
            echo ""
            read -rp "  Buat user trial? [Y/n]: " create_trial
            if [[ ! "$create_trial" =~ ^[Nn] ]]; then
                source "${LIB_DIR}/07-users.sh"
                users_init
                echo "  Durasi: [1]=2jam [2]=6jam [3]=12jam [4]=1hari [5]=3hari [6]=7hari [7]=Custom"
                read -rp "  > " dur_choice
                case "$dur_choice" in
                    1) H=2 ;;
                    2) H=6 ;;
                    3) H=12 ;;
                    4) H=24 ;;
                    5) H=72 ;;
                    6) H=168 ;;
                    7) read -rp "  Jam: " H ;;
                    *) H=2 ;;
                esac
                trial_pass=$(users_create "$H")
                TRIAL_USER=$(tail -1 "$USER_DB" 2>/dev/null | cut -d'|' -f1)
                TRIAL_PASS="$trial_pass"
            fi

            show_summary
            ;;

        2)  # ── Per-Komponen ─────────────────────────────
            while true; do
                clear
                echo -e "${BOLD}${CYAN}  INSTALL PER-KOMPONEN${NC}"
                echo ""
                echo "  [1] OpenSSH"
                echo "  [2] Dropbear"
                echo "  [3] BadVPN/UDPGW"
                echo "  [4] HAProxy (port sharing 80+443)"
                echo "  [5] Python WS Tunnel"
                echo "  [6] Firewall + Fail2Ban"
                echo "  [7] Kembali"
                echo ""
                read -rp "  > " comp_choice

                case "$comp_choice" in
                    1)
                        read -rp "  SSH Port [22]: " input; SSH_PORT="${input:-$SSH_PORT}"
                        source "${LIB_DIR}/01-openssh.sh"
                        openssh_install "$SSH_PORT" "$ALLOW_ROOT" "$ALLOW_PASSWORD"
                        read -rp "  [Enter] lanjut..." _;;
                    2)
                        read -rp "  Dropbear Port [143]: " input; DROPBEAR_PORT="${input:-$DROPBEAR_PORT}"
                        source "${LIB_DIR}/02-dropbear.sh"
                        dropbear_install "$DROPBEAR_PORT"
                        read -rp "  [Enter] lanjut..." _;;
                    3)
                        read -rp "  BadVPN Start Port [7300]: " input; BADVPN_START="${input:-$BADVPN_START}"
                        source "${LIB_DIR}/03-badvpn.sh"
                        badvpn_install "$BADVPN_START"
                        read -rp "  [Enter] lanjut..." _;;
                    4)
                        read -rp "  Ada domain? [y/N]: " has_domain
                        if [[ "$has_domain" =~ ^[Yy] ]]; then
                            while true; do
                                read -rp "  Domain: " DOMAIN
                                validate_fqdn "$DOMAIN" && break || warn "Invalid"
                            done
                        fi
                        source "${LIB_DIR}/04-haproxy.sh"
                        haproxy_install "$DOMAIN" "$WS_PORT" "$SSH_PORT" "$DROPBEAR_PORT" "$HAPROXY_PORT_80" "$HAPROXY_PORT_443"
                        read -rp "  [Enter] lanjut..." _;;
                    5)
                        source "${LIB_DIR}/05-ws-tunnel.sh"
                        ws_tunnel_install "$WS_PORT" "127.0.0.1" "$SSH_PORT"
                        read -rp "  [Enter] lanjut..." _;;
                    6)
                        source "${LIB_DIR}/06-firewall.sh"
                        firewall_setup "$SSH_PORT" "$DROPBEAR_PORT" "$WS_PORT" "$BADVPN_START" $((BADVPN_START+99))
                        read -rp "  [Enter] lanjut..." _;;
                    7) break ;;
                    *) warn "Invalid"; sleep 1 ;;
                esac
            done
            ;;

        3)  # ── User Management ──────────────────────────
            source "${LIB_DIR}/07-users.sh"
            users_init
            users_menu
            ;;

        4)  # ── Service Status ────────────────────────────
            clear
            section "SERVICE STATUS"

            echo ""
            for svc in ssh sshd dropbear udpgw haproxy ws-tunnel fail2ban; do
                if systemctl is-active --quiet "$svc" 2>/dev/null; then
                    echo -e "  ${GREEN}●${NC} $svc ${GREEN}active${NC}"
                elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
                    echo -e "  ${RED}○${NC} $svc ${YELLOW}inactive${NC}"
                else
                    echo -e "  ${DIM}─${NC} $svc not installed"
                fi
            done

            echo ""
            echo -e "${BOLD}Listening Ports:${NC}"
            netstat -tlnp 2>/dev/null | head -20 || ss -tlnp 2>/dev/null | head -20

            echo ""
            read -rp "  [Enter] kembali..." _
            ;;

        5)  # ── Uninstall ─────────────────────────────────
            section "UNINSTALL"

            warn "Ini akan menghapus semua komponen VPN SSH!"
            echo ""
            confirm "Yakin ingin uninstall? [y/N]" "N" || continue

            log "Stopping services..."
            for svc in ws-tunnel udpgw haproxy dropbear ssh fail2ban; do
                systemctl stop "$svc" 2>/dev/null || true
                systemctl disable "$svc" 2>/dev/null || true
            done

            log "Removing packages..."
            apt-get remove --purge -y -qq dropbear haproxy fail2ban 2>/dev/null || true

            log "Removing configs..."
            rm -f /etc/systemd/system/udpgw.service
            rm -f /etc/systemd/system/ws-tunnel.service
            rm -f /etc/cron.d/certbot-vpn
            rm -f /etc/cron.d/vpn-expire
            rm -rf /opt/vpn-ssh
            rm -rf /etc/haproxy/ssl
            rm -f /etc/issue.net /etc/dropbear.banner
            rm -f "$USER_DB"

            # Restore original sshd_config
            local bak
            bak=$(ls -t /etc/ssh/sshd_config.bak-* 2>/dev/null | head -1)
            if [ -n "$bak" ]; then
                cp "$bak" /etc/ssh/sshd_config
                systemctl restart ssh 2>/dev/null || true
                log "Restored original sshd_config"
            fi

            # Reset firewall
            ufw --force reset 2>/dev/null || true

            systemctl daemon-reload 2>/dev/null || true
            log "Uninstall selesai"
            read -rp "  [Enter] kembali..." _
            ;;

        6)  # ── Exit ──────────────────────────────────────
            log "Bye! Log: $LOG_FILE"
            exit 0
            ;;

        *)
            warn "Pilihan tidak valid"
            sleep 1
            ;;
    esac
done

# ── Summary ────────────────────────────────────────────────
show_summary() {
    clear
    local vps_ip
    vps_ip=$(get_public_ip)

    local cert_status="self-signed ⚠️"
    [ -f /etc/haproxy/ssl/vpn.pem ] && {
        openssl x509 -in /etc/haproxy/ssl/vpn.pem -noout -issuer 2>/dev/null | grep -qi "lets.encrypt" && \
            cert_status="Let's Encrypt ✅"
    }

    echo ""
    echo -e "${BOLD}${GREEN}"
    cat <<'SUMMARY'
╔══════════════════════════════════════════════════════════╗
║                                                        ║
║           INSTALL SELESAI — VPN SSH READY              ║
║                                                        ║
╚══════════════════════════════════════════════════════════╝
SUMMARY
    echo -e "${NC}"
    echo ""
    echo -e "  ${BOLD}Server Info${NC}"
    echo -e "  ├─ IP        : ${CYAN}${vps_ip}${NC}"
    echo -e "  ├─ OS        : ${CYAN}${OS_NAME}${NC}"
    echo -e "  └─ SSL       : ${CYAN}${cert_status}${NC}"
    if [ -n "$DOMAIN" ]; then
        echo -e "     Domain    : ${CYAN}${DOMAIN}${NC}"
    fi
    echo ""
    echo -e "  ${BOLD}Service Ports${NC}"
    echo -e "  ├─ SSH       : ${CYAN}${SSH_PORT}${NC} ${DIM}(+ 80/443 via HAProxy)${NC}"
    echo -e "  ├─ Dropbear  : ${CYAN}${DROPBEAR_PORT}${NC} ${DIM}(+ 80/443 via HAProxy)${NC}"
    echo -e "  ├─ WS Tunnel : ${CYAN}${WS_PORT}${NC} ${DIM}(internal)${NC}"
    echo -e "  ├─ HAProxy   : ${CYAN}80, 443${NC} ${DIM}(port sharing)${NC}"
    echo -e "  ├─ BadVPN    : ${CYAN}${BADVPN_START}${NC} ${DIM}(UDP)${NC}"
    echo -e "  └─ Stats     : ${CYAN}9090${NC} ${DIM}(HAProxy stats)${NC}"

    if [ -n "${TRIAL_USER:-}" ] && [ -n "${TRIAL_PASS:-}" ]; then
        echo ""
        echo -e "  ${BOLD}Trial User${NC}"
        echo -e "  ├─ Username  : ${CYAN}${TRIAL_USER}${NC}"
        echo -e "  └─ Password  : ${CYAN}${TRIAL_PASS}${NC}"
    fi

    echo ""
    echo -e "  ${BOLD}Mode Koneksi HTTP Injector${NC}"
    echo -e "  ├─ SSH Direct       : ${DIM}${vps_ip}:80${NC} ${DIM}(no payload)${NC}"
    echo -e "  ├─ SSH over SSL     : ${DIM}${vps_ip}:443${NC} ${DIM}(SSL ON, no payload)${NC}"
    echo -e "  ├─ SSH over WS      : ${DIM}${vps_ip}:80${NC} ${DIM}(payload: GET...Upgrade: websocket)${NC}"
    echo -e "  └─ SSH over WSS     : ${DIM}${vps_ip}:443${NC} ${DIM}(SSL ON + WS payload)${NC}"
    echo ""
    echo -e "  ${YELLOW}Log: ${LOG_FILE}${NC}"
    echo ""

    if [ -n "${TRIAL_USER:-}" ]; then
        echo -e "  ${YELLOW}Jangan lupa: reboot VPS untuk memastikan semua service jalan${NC}"
    fi
    echo ""
}