#!/usr/bin/env bash
# ============================================================
#  badvpn.sh — BadVPN UDPGW compile from source + setup
# ============================================================

badvpn_install() {
    local start_port="${1:-7300}"
    local max_clients="${2:-1000}"

    section "Installing BadVPN/UDPGW"

    install_pkg cmake
    install_pkg build-essential
    install_pkg git
    install_pkg screen

    local build_dir="/tmp/badvpn-build"
    local bin_path="/usr/local/bin/badvpn-udpgw"

    # Check if already installed
    if [ -x "$bin_path" ]; then
        log "badvpn-udpgw already installed at $bin_path"
    else
        log "Compiling BadVPN UDPGW from source (ambrop72/badvpn)..."

        # Cleanup old build
        rm -rf "$build_dir" 2>/dev/null || true
        git clone --depth 1 https://github.com/ambrop72/badvpn.git "$build_dir" 2>&1 | tee -a "$LOG_FILE" || {
            # Fallback: try mirror
            warn "Primary repo failed, trying mirror..."
            rm -rf "$build_dir" 2>/dev/null || true
            git clone --depth 1 https://github.com/ambrop72/badvpn.git "$build_dir" || \
                die "Gagal clone badvpn repo"
        }

        cd "$build_dir"

        # Apply kernel 5.x+ fix (memset_s -> memset)
        if grep -q "memset_s" "$build_dir/lwip/src/lwip-1.4.1/src/netif/ppp/polarssl/md4.c" 2>/dev/null; then
            log "Patching for kernel 5.x+ compatibility..."
            sed -i 's/memset_s/memset/g' "$build_dir/lwip/src/lwip-1.4.1/src/netif/ppp/polarssl/md4.c" 2>/dev/null || true
        fi

        # Build only UDPGW
        cmake -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 . 2>&1 | tee -a "$LOG_FILE" || \
            die "cmake failed"

        make -j"$(nproc)" 2>&1 | tee -a "$LOG_FILE" || \
            die "make failed"

        cp udpgw/badvpn-udpgw "$bin_path"
        chmod +x "$bin_path"
        cd /root
        rm -rf "$build_dir"
        log "badvpn-udpgw compiled and installed"
    fi

    # Create systemd service
    log "Creating udpgw systemd service..."
    cat > /etc/systemd/system/udpgw.service <<SYSTEMD
[Unit]
Description=BadVPN UDP Gateway
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:${start_port} --max-clients ${max_clients}
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