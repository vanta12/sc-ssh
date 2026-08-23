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
case "$AUTOSCRIPT_ROOT" in
    /opt/autoscript) ;;
    *) printf 'AUTOSCRIPT_ROOT tidak aman: %s\n' "$AUTOSCRIPT_ROOT" >&2; exit 1 ;;
esac

DATA_DIR="${AUTOSCRIPT_ROOT}/data"
PACKAGE_MANIFEST="${DATA_DIR}/packages.list"
BACKUP_MANIFEST="${DATA_DIR}/backups.list"
CREATED_MANIFEST="${DATA_DIR}/created.list"
USER_MANIFEST="${DATA_DIR}/users.list"
SERVICE_MANIFEST="${DATA_DIR}/services.list"
CERT_OWNED_FILE="${DATA_DIR}/certificate-owned"
OWNED_DOMAIN=""
if [ -s "$CERT_OWNED_FILE" ]; then
    OWNED_DOMAIN="$(head -n 1 "$CERT_OWNED_FILE")"
fi

# ── Stop only services installed by AutoScript ───────────────
echo "[1] Stopping services..."
for svc in ws-tunnel udpgw haproxy autoscript-dropbear fail2ban; do
    if [ ! -f "$PACKAGE_MANIFEST" ] && [ ! -f "$CREATED_MANIFEST" ]; then
        continue
    fi
    if grep -Fxq "$svc" "$PACKAGE_MANIFEST" 2>/dev/null || \
       grep -Fq "/${svc}.service" "$CREATED_MANIFEST" 2>/dev/null || \
       { [ "$svc" = haproxy ] && \
         { grep -Fq "/etc/haproxy/haproxy.cfg|" "$BACKUP_MANIFEST" 2>/dev/null || \
           grep -Fxq "/etc/haproxy/haproxy.cfg" "$CREATED_MANIFEST" 2>/dev/null; }; }; then
        systemctl disable --now "$svc" 2>/dev/null || true
    fi
done
# Dropbear package service is separate from AutoScript custom unit.
if grep -Fxq dropbear "$PACKAGE_MANIFEST" 2>/dev/null; then
    systemctl disable --now dropbear 2>/dev/null || true
fi

# ── Remove only AutoScript units ────────────────────────────
echo "[2] Removing systemd units..."
for unit in /etc/systemd/system/udpgw.service \
    /etc/systemd/system/ws-tunnel.service \
    /etc/systemd/system/autoscript-dropbear.service; do
    if grep -Fxq "$unit" "$CREATED_MANIFEST" 2>/dev/null; then
        rm -f -- "$unit"
    fi
done
systemctl daemon-reload 2>/dev/null || true
systemctl reset-failed 2>/dev/null || true

# ── Remove only AutoScript-owned cron jobs ─────────────────
echo "[3] Removing cron jobs..."
for cron_file in /etc/cron.d/certbot-vpn /etc/cron.d/vpn-expire; do
    if grep -Fxq "$cron_file" "$CREATED_MANIFEST" 2>/dev/null; then
        rm -f -- "$cron_file"
    fi
done

# ── Restore pre-install iptables before package removal ─────
echo "[4] Restoring firewall rules..."
firewall_backup="${AUTOSCRIPT_ROOT}/data/iptables.before.v4"
if [ -s "$firewall_backup" ] && command -v iptables-restore >/dev/null 2>&1; then
    iptables-restore < "$firewall_backup" 2>/dev/null || true
else
    iptables -D INPUT -p tcp --syn --dport 143 -m conntrack --ctstate NEW -j AUTOSCRIPT_RATE_SSH 2>/dev/null || true
    iptables -D INPUT -m conntrack --ctstate INVALID -j AUTOSCRIPT_INVALID 2>/dev/null || true
    iptables -F AUTOSCRIPT_RATE_SSH 2>/dev/null || true
    iptables -X AUTOSCRIPT_RATE_SSH 2>/dev/null || true
    iptables -F AUTOSCRIPT_INVALID 2>/dev/null || true
    iptables -X AUTOSCRIPT_INVALID 2>/dev/null || true
fi

# ── Remove only packages recorded as AutoScript-owned ───────
echo "[5] Removing packages..."
if [ -s "$PACKAGE_MANIFEST" ]; then
    mapfile -t owned_packages < "$PACKAGE_MANIFEST"
    if [ "${#owned_packages[@]}" -gt 0 ]; then
        apt-get remove --purge -y -qq "${owned_packages[@]}" 2>/dev/null || true
    fi
fi

# ── Restore previous configs and remove created files ───────
echo "[6] Restoring generated configs..."
if [ -f "$BACKUP_MANIFEST" ]; then
    while IFS='|' read -r original backup; do
        if [ -n "$original" ] && [ -f "$backup" ]; then
            cp -a -- "$backup" "$original"
            rm -f -- "$backup"
        fi
    done < "$BACKUP_MANIFEST"
fi
if [ -f "$CREATED_MANIFEST" ]; then
    while IFS= read -r created; do
        [ -n "$created" ] && rm -f -- "$created"
    done < "$CREATED_MANIFEST"
fi
# Created files are already removed from CREATED_MANIFEST; restored files stay.

# ── Remove runtime data and owned certificate ───────────────
echo "[7] Removing runtime data..."
if [ -n "$OWNED_DOMAIN" ]; then
    domain="$OWNED_DOMAIN"
    case "$domain" in
        *[!a-zA-Z0-9.-]*|.*|*..*|*/*) domain="" ;;
    esac
    if [ -n "$domain" ]; then
        certbot delete --cert-name "$domain" --non-interactive 2>/dev/null || true
        rm -rf -- "/etc/letsencrypt/live/$domain" "/etc/letsencrypt/archive/$domain"
        rm -f -- "/etc/letsencrypt/renewal/$domain.conf"
    fi
fi
if [ -f "$USER_MANIFEST" ]; then
    while IFS= read -r username; do
        if [ -n "$username" ] && id "$username" >/dev/null 2>&1; then
            pkill -u "$username" 2>/dev/null || true
            userdel -f "$username" 2>/dev/null || true
        fi
    done < "$USER_MANIFEST"
fi

# Restore enabled/active state for services that predated AutoScript.
if [ -f "$SERVICE_MANIFEST" ]; then
    while IFS='|' read -r svc enabled active; do
        [ -n "$svc" ] || continue
        grep -Fxq "$svc" "$PACKAGE_MANIFEST" 2>/dev/null && continue
        case "$enabled" in
            enabled|enabled-runtime|static) systemctl enable "$svc" 2>/dev/null || true ;;
            *) systemctl disable "$svc" 2>/dev/null || true ;;
        esac
        [ "$active" = active ] && systemctl start "$svc" 2>/dev/null || true
    done < "$SERVICE_MANIFEST"
fi

rm -rf -- "$AUTOSCRIPT_ROOT"

# ── Restart remaining services ──────────────────────────────
systemctl restart rsyslog 2>/dev/null || true

echo ""
echo "Uninstall selesai. Semua artefak VPN SSH dihapus."
echo "OpenSSH tetap berjalan di port 22."