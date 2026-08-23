#!/usr/bin/env bash
# ============================================================
#  common.sh — Shared functions untuk VPN SSH installer
# ============================================================

set -euo pipefail
IFS=$'\n\t'

# ── Color ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; PURPLE='\033[0;35m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ── Flags ───────────────────────────────────────────────────
AUTOSCRIPT_ROOT="${AUTOSCRIPT_ROOT:-/opt/autoscript}"
LOG_FILE="${AUTOSCRIPT_ROOT}/logs/vpn-install.log"
DRY_RUN=false
FORCE=false

# ── Logging ─────────────────────────────────────────────────
log()  { echo -e "${GREEN}[✓]${NC} $(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE" 2>/dev/null || true; }
warn() { echo -e "${YELLOW}[!]${NC} $(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE" 2>/dev/null || true; }
err()  { echo -e "${RED}[✗]${NC} $(date '+%H:%M:%S') $*" >&2 | tee -a "$LOG_FILE" 2>/dev/null || true; }
info() { echo -e "${CYAN}[i]${NC} $(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE" 2>/dev/null || true; }
ok()   { echo -e "${GREEN}  →${NC} $*"; }
die()  { err "$*"; exit 1; }

# ── Spinner ─────────────────────────────────────────────────
spinner() {
    local pid=$1; local delay=0.1
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    while kill -0 "$pid" 2>/dev/null; do
        for ((i=0; i<${#spin}; i++)); do
            printf "\r${CYAN}[%c]${NC} " "${spin:$i:1}"
            sleep $delay
        done
    done
    printf "\r"
}

# ── Progress bar ────────────────────────────────────────────
progress() {
    local current=$1 total=$2 label="${3:-Progress}"
    local pct=$((current * 100 / total))
    local filled=$((pct / 2))
    local bar=""
    for ((i=0; i<filled; i++)); do bar="${bar}█"; done
    for ((i=filled; i<50; i++)); do bar="${bar}░"; done
    printf "\r${CYAN}[%s]${NC} %s %d%%" "$bar" "$label" "$pct"
}

# ── Banner ─────────────────────────────────────────────────
banner() {
    clear
    echo -e "${BOLD}${PURPLE}"
    cat <<'BANNER'
╔══════════════════════════════════════════════════════════╗
║                                                        ║
║   ██╗   ██╗██████╗ ███╗   ██╗    ███████╗███████╗██╗  ║
║   ██║   ██║██╔══██╗████╗  ██║    ██╔════╝██╔════╝██║  ║
║   ██║   ██║██████╔╝██╔██╗ ██║    ███████╗███████╗██║  ║
║   ╚██╗ ██╔╝██╔═══╝ ██║╚██╗██║    ╚════██║╚════██║██║  ║
║    ╚████╔╝ ██║     ██║ ╚████║    ███████║███████║██║  ║
║     ╚═══╝  ╚═╝     ╚═╝  ╚═══╝    ╚══════╝╚══════╝╚═╝  ║
║                                                        ║
║        SSH + Dropbear + BadVPN + HAProxy + WS          ║
║                Auto Installer v1.0                      ║
╚══════════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
}

# ── Root check ──────────────────────────────────────────────
must_be_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Jalankan sebagai root: sudo bash install.sh"
    fi
}

# ── OS Detection ────────────────────────────────────────────
detect_os() {
    if [ ! -f /etc/os-release ]; then
        die "OS tidak dikenali. Hanya support Debian 10+/Ubuntu 20.04+"
    fi
    . /etc/os-release
    OS_ID=$ID
    OS_VER=$VERSION_ID
    OS_NAME=$PRETTY_NAME

    case "$OS_ID" in
        debian)
            if (( ${OS_VER%%.*} < 10 )); then
                die "Debian $OS_VER tidak support. Minimal Debian 10 (buster)."
            fi
            ;;
        ubuntu)
            if (( ${OS_VER%%.*} < 20 )); then
                die "Ubuntu $OS_VER tidak support. Minimal Ubuntu 20.04 (focal)."
            fi
            ;;
        *)
            die "OS '$OS_ID' tidak support. Hanya Debian/Ubuntu."
            ;;
    esac
    info "Detected: $OS_NAME ($OS_ID $OS_VER)"
}

# ── Install package ─────────────────────────────────────────
install_pkg() {
    local pkg=$1
    if dpkg -s "$pkg" &>/dev/null; then
        ok "$pkg — already installed"
        return 0
    fi
    log "Installing $pkg..."
    if $DRY_RUN; then
        ok "[DRY-RUN] apt install -y $pkg"
    else
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" 2>&1 | tee -a "$LOG_FILE" >/dev/null || {
            warn "Gagal install $pkg — retrying..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" || die "Gagal install $pkg"
        }
    fi
}

# ── Backup file ─────────────────────────────────────────────
backup_file() {
    local file=$1
    if [ -f "$file" ]; then
        local bak="${file}.bak-$(date +%Y%m%d%H%M%S)"
        cp "$file" "$bak"
        ok "Backup: $bak"
    fi
}

# ── systemd daemon-reload + enable + start ──────────────────
enable_service() {
    local svc=$1
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable "$svc" 2>/dev/null || ok "$svc enable — skipped"

    if timeout 30 systemctl start "$svc" 2>/dev/null && systemctl is-active --quiet "$svc"; then
        return 0
    fi

    # SysV fallback is only valid when systemd is unavailable. Do not hide a
    # failed service start behind a success-looking warning.
    if ! command -v systemctl >/dev/null 2>&1 && service "$svc" start 2>/dev/null; then
        return 0
    fi

    err "$svc gagal start"
    systemctl status "$svc" --no-pager -l 2>&1 | tee -a "$LOG_FILE" >/dev/null || true
    return 1
}

# ── Check port ──────────────────────────────────────────────
port_in_use() {
    local port=$1
    if command -v ss >/dev/null 2>&1; then
        ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q . && return 0
        ss -H -lnu "sport = :${port}" 2>/dev/null | grep -q . && return 0
    fi
    netstat -ltnu 2>/dev/null | awk -v p=":${port}" '$4 ~ p "$" || $4 ~ p "[[:space:]]" { found=1 } END { exit !found }' && return 0
    return 1
}

wait_for_port() {
    local port=$1
    local attempts=${2:-20}
    while [ "$attempts" -gt 0 ]; do
        port_in_use "$port" && return 0
        sleep 0.5
        attempts=$((attempts - 1))
    done
    return 1
}

# ── Get public IP ───────────────────────────────────────────
get_public_ip() {
    curl -s4 --max-time 5 ifconfig.me 2>/dev/null \
        || curl -s4 --max-time 5 ipinfo.io/ip 2>/dev/null \
        || curl -s4 --max-time 5 icanhazip.com 2>/dev/null \
        || hostname -I 2>/dev/null | awk '{print $1}'
}

# ── Validate FQDN ───────────────────────────────────────────
validate_fqdn() {
    local domain=$1
    # RFC 1035 FQDN validation
    [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] && return 0
    return 1
}

# ── Validate IP ─────────────────────────────────────────────
validate_ip() {
    local ip=$1
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && return 0
    return 1
}

# ── Confirm prompt ──────────────────────────────────────────
confirm() {
    local msg="${1:-Lanjutkan?}"
    local default="${2:-Y}"
    if $FORCE; then return 0; fi
    read -rp "$msg [Y/n] " reply
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy]$ ]] && return 0
    return 1
}

# ── Random string ───────────────────────────────────────────
random_str() {
    local len=${1:-8}
    openssl rand -base64 "$((len * 2))" 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c "$len"
}

# ── Random numeric ──────────────────────────────────────────
random_num() {
    local min=${1:-1000}
    local max=${2:-9999}
    echo $((RANDOM % (max - min + 1) + min))
}

# ── Loading animation ───────────────────────────────────────
loading() {
    local msg="${1:-Processing}"
    local pid=$2
    local delay=0.1
    local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    while kill -0 "$pid" 2>/dev/null; do
        for frame in "${frames[@]}"; do
            printf "\r${CYAN}[%s]${NC} %s..." "$frame" "$msg"
            sleep $delay
        done
    done
    printf "\r${GREEN}[✓]${NC} %s... done\n" "$msg"
}

# ── Section header ──────────────────────────────────────────
section() {
    echo ""
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${BLUE}  $*${NC}"
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ── Summary box ─────────────────────────────────────────────
summary_box() {
    local title=$1; shift
    local width=56
    echo "┌$(printf '─%.0s' $(seq 1 $width))┐"
    printf "│ %-*s │\n" "$width" "$title"
    echo "├$(printf '─%.0s' $(seq 1 $width))┤"
    for line in "$@"; do
        printf "│ %-*s │\n" "$width" "$line"
    done
    echo "└$(printf '─%.0s' $(seq 1 $width))┘"
}

# ── Trap cleanup ────────────────────────────────────────────
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ] && [ $exit_code -ne 130 ]; then
        echo ""
        warn "Script selesai dengan error (code: $exit_code)"
        warn "Log disimpan di: $LOG_FILE"
    fi
    # Remove lock
    rm -f /tmp/vpn-install.lock 2>/dev/null || true
}
trap cleanup EXIT

# ── Lock ────────────────────────────────────────────────────
acquire_lock() {
    if [ -f /tmp/vpn-install.lock ]; then
        local pid=$(cat /tmp/vpn-install.lock 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null; then
            die "Installer sudah berjalan (PID: $pid). Hapus /tmp/vpn-install.lock jika yakin tidak ada."
        fi
    fi
    echo $$ > /tmp/vpn-install.lock
}

# ── JSON helper (tanpa jq) ──────────────────────────────────
json_get() {
    local json=$1 key=$2
    echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('$key',''))" 2>/dev/null
}

# ── Check internet ──────────────────────────────────────────
check_internet() {
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null || ping -c 1 -W 2 1.1.1.1 &>/dev/null; then
        return 0
    fi
    return 1
}

# ── Setup log ───────────────────────────────────────────────
setup_log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    echo "=== VPN SSH Installer — $(date) ===" >> "$LOG_FILE"
}