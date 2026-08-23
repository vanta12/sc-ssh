#!/usr/bin/env bash
# ============================================================
#  03-haproxy.sh — HAProxy port sharing 80/443 + SSL
# ============================================================

haproxy_install() {
    local domain="${1:-}"
    local ws_port="${2:-8880}"
    local dropbear_port="${3:-143}"
    local haproxy_port_80="${4:-80}"
    local haproxy_port_443="${5:-443}"

    section "Installing HAProxy"

    install_pkg haproxy
    install_pkg openssl
    install_pkg dnsutils

    local ha_conf="/etc/haproxy/haproxy.cfg"
    local ssl_dir="${AUTOSCRIPT_ROOT}/ssl"
    mkdir -p "$ssl_dir"
    backup_file "$ha_conf"

    # ── SSL Certificate ────────────────────────────────────
    local cert_type="self-signed"
    local cert_pem="${ssl_dir}/vpn.pem"
    local cert_valid=false

    if [ -n "$domain" ]; then
        section "Domain + SSL Validation"

        # Step 1: Validate FQDN
        if ! validate_fqdn "$domain"; then
            warn "Domain '$domain' format tidak valid — menggunakan self-signed"
        # Step 2: DNS A record
        elif ! dns_ip=$(dig +short A "$domain" 2>/dev/null | head -1); then
            warn "Tidak bisa query DNS untuk '$domain' — menggunakan self-signed"
        elif [ -z "$dns_ip" ]; then
            warn "DNS A record untuk '$domain' tidak ditemukan — menggunakan self-signed"
        else
            # Step 3: Compare with VPS IP
            local vps_ip
            vps_ip=$(get_public_ip)
            if [ "$dns_ip" = "$vps_ip" ]; then
                log "DNS A record OK: $domain → $dns_ip (cocok dengan VPS)"

                # Step 4: Check port 80 availability
                if port_in_use 80 && ! $FORCE; then
                    warn "Port 80 sudah digunakan — stop sementara untuk certbot"
                    # Try to free port 80
                    systemctl stop haproxy 2>/dev/null || true
                    systemctl stop nginx 2>/dev/null || true
                    systemctl stop apache2 2>/dev/null || true
                    sleep 2
                fi

                # Use a syntactically valid mailbox. Let's Encrypt only needs a
                # reachable-looking contact address; do not invent invalid TLDs.
                local rand_id rand_user email_domain
                local email_domains=(gmail.com yahoo.com icloud.com hotmail.com outlook.com aol.com)
                rand_id=$(openssl rand -hex 5)
                rand_user=$(openssl rand -hex 3)
                email_domain="${email_domains[$((RANDOM % ${#email_domains[@]}))]}"
                local name="user_${rand_id}"
                local email="${rand_user}@${email_domain}"
                info "Random identity: $name <$email>"

                # Install certbot
                log "Installing certbot..."
                if command -v snap &>/dev/null; then
                    snap install core 2>/dev/null || true
                    snap refresh core 2>/dev/null || true
                    snap install --classic certbot 2>/dev/null || \
                        apt-get install -y -qq certbot 2>/dev/null || true
                else
                    apt-get install -y -qq certbot 2>/dev/null || true
                fi

                if command -v certbot &>/dev/null; then
                    # Keep Certbot lineage name stable and use same path for
                    # HAProxy and renewal. Random cert names break path lookup.
                    local cert_name="autoscript-${domain//./-}"
                    local le_live="/etc/letsencrypt/live/${cert_name}"
                    log "Requesting Let's Encrypt certificate (name=${cert_name})..."
                    if certbot certonly --standalone \
                        --non-interactive --agree-tos \
                        --email "$email" \
                        --domain "$domain" \
                        --cert-name "$cert_name" \
                        2>&1 | tee -a "$LOG_FILE"; then


                        if [ -f "${le_live}/fullchain.pem" ] && [ -f "${le_live}/privkey.pem" ]; then
                            cat "${le_live}/fullchain.pem" "${le_live}/privkey.pem" > "$cert_pem"
                            chmod 600 "$cert_pem"
                            cert_type="lets-encrypt"
                            cert_valid=true
                            log "Let's Encrypt certificate obtained ✓"

                            # Setup auto-renew
                            cat > /etc/cron.d/certbot-vpn <<CRONEOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

0 3 */2 * * root certbot renew --quiet --non-interactive && cat ${le_live}/fullchain.pem ${le_live}/privkey.pem > ${cert_pem} && chmod 600 ${cert_pem} && systemctl reload haproxy
CRONEOF
                            log "Auto-renew cron setup (every 2 days 03:00)"
                        else
                            warn "Let's Encrypt files not found, using self-signed"
                        fi
                    else
                        warn "certbot failed — using self-signed"
                    fi
                else
                    warn "certbot not available — using self-signed"
                fi
            else
                warn "DNS A record ($dns_ip) != VPS IP ($vps_ip) — menggunakan self-signed"
            fi
        fi
    fi

    # ── Self-signed fallback ───────────────────────────────
    if [ "$cert_valid" != "true" ]; then
        log "Generating self-signed certificate..."
        local self_pem="${ssl_dir}/vpn.self.pem"
        local self_crt="${ssl_dir}/vpn.self.crt"
        local self_key="${ssl_dir}/vpn.self.key"

        openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
            -subj "/C=ID/ST=Jakarta/L=Jakarta/O=AutoScript/CN=VPS-$(hostname)" \
            -keyout "$self_key" \
            -out "$self_crt" 2>/dev/null

        cat "$self_crt" "$self_key" > "$self_pem"
        chmod 600 "$self_pem" "$self_key"
        ln -sf "$self_pem" "$cert_pem"
        cert_type="self-signed"
        log "Self-signed certificate created"
    fi

    # ── HAProxy Config ─────────────────────────────────────
    log "Writing HAProxy config (port sharing 80+443)..."

    local cpu_cores
    cpu_cores=$(nproc)
    local maxconn=$((cpu_cores * 1000))
    [ "$maxconn" -lt 2000 ] && maxconn=2000

    if false; then
        cat > "$ha_conf" <<HAPROXY
# Generated by VPN SSH Installer — $(date)
# Port sharing: SSH Direct, SSH over SSL/TLS, SSH over WS/WSS
# Certificate: ${cert_type}

global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    maxconn ${maxconn}
    tune.ssl.default-dh-param 2048
    ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384
    ssl-default-bind-options no-sslv3 no-tlsv10 no-tlsv11

defaults
    log global
    mode tcp
    option dontlognull
    option tcplog
    timeout connect 10s
    timeout client 1800s
    timeout server 1800s
    timeout tunnel 3600s
    timeout client-fin 30s
    timeout server-fin 30s

# ── Stats Page ──────────────────────────────────────────
listen stats
    bind 127.0.0.1:9090
    mode http
    stats enable
    stats uri /stats
    stats realm HAProxy\ Stats
    stats auth admin:$(random_str 12)
    stats refresh 10s

# ══════════════════════════════════════════════════════════
# FRONTEND: Port 80 (Plain TCP — protocol sniffing)
# ══════════════════════════════════════════════════════════

frontend http-in
    bind :${haproxy_port_80}
    mode tcp
    option tcplog
    tcp-request inspect-delay 3s
    tcp-request content accept if { req.payload(0,4) -m str SSH- }
    tcp-request content accept if { req.payload(0,3) -m str GET }
    tcp-request content accept if { req.payload(0,4) -m str POST }
    tcp-request content accept if { req.payload(0,4) -m str CONN }
    tcp-request content accept if { req.payload(0,7) -m str OPTIONS }
    tcp-request content accept if { req.payload(0,4) -m str HEAD }
    tcp-request content accept if { req.payload(0,4) -m str PUT  }
    tcp-request content accept if { req.payload(0,6) -m str DELETE }
    tcp-request content accept if { req.payload(0,5) -m str PATCH }
    default_backend ssh_direct

    # SSH Direct (byte starts with "SSH-")
    use_backend ssh_direct if { req.payload(0,4) -m str SSH- }

    # WS tunnel (HTTP GET with Upgrade header)
    use_backend ws_tunnel_plain if HTTP
    use_backend ws_tunnel_plain if { req.payload(0,3) -m str GET }
    use_backend ws_tunnel_plain if { req.payload(0,4) -m str POST }

# ══════════════════════════════════════════════════════════
# FRONTEND: Port 443 (TLS termination + sniffing)
# ══════════════════════════════════════════════════════════

frontend https-in
    bind :${haproxy_port_443} ssl crt ${cert_pem} alpn h2,http/1.1
    mode tcp
    option tcplog
    tcp-request inspect-delay 3s
    tcp-request content accept if { req.payload(0,4) -m str SSH- }
    tcp-request content accept if { req.payload(0,3) -m str GET }
    default_backend ws_tunnel_ssl

    # SSH over SSL/TLS
    use_backend ssh_local if { req.payload(0,4) -m str SSH- }

    # WSS / HTTP over TLS
    use_backend ws_tunnel_ssl if HTTP
    use_backend ws_tunnel_ssl if { req.payload(0,3) -m str GET }

# ══════════════════════════════════════════════════════════
# BACKENDS
# ══════════════════════════════════════════════════════════

backend ssh_direct
    mode tcp
    server dropbear1 127.0.0.1:${dropbear_port} check inter 10s fall 3 rise 2
    timeout server 3600s

backend ssh_local
    mode tcp
    server dropbear1 127.0.0.1:${dropbear_port} check inter 10s fall 3 rise 2
    timeout server 3600s

backend ws_tunnel_plain
    mode tcp
    option tcp-check
    server ws1 127.0.0.1:${ws_port} check inter 10s fall 3 rise 2
    timeout server 3600s
    timeout tunnel 3600s

backend ws_tunnel_ssl
    mode tcp
    option tcp-check
    server ws1 127.0.0.1:${ws_port} check inter 10s fall 3 rise 2
    timeout server 3600s
    timeout tunnel 3600s

HAPROXY
    fi

    local template="${AUTOSCRIPT_HAPROXY_TEMPLATE:-}"
    [ -f "$template" ] || die "Template HAProxy tidak ditemukan: $template"

    local stats_password
    stats_password="$(random_str 12)"
    sed \
        -e "s|{{CERT_TYPE}}|${cert_type}|g" \
        -e "s|{{MAXCONN}}|${maxconn}|g" \
        -e "s|{{STATS_PASSWORD}}|${stats_password}|g" \
        -e "s|{{PORT_80}}|${haproxy_port_80}|g" \
        -e "s|{{PORT_443}}|${haproxy_port_443}|g" \
        -e "s|{{CERT_PEM}}|${cert_pem}|g" \
        -e "s|{{DROPBEAR_PORT}}|${dropbear_port}|g" \
        -e "s|{{WS_PORT}}|${ws_port}|g" \
        "$template" > "$ha_conf"

    if command -v haproxy >/dev/null 2>&1; then
        haproxy -c -f "$ha_conf" >/dev/null || die "Konfigurasi HAProxy tidak valid"
    fi
    enable_service haproxy

    log "HAProxy running — port ${haproxy_port_80} (plain) + ${haproxy_port_443} (TLS)"
    log "SSL type: ${cert_type}"
    log "Stats: http://127.0.0.1:9090/stats"
}