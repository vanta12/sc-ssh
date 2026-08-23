# VPN SSH Auto Installer

Installer otomatis untuk VPN server berbasis SSH —
mendukung multi-protocol sharing di port 80 & 443.

## Komponen

| Komponen | Port Internal | Deskripsi |
|----------|--------------|-----------|
| OpenSSH | 22 | SSH server utama + hardening |
| Dropbear | 143 | Lightweight SSH daemon |
| BadVPN/UDPGW | 7300-7399 | UDP tunnel (game/streaming) |
| HAProxy | 80, 443 | Port sharing + SSL termination |
| Python WS Tunnel | 8880 | Custom raw WebSocket (no dependencies) |
| Fail2Ban | — | Brute-force protection |
| UFW | — | Firewall |

## Mode Koneksi (Port 80 & 443)

| Mode | Port 80 | Port 443 | Keterangan |
|------|---------|----------|------------|
| SSH Direct | ✅ | ❌ | SSH mentah via TCP |
| SSH over SSL | ❌ | ✅ | SSH dibungkus TLS |
| SSH over WS | ✅ | ❌ | SSH via WebSocket plain |
| SSH over WSS | ❌ | ✅ | SSH via WebSocket over TLS |

## Cara Pakai

### Install interaktif
```bash
cd ~/proyek/autoscript
sudo bash install.sh
```

### Full auto
```bash
sudo bash install.sh --full-auto --domain vpn.example.com
```

### Install per-komponen
```bash
sudo bash install.sh --component ssh
sudo bash install.sh --component dropbear
sudo bash install.sh --component badvpn
sudo bash install.sh --component haproxy --domain vpn.example.com
sudo bash install.sh --component ws-tunnel
sudo bash install.sh --component firewall
```

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
│   ├── 01-openssh.sh    ← Step 1: OpenSSH
│   ├── 02-dropbear.sh   ← Step 2: Dropbear
│   ├── 03-badvpn.sh     ← Step 3: BadVPN/UDPGW
│   ├── 04-haproxy.sh    ← Step 4: HAProxy + SSL
│   ├── 05-ws-tunnel.sh  ← Step 5: Python WS tunnel
│   ├── 06-firewall.sh   ← Step 6: Fail2Ban/firewall
│   └── 07-users.sh      ← Step 7: User management
├── src/
│   └── ws-tunnel.py     ← Raw WebSocket server (pure stdlib)
├── config/              ← Config templates
├── tests/               ← Test scripts
└── README.md
```

## User Management

```bash
# Buat user trial
sudo bash install.sh --component users user-create 24  # 24 jam

# List user
sudo bash install.sh --component users user-list

# Delete user
sudo bash install.sh --component users user-delete nama_user

# Menu interaktif
sudo bash install.sh  # pilih [3] User Management
```

## Keamanan

- Fail2Ban active (4 retry → ban 1 jam)
- iptables rate limit (10 conn/menit per IP)
- UFW firewall
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