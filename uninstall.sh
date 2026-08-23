#!/usr/bin/env bash
# ============================================================
# UNINSTALLER — reverses everything install.sh creates.
# No backup, no confirmation prompt. Purge-only mode.
# ============================================================

set -euo pipefail

if [ "${EUID}" -ne 0 ]; then
    printf 'Jalankan sebagai root: sudo bash uninstall.sh\n' >&2
    exit 1
fi

echo "=== UNINSTALL VPN SSH AUTOSCRIPT ==="

AUTOSCRIPT_ROOT="${AUTOSCRIPT_ROOT:-/opt/autoscript}"

# ── Stop + disable all services ─────────────────────────────
echo "[1] Stopping services..."
for svc in ws-tunnel udpgw haproxy autoscript-dropbear dropbear fail2ban; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
done

# ── Remove systemd units ────────────────────────────────────
echo "[2] Removing systemd units..."
rm -f /etc/systemd/system/udpgw.service
rm -f /etc/systemd/system/ws-tunnel.service
rm -f /etc/systemd/system/autoscript-dropbear.service
rm -rf /lib/systemd/system/dropbear.service.d /etc/systemd/system/dropbear.service.d 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
systemctl reset-failed 2>/dev/null || true

# ── Remove cron jobs ────────────────────────────────────────
echo "[3] Removing cron jobs..."
rm -f /etc/cron.d/certbot-vpn
rm -f /etc/cron.d/vpn-expire

# ── Remove packages ─────────────────────────────────────────
echo "[4] Removing packages..."
apt-get remove --purge -y -qq dropbear haproxy fail2ban iptables-persistent 2>/dev/null || true
apt-get autoremove --purge -y -qq 2>/dev/null || true

# ── Remove generated configs ────────────────────────────────
echo "[5] Removing generated configs..."
rm -f /etc/dropbear.banner
rm -f /etc/default/dropbear
rm -f /etc/haproxy/haproxy.cfg
rm -f /etc/rsyslog.d/haproxy.conf

# ── Remove runtime data ─────────────────────────────────────
echo "[6] Removing runtime data..."
rm -rf "$AUTOSCRIPT_ROOT"
rm -rf /etc/letsencrypt/live/vpn-* 2>/dev/null || true
rm -rf /etc/letsencrypt/archive/vpn-* 2>/dev/null || true
rm -rf /etc/letsencrypt/renewal/vpn-* 2>/dev/null || true

# ── Flush iptables rules ────────────────────────────────────
echo "[7] Flushing iptables rules..."
iptables -D INPUT -p tcp --dport 143 -j RATE_SSH 2>/dev/null || true
iptables -D INPUT -m state --state INVALID -j DROP 2>/dev/null || true
iptables -F RATE_SSH 2>/dev/null || true
iptables -X RATE_SSH 2>/dev/null || true
rm -f /etc/iptables/rules.v4

# ── Restart remaining services ──────────────────────────────
systemctl restart rsyslog 2>/dev/null || true

echo ""
echo "Uninstall selesai. Semua artefak VPN SSH dihapus."
echo "OpenSSH tetap berjalan di port 22."