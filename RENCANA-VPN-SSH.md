# Rencana Installer VPN Berbasis SSH (Final)

## Tujuan
Installer otomatis VPN server — SSH multi-protocol sharing port 80 & 443
dengan script Python WebSocket super fleksibel (non-standar).

---

## Arsitektur: HAProxy Port Sharing 80 & 443

```
                          ┌─────────────────────────────────┐
                          │         HAProxy                 │
Client ──────────────────▶│                                 │
(HTTP Injector /          │  PORT 80 (plain)                │
 Android / PC)            │  ├─ detect "SSH-" → SSH :143    │
                          │  ├─ detect "GET.*Upgrade" → WS  │
                          │  │   (Python raw WS :8880)      │
                          │  └─ else → HTTP (drop/reject)   │
                          │                                  │
                          │  PORT 443 (TLS)                  │
                          │  ├─ TLS terminate               │
                          │  │   (Let's Encrypt / self-signed)│
                          │  ├─ detect "SSH-" → SSH :143    │
                          │  │   → SSH over SSL/TLS                    │
                          │  ├─ detect "GET.*Upgrade" → WS  │
                          │  │   → WSS (WS over TLS)                    │
                          │  └─ else → HTTP/WS tunnel       │
                          └──────────┬──────────────────────┘
                                     │
              ┌──────────────────────┼──────────────────────┐
              ▼                      ▼                      ▼
        ┌──────────┐         ┌──────────────┐       ┌──────────┐
        │ Dropbear │         │ Custom Python │
        │ :143     │         │ Raw WS :8880  │
        └──────────┘         └──────┬───────┘       └──────────┘
                                    │
                            (connect lokal)
                                    │
                              ┌─────▼─────┐
                              │ Dropbear   │
                              │ SSH utama  │
                              └────────────┘
```

### Detail Routing HAProxy

**Port 80 (plain TCP — protocol sniffing):**
```
tcp-request inspect-delay 3s
tcp-request content accept if { req.payload(0,4) -m str SSH- }
  → use_backend ssh_direct
tcp-request content accept if { req.payload(0,4) -m str GET  }
  → use_backend ws_tunnel   (jika ada header Upgrade)
  → use_backend http_backend (jika bukan WS)
default → ssh_direct (fallback)
```

**Port 443 (TLS termination + protocol sniffing):**
```
frontend https-in
  bind :443 ssl crt /etc/haproxy/ssl/vpn.pem
  tcp-request inspect-delay 3s
  tcp-request content accept if { req.payload(0,4) -m str SSH- }
    → use_backend ssh_local
  tcp-request content accept if { req.ssl_hello_type 1 }
    → use_backend ws_tunnel_ssl  (HTTP di dalam TLS → WS)
  default → ws_tunnel_ssl
```

Backend mapping:
- `ssh_direct` → 127.0.0.1:143 (Dropbear)
- `ssh_local`  → 127.0.0.1:143 (Dropbear via TLS termination)
- `ws_tunnel`  → 127.0.0.1:8880 (Python raw WS)
- `ws_tunnel_ssl` → 127.0.0.1:8880 (Python raw WS via TLS)

---

## Komponen

### 1. Dropbear — SSH utama
- Port 22 (internal), bisa langsung diakses via port 80/443
- Lightweight, < 5 MB RAM
- Password authentication dan public key authentication
- Dropbear menjadi satu-satunya SSH server

### 3. BadVPN/UDPGW
- Port 7300 (start), range 7300-7399
- Binary precompiled diunduh dari `bin/badvpn-udpgw` repo GitHub

### 4. HAProxy — Port Sharing Engine
- Listen: 80 (plain) + 443 (TLS)
- Protocol detection via `req.payload()` — baca byte pertama
- Routing: SSH, HTTP/WS, SSL/TLS
- SSL cert: auto-detect (Let's Encrypt kalau domain valid, self-signed fallback)

### 5. Domain + SSL Management

#### Alur Deteksi + Validasi Domain

```
installer prompt → "Ada domain? [y/n]"
  │
  ├─ n → self-signed cert → langsung deploy
  │
  └─ y → input domain → VALIDASI KETAT
          ├─ [1] Format FQDN valid?
          │     Regex: ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$
          │     Gagal → "Domain tidak valid!" → ulangi
          │
          ├─ [2] DNS A record ada?
          │     dig +short A domain.com
          │     Gagal → "DNS A record tidak ditemukan!" → fallback self-signed
          │
          ├─ [3] A record = IP VPS?
          │     IP VPS = $(curl -s ifconfig.me)
          │     Bandingkan A record IP vs VPS IP
          │     Tidak cocok → "A record bukan VPS ini!" → fallback self-signed
          │     Cocok → lanjut Let's Encrypt
          │
          └─ [4] Port 80 tersedia? (untuk HTTP-01 challenge)
                netstat -tlnp | grep ':80 '
                Ada service lain → stop sementara / warning
                OK → jalankan certbot
```

#### Generate Email + Nama Acak (Let's Encrypt)

**TIDAK minta input email dari user.** Generate otomatis:

```bash
# generate random values
RAND_ID=$(openssl rand -hex 5)        # 10 char hex — untuk cert-name & name
RAND_USER=$(openssl rand -hex 3)      # 6 char hex — local user
RAND_DOM=$(openssl rand -hex 4)       # 8 char hex — domain email
RAND_TLD=$(openssl rand -hex 2)       # 4 char hex — TLD email

NAME="user_${RAND_ID}"
EMAIL="${RAND_USER}@${RAND_DOM}.${RAND_TLD}"
# Contoh hasil:
#   NAME  = user_a3f7b2e901
#   EMAIL = 1a2b3c@d4e5f6g7.x8y9

# certbot pakai ini
certbot certonly --standalone \
  --non-interactive --agree-tos \
  --email "$EMAIL" \
  --cert-name "vpn-${RAND_ID}"
```

#### Path Sertifikat

```
/etc/haproxy/ssl/
├── vpn.pem          ← gabungan fullchain+privkey (aktif)
├── vpn.self.crt    ← self-signed cert (fallback)
├── vpn.self.key    ← self-signed key  (fallback)
└── vpn.self.pem    ← self-signed gabungan (fallback)
```

#### Self-Signed Fallback

```bash
# Auto-generate saat domain tidak valid / DNS gagal
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
  -subj "/C=ID/ST=Jakarta/L=Jakarta/O=AutoScript/CN=VPS-$(hostname)" \
  -keyout /etc/haproxy/ssl/vpn.self.key \
  -out /etc/haproxy/ssl/vpn.self.crt
cat /etc/haproxy/ssl/vpn.self.crt /etc/haproxy/ssl/vpn.self.key > /etc/haproxy/ssl/vpn.self.pem
ln -sf /etc/haproxy/ssl/vpn.self.pem /etc/haproxy/ssl/vpn.pem
```

#### Auto-Renew (Let's Encrypt)

```bash
# /etc/cron.d/certbot-vpn — setiap 2 hari jam 03:00
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

0 3 */2 * * root certbot renew --quiet --non-interactive && cat /etc/letsencrypt/live/$DOMAIN/fullchain.pem /etc/letsencrypt/live/$DOMAIN/privkey.pem > /etc/haproxy/ssl/vpn.pem && systemctl reload haproxy
```

#### HAProxy SSL Config Final

```haproxy
frontend https-in
  bind :443 ssl crt /etc/haproxy/ssl/vpn.pem alpn h2,http/1.1
  tcp-request inspect-delay 3s
  tcp-request content accept if { req.payload(0,4) -m str SSH- }
  default_backend ws_tunnel_ssl
```

#### Ringkasan SSL

| Kondisi | Sertifikat | Klien |
|---------|-----------|-------|
| Domain valid + DNS ke VPS | Let's Encrypt (valid) | ✅ Trusted, no warning |
| Domain tidak valid / DNS gagal | Self-signed | ⚠️ Warning, tetap jalan |
| Tanpa domain | Self-signed | ⚠️ Warning, tetap jalan |

### 6. Custom Python Raw WebSocket
- **TIDAK pakai library** `websockets` atau `wsproto`
- Manual/raw WebSocket upgrade handling
- Feature:
  - Parse HTTP upgrade header manual (socket + regex)
  - WebSocket handshake raw (SHA1 + base64 accept key)
  - Frame encode/decode manual (RFC 6455)
  - Support berbagai metode payload injection
  - Support berbagai header Upgrade custom
  - Support berbagai path/URI
  - Support proxy-protocol (nginx/haproxy compatible)
  - Frame masking/unmasking
  - Opcode: text, binary, ping, pong, close
  - Fragmentasi frame
  - Buffer management
  - Koneksi ke backend SSH/Dropbear lokal
  - Multi-threading (threading.Thread atau asyncio manual)
  - Rate limit per IP
  - Logging structured
  - HTTP fallback (non-WS request)
- systemd: `ws-tunnel.service`

---

## Protokol yang Didukung di Port 80 & 443

| Mode                 | Port 80 | Port 443 | Cara Kerja                                      |
|----------------------|---------|----------|-------------------------------------------------|
| SSH Direct           | ✅      | ❌       | SSH mentah via TCP, HAProxy sniff "SSH-"         |
| SSH over SSL/TLS     | ❌      | ✅       | SSH dibungkus TLS, HAProxy terminate + sniff     |
| SSH over WS          | ✅      | ❌       | SSH via WebSocket plain, HAProxy sniff "GET...Upgrade" |
| SSH over WSS         | ❌      | ✅       | SSH via WebSocket over TLS, HAProxy terminate     |
| Dropbear Direct      | ✅      | ❌       | Dropbear via port 80 (sniff)                     |
| Dropbear over SSL    | ❌      | ✅       | Dropbear via port 443 (TLS terminate)             |

---

## Struktur File

```
autoscript/
├── install.sh                  ← Main installer
├── lib/
│   ├── common.sh               ← Shared functions
│   ├── 01-dropbear.sh          ← Step 1: SSH utama
│   ├── 02-badvpn.sh            ← Step 2: BadVPN/UDPGW
│   ├── 03-haproxy.sh           ← Step 3: HAProxy + port sharing
│   ├── 04-ws-tunnel.sh         ← Step 4: Python raw WS tunnel
│   ├── 05-firewall.sh          ← Step 5: iptables + Fail2Ban
│   └── 06-users.sh             ← Step 6: User management
├── src/
│   └── ws-tunnel.py            ← Raw WebSocket server (no libraries)
├── bin/
│   └── badvpn-udpgw            ← Precompiled BadVPN binary (x86_64)
├── config/
│   ├── haproxy.cfg             ← HAProxy port sharing config
│   ├── dropbear.default        ← Dropbear config template
│   └── udpgw.service           ← BadVPN systemd unit
└── README.md
```

---

## Detail: Custom Raw WebSocket Python

```python
# ws-tunnel.py — arsitektur
#
# NO external library. Pure Python stdlib only.
#
# Struktur kelas utama:
#
# WSFrame
#   + encode(opcode, payload, mask=False)
#   + decode(raw_bytes) -> (opcode, payload, fin, masked)
#
# WSHandshake
#   + parse_upgrade(request_headers: bytes) -> dict
#   + build_accept_key(client_key: str) -> str
#   + respond(socket, headers: dict) -> bool
#
# WSTunnel
#   + __init__(listen_host, listen_port, backend_host, backend_port)
#   + handle_client(client_socket, client_addr)
#   + pipe_ws_to_tcp(ws_frame_generator, backend_socket)
#   + pipe_tcp_to_ws(backend_socket, ws_sender)
#   + payload_inject(raw_payload, pattern_map: dict) -> bytes
#
# AuthHandler
#   + pam_auth(username, password) -> bool
#   + load_users() -> dict
#
# RateLimiter
#   + check(ip) -> bool
#   + ban(ip, duration)
#
# Logger
#   + log(ip, port, protocol, status, bytes_sent, bytes_recv)
#
# Fitur super fleksibel:
# - Raw payload injection (modify HTTP upgrade header)
# - Custom HTTP path routing (/ws, /ssh, /proxy, bebas)
# - Custom headers (Host, Origin, User-Agent, dll bebas)
# - Support upgrade protokol selain websocket:
#   * ws-epro (HTTP Injector standard)
#   * ws-opvn (OpenVPN over WS)
#   * ws-ssh (SSH over WS — langsung pipe)
# - Buffer/queue per connection
# - Connection pooling
# - Graceful shutdown (SIGTERM handler)
# - Hot reload config (SIGHUP)
```

---

## Skenario Penggunaan HTTP Injector

### Skenario 1: SSH Direct Port 80
```
HTTP Injector config:
  - Host: vps-ip:80
  - Port: 80
  - Payload: (kosong, direct SSH)
```
HAProxy sniff "SSH-" → route ke Dropbear :143

### Skenario 2: SSH over SSL Port 443
```
HTTP Injector config:
  - Host: vps-ip:443
  - Port: 443
  - SSL/TLS: ✅ enable
  - Payload: (kosong, SSH over TLS)
```
HAProxy: Port 443 → TLS terminate → sniff "SSH-" → route ke :143

### Skenario 3: SSH over WebSocket Port 80
```
HTTP Injector config:
  - Host: vps-ip:80
  - Port: 80
  - Payload: GET / HTTP/1.1[crlf]Host: vps-ip[crlf]Upgrade: websocket[crlf][crlf]
```
HAProxy sniff "GET" → deteksi Upgrade → route ke Python WS :8880 → pipe ke Dropbear :143

### Skenario 4: SSH over WSS Port 443
```
HTTP Injector config:
  - Host: vps-ip:443
  - Port: 443
  - SSL/TLS: ✅ enable
  - Payload: GET / HTTP/1.1[crlf]Host: vps-ip[crlf]Upgrade: websocket[crlf][crlf]
```
HAProxy: Port 443 → TLS terminate → deteksi HTTP GET + Upgrade → route ke :8880

---

## Alur Instalasi (User Flow)

```
┌─────────────────────────────────────────────────────┐
│         VPN SSH AUTO INSTALLER                      │
│         ~/proyek/autoscript/install.sh             │
└────────────────────────┬────────────────────────────┘
                         │
                         ▼
              ┌─────────────────────┐
              │ STEP 0: Root Check  │
              │ Gagal → exit        │
              └──────────┬──────────┘
                         │
                         ▼
              ┌────────────────────────────────┐
              │ STEP 1: OS Detection           │
              │ /etc/os-release → Debian/Ubuntu│
              │ Tidak support → exit           │
              └──────────┬─────────────────────┘
                         │
                         ▼
              ┌─────────────────────────────────────┐
              │ STEP 2: Menu Utama (whiptail)        │
              │                                      │
              │ [1] Full Install (Semua)              │
              │ [2] Setup lanjutan                     │
              │ [3] User Management                  │
              │ [4] Service Status                    │
              │ [5] Uninstall                        │
              │ [6] Exit                             │
              └──────────┬──────────────────────────┘
                         │
              ┌──────────┴──────────┐
              ▼                     ▼
    ┌─────────────────┐   ┌─────────────────┐
    │ Full Install    │   │ Per-Komponen    │
    │ (jalan semua)   │   │ (pilih manual)  │
    └────────┬────────┘   └────────┬────────┘
             │                     │
             └──────────┬──────────┘
                        │
                        ▼
              ┌─────────────────────────────────┐
              │ STEP 3: Input Konfigurasi        │
              │                                  │
              │ → Dropbear Port  [default: 143] │
              │ → Dropbear Port  [default: 143] │
              │ → BadVPN Start   [default: 7300]│
              │ → HAProxy Ports  [80, 443]      │
              │ → WS Tunnel Port [default: 8880]│
              │ → Root Login     [yes/no]       │
              │ → Password Auth  [yes/no]       │
              └──────────┬──────────────────────┘
                         │
                         ▼
              ┌─────────────────────────────────┐
              │ STEP 4: Konfigurasi Domain+SSL   │
              │                                  │
              │ "Ada domain?" [y/n]             │
              │                                  │
              │ ├─ n → self-signed cert          │
              │ │       lanjut STEP 5            │
              │ │                                │
              │ └─ y → input domain              │
              │        VALIDASI KETAT:           │
              │        ├─ FQDN valid?            │
              │        ├─ DNS A record ada?      │
              │        ├─ A record = IP VPS?     │
              │        ├─ Port 80 tersedia?      │
              │        │                         │
              │        ├─ SEMUA OK → Let's Encrypt│
              │        │   • generate email acak │
              │        │   • generate nama acak  │
              │        │   • certbot standalone  │
              │        │   • vpn.pem → HAProxy   │
              │        │   • auto-renew cron     │
              │        │                         │
              │        └─ ADA GAGAL → self-signed│
              │            • warning ke user     │
              │            • vpn.self.pem        │
              └──────────┬──────────────────────┘
                         │
                         ▼
              ┌─────────────────────────────────┐
              │ STEP 5: apt update + upgrade     │
              │ (opsional, bisa skip)            │
              └──────────┬──────────────────────┘
                         │
                         ▼
              ┌─────────────────────────────────┐
              │ STEP 6: Konfigurasi layanan       │
              │ Berjalan otomatis setelah tahap 01-05 │
              │                                  │
              │ [6a] User database               │
              │  • initialize /etc/vpn-ssh        │
              │  • initialize user database      │
              │  • setup user expiry             │
              │  • keep Dropbear as SSH utama    │
              │                                  │
              │ [1] Dropbear SSH utama           │
              │  • apt install dropbear          │
              │  • config port 22                │
              │  • generate host keys            │
              │  • restart dropbear              │
              │                                  │
              │ [6c] BadVPN/UDPGW                │
              │  • download bin/badvpn-udpgw     │
              │  • verify SHA-256 + x86_64       │
              │  • cp binary → /usr/local/bin/   │
              │  • systemd service               │
              │                                  │
              │ [6d] HAProxy                     │
              │  • apt install haproxy           │
              │  • backup config lama            │
              │  • tulis haproxy.cfg port sharing│
              │  • symlink vpn.pem               │
              │  • restart haproxy               │
              │                                  │
              │ [6e] Python WS Tunnel            │
              │  • deploy ws-tunnel.py → /opt/   │
              │  • test Python3 deps (stdlib ok) │
              │  • systemd service ws-tunnel     │
              │  • start + enable                │
              └──────────┬──────────────────────┘
                         │
                         ▼
              ┌─────────────────────────────────┐
              │ STEP 7: Firewall + Fail2Ban      │
              │                                  │
              │ Provider firewall:                │
              │  • port diatur via portal VPS     │
              │  • UFW tidak dipasang             │
              │                                  │
              │ Fail2Ban:                        │
              │  • jail sshd (maxretry 4)        │
              │  • jail dropbear (maxretry 4)    │
              │  • restart fail2ban              │
              │                                  │
              │ iptables:                        │
              │  • rate limit 10 conn/sec/IP     │
              │  • drop invalid packets          │
              └──────────┬──────────────────────┘
                         │
                         ▼
              ┌─────────────────────────────────┐
              │ STEP 8: User Trial               │
              │                                  │
              │ "Buat user trial?" [y/n]        │
              │  ├─ y → pilih durasi:            │
              │  │       1) 2 jam                │
              │  │       2) 1 hari               │
              │  │       3) 3 hari               │
              │  │       4) 7 hari               │
              │  │       5) Custom               │
              │  │                                │
              │  │       generate random username │
              │  │       generate random password │
              │  │       set expire date          │
              │  │       cron auto-delete expired │
              │  │                                │
              │  └─ n → skip                     │
              └──────────┬──────────────────────┘
                         │
                         ▼
              ┌─────────────────────────────────┐
              │ STEP 9: Verifikasi + Ringkasan   │
              │                                  │
              │ • Cek semua service status:      │
              │   systemctl status ssh           │
              │   systemctl status dropbear      │
              │   systemctl status udpgw         │
              │   systemctl status haproxy       │
              │   systemctl status ws-tunnel     │
              │   systemctl status fail2ban      │
              │                                  │
              │ • Cek port listening:            │
              │   netstat -tlnp                  │
              │                                  │
              │ • Tampilkan ringkasan:           │
              │   ┌────────────────────┐         │
              │   │ INSTALL SELESAI     │         │
              │   │ IP    : xxx.xxx.xx │         │
              │   │ SSH   : 22,80,443  │         │
              │   │ Drop  : 143,80,443 │         │
              │   │ WS    : 80,443     │         │
              │   │ UDPGW : 7300-7399  │         │
              │   │ SSL   : valid/self │         │
              │   │ Domain: vpn.xxx.id │         │
              │   │ User  : abc / pass │         │
              │   └────────────────────┘         │
              │                                  │
              │ • Tanya restart VPS (opsional)    │
              └──────────────────────────────────┘
```

## Mode Eksekusi

`install.sh` hanya punya satu alur. Saat dipanggil, bootstrap mengunduh runtime dari GitHub lalu menjalankan semua tahap berurutan `01` sampai `06` tanpa menu, subcommand, atau opsi.

```bash
curl -fsSL https://raw.githubusercontent.com/vanta12/sc-ssh/main/install.sh | sudo bash
```

Installer memakai konfigurasi default tetap: Dropbear `143`, BadVPN `7300`, WS `8880`, HAProxy `80/443`.

Urutan setup:

```text
01 Dropbear (SSH utama)
02 BadVPN/UDPGW
03 HAProxy
04 WebSocket tunnel
05 iptables + Fail2Ban
06 User database
```

## Timeline Pengerjaan

| Tahap                         | Estimasi |
|-------------------------------|----------|
| 1. Library + Menu             | 1 jam    |
| 2. Dropbear module            | 30 menit |
| 3. Dropbear module            | 30 menit |
| 4. BadVPN binary + service    | 15 menit |
| 5. HAProxy + port sharing     | 1.5 jam  |
| 6. Python raw WS tunnel       | 2 jam    |
| 7. Firewall + Fail2Ban        | 30 menit |
| 8. User management            | 30 menit |
| 9. Testing + Fix              | 1 jam    |
| **Total**                     | **~8 jam** |

---

## Keamanan

- HAProxy: `req.payload()` sniffing, bukan regex rentan
- HAProxy: maxconn 500 per backend
- Fail2Ban: 3 retry → 600s ban
- iptables rate limit: 10 conn/sec per IP
- Inbound port policy: portal web provider VPS; UFW tidak dipasang
- WS tunnel rate limit: 30 req/menit per IP
- TLS cert auto-regenerate setiap 90 hari
- Log rotation (logrotate)

---

## Hasil Akhir

1. `~/proyek/autoscript/install.sh` — main installer
2. Bootstrap mengunduh semua module `lib/`, source `src/`, dan binary BadVPN dari GitHub
3. File konfigurasi template
4. Semua service running via systemd
5. README.md dengan cara pakai HTTP Injector