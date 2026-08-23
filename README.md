# VPN SSH Auto Installer

Installer otomatis untuk VPN server berbasis SSH —
mendukung multi-protocol sharing di port 80 & 443.

## Komponen

| Komponen | Port Internal | Deskripsi |
|----------|--------------|-----------|
| Dropbear | 143 | SSH server utama + hardening |
| BadVPN/UDPGW | 7300/UDP | Precompiled UDP tunnel binary |
| HAProxy | 80, 443 | Port sharing + SSL termination |
| Python WS Tunnel | 8880 | Custom raw WebSocket (no dependencies) |
| iptables + Fail2Ban | — | Rate limit dan brute-force protection |

## Mode Koneksi (Port 80 & 443)

| Mode | Port 80 | Port 443 | Keterangan |
|------|---------|----------|------------|
| SSH Direct | ✅ | ❌ | SSH mentah via TCP |
| SSH over SSL | ❌ | ✅ | SSH dibungkus TLS |
| SSH over WS | ✅ | ❌ | SSH via WebSocket plain |
| SSH over WSS | ❌ | ✅ | SSH via WebSocket over TLS |

## Cara Pakai

### One-click install
```bash
curl -fsSL https://raw.githubusercontent.com/vanta12/sc-ssh/main/install.sh | sudo bash
```

Saat dijalankan, `install.sh` selalu mengunduh `lib/`, `src/`, dan `bin/badvpn-udpgw` dari branch `main`, lalu menjalankan setup berurutan:

```text
01 Dropbear (SSH utama)
02 BadVPN/UDPGW
03 HAProxy
04 WebSocket tunnel
05 iptables + Fail2Ban
06 User database
```

Binary BadVPN diverifikasi dengan SHA-256 dan saat ini tersedia untuk `x86_64/amd64`. Installer memakai konfigurasi default tetap; tidak ada subcommand atau opsi instalasi.

## Konfigurasi di HTTP Injector

### SSH Direct (Port 80)
- Host: `IP_VPS:80`
- Port: 80
- Payload: (kosong)

### SSH over SSL (Port 443)
- Host: `IP_VPS:443`
- Port: 443
- SSL/TLS: ✅ Enable
- Payload: (kosong)

### SSH over WebSocket (Port 80)
- Host: `IP_VPS:80`
- Port: 80
- Payload: `GET / HTTP/1.1[crlf]Host: IP_VPS[crlf]Upgrade: websocket[crlf][crlf]`

### SSH over WSS (Port 443)
- Host: `IP_VPS:443`
- Port: 443
- SSL/TLS: ✅ Enable
- Payload: `GET / HTTP/1.1[crlf]Host: IP_VPS[crlf]Upgrade: websocket[crlf][crlf]`

## Struktur Folder

```
autoscript/
├── install.sh           ← Main installer
├── lib/
│   ├── common.sh        ← Shared functions
│   ├── 01-dropbear.sh   ← Step 1: SSH utama
│   ├── 02-badvpn.sh     ← Step 2: BadVPN/UDPGW
│   ├── 03-haproxy.sh    ← Step 3: HAProxy + SSL
│   ├── 04-ws-tunnel.sh  ← Step 4: Python WS tunnel
│   ├── 05-firewall.sh   ← Step 5: iptables + Fail2Ban
│   └── 06-users.sh      ← Step 6: User database
├── src/
│   └── ws-tunnel.py     ← Raw WebSocket server (pure stdlib)
├── bin/
│   └── badvpn-udpgw      ← Precompiled BadVPN UDPGW (x86_64)
├── config/              ← Config templates
├── tests/               ← Test scripts
└── README.md
```

## User Management

User database diinisialisasi otomatis pada tahap `06-users.sh`. Dropbear menjadi satu-satunya SSH server.

## Keamanan

- Fail2Ban active (4 retry → ban 1 jam)
- iptables rate limit (10 conn/menit per IP)
- Port/firewall network diatur lewat portal web provider VPS
- SSH hardening (no empty password, max auth tries, banner)
- TLS 1.2+ only (HAProxy)
- RSA 4096-bit certs
- Auto-ban IP di WS tunnel setelah rate limit

## Persyaratan

| Item | Minimal |
|------|---------|
| OS | Debian 10+ / Ubuntu 20.04+ |
| RAM | 256 MB |
| Storage | 3 GB |
| Kernel | 4.x+ |

## Log

Semua log disimpan di: `/var/log/vpn-install.log`