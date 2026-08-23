#!/usr/bin/env bash
# ============================================================
#  02-badvpn.sh — BadVPN UDPGW binary download + setup
# ============================================================

badvpn_install() {
    local start_port="${1:-7300}"
    local max_clients="${2:-1000}"

    section "Installing BadVPN/UDPGW"

    local bin_path="${AUTOSCRIPT_ROOT}/bin/badvpn-udpgw"
    local downloaded_bin="${AUTOSCRIPT_BADVPN_BINARY:-}"

    if [ -z "$downloaded_bin" ] || [ ! -x "$downloaded_bin" ]; then
        die "Binary BadVPN hasil unduhan tidak ditemukan di runtime"
    fi

    mkdir -p "$(dirname "$bin_path")"
    install -m 0755 "$downloaded_bin" "$bin_path"
    log "badvpn-udpgw dari GitHub dipasang ke $bin_path"

    # Create systemd service
    log "Creating udpgw systemd service..."
    cat > /etc/systemd/system/udpgw.service <<SYSTEMD
[Unit]
Description=BadVPN UDP Gateway
After=network.target

[Service]
Type=simple
ExecStart=${AUTOSCRIPT_ROOT}/bin/badvpn-udpgw --listen-addr 127.0.0.1:${start_port} --max-clients ${max_clients}
Restart=always
RestartSec=3
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
SyslogIdentifier=udpgw

[Install]
WantedBy=multi-user.target
SYSTEMD

    enable_service udpgw

    if port_in_use "$start_port"; then
        log "BadVPN UDPGW running on port $start_port ✓"
    else
        warn "BadVPN mungkin tidak listen — cek: systemctl status udpgw"
    fi
}