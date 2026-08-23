#!/usr/bin/env bash
# ============================================================
#  ws-tunnel.sh — Deploy Python raw WebSocket tunnel
# ============================================================

ws_tunnel_install() {
    local listen_port="${1:-8880}"
    local backend_host="${2:-127.0.0.1}"
    local backend_port="${3:-22}"

    section "Installing Python WebSocket Tunnel"

    # Check Python3
    if ! command -v python3 &>/dev/null; then
        install_pkg python3
    fi

    local deploy_dir="/opt/vpn-ssh"
    mkdir -p "$deploy_dir"

    # Find ws-tunnel.py source
    local src
    src="$(dirname "$(dirname "$(readlink -f "$0")")")/src/ws-tunnel.py"
    # Fallback: look alongside installer
    [ -f "$src" ] || src="$(dirname "$(readlink -f "$0")")/../src/ws-tunnel.py"
    [ -f "$src" ] || src="./src/ws-tunnel.py"

    if [ ! -f "$src" ]; then
        warn "ws-tunnel.py source tidak ditemukan di $src"
        # Generate inline if source not found
        log "Generating ws-tunnel.py inline..."
        cat > "$deploy_dir/ws-tunnel.py" <<'PYEOF'
#!/usr/bin/env python3
""" Raw WebSocket Tunnel — no external libraries """
import socket, struct, hashlib, base64, threading, sys, os, json, time, signal

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 8880
BACKEND_HOST = "127.0.0.1"
BACKEND_PORT = 22
MAX_CLIENTS = 500
RATE_LIMIT = 30
RATE_WINDOW = 60
TIMEOUT = 3600

clients = {}
rate_map = {}
lock = threading.Lock()

def sha1_key(key):
    GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    return base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()

def decode_frame(data):
    if len(data) < 2: return None, None, False, False, b""
    b0, b1 = data[0], data[1]
    fin = bool(b0 & 0x80)
    opcode = b0 & 0x0F
    masked = bool(b1 & 0x80)
    length = b1 & 0x7F
    offset = 2
    if length == 126:
        if len(data) < 4: return None, None, fin, masked, b""
        length = struct.unpack(">H", data[2:4])[0]
        offset = 4
    elif length == 127:
        if len(data) < 10: return None, None, fin, masked, b""
        length = struct.unpack(">Q", data[2:10])[0]
        offset = 10
    mask_key = data[offset:offset+4] if masked else b""
    if masked: offset += 4
    if len(data) < offset + length: return None, None, fin, masked, b""
    payload = data[offset:offset+length]
    if masked:
        payload = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))
    return opcode, payload, fin, masked, data[offset+length:]

def encode_frame(opcode, payload, mask=False):
    frame = bytearray()
    frame.append(0x80 | (opcode & 0x0F))
    length = len(payload)
    if length < 126:
        frame.append(length | (0x80 if mask else 0x00))
    elif length < 65536:
        frame.append(126 | (0x80 if mask else 0x00))
        frame.extend(struct.pack(">H", length))
    else:
        frame.append(127 | (0x80 if mask else 0x00))
        frame.extend(struct.pack(">Q", length))
    if mask:
        import random
        mk = bytes(random.randint(0, 255) for _ in range(4))
        frame.extend(mk)
        payload = bytes(b ^ mk[i % 4] for i, b in enumerate(payload))
    frame.extend(payload)
    return bytes(frame)

def do_handshake(sock):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk: return False, {}
        data += chunk
    headers_text = data[:data.index(b"\r\n\r\n")].decode("utf-8", errors="replace")
    headers = {}
    key = None
    for line in headers_text.split("\r\n"):
        if ": " in line:
            k, v = line.split(": ", 1)
            headers[k.lower().strip()] = v.strip()
            if k.lower().strip() == "sec-websocket-key":
                key = v.strip()
    if not key: return False, {"error": "no websocket key"}
    accept = sha1_key(key)
    response = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n"
        "\r\n"
    )
    sock.sendall(response.encode())
    remaining = data[data.index(b"\r\n\r\n")+4:]
    return True, {"headers": headers, "remaining": remaining}

def rate_check(ip):
    now = time.time()
    with lock:
        if ip not in rate_map: rate_map[ip] = []
        rate_map[ip] = [t for t in rate_map[ip] if now - t < RATE_WINDOW]
        if len(rate_map[ip]) >= RATE_LIMIT: return False
        rate_map[ip].append(now)
        return True

def handle(client_sock, addr):
    ip = addr[0]
    if not rate_check(ip):
        client_sock.close(); return
    ok, result = do_handshake(client_sock)
    if not ok:
        client_sock.close(); return
    try:
        backend = socket.create_connection((BACKEND_HOST, BACKEND_PORT), timeout=5)
    except:
        client_sock.close(); return
    remaining = result.get("remaining", b"")
    if remaining: backend.sendall(remaining)
    def pipe(src, dst, name):
        buf = b""
        try:
            while True:
                data = src.recv(8192)
                if not data: break
                buf += data
                while True:
                    opcode, payload, fin, m, rest = decode_frame(buf)
                    if opcode is None: break
                    if opcode == 0x8: return
                    if opcode == 0x9:
                        src.sendall(encode_frame(0xA, payload))
                    elif opcode in (0x1, 0x2):
                        dst.sendall(payload)
                    buf = rest
        except: pass
        finally:
            try: src.close()
            except: pass
            try: dst.close()
            except: pass
    t1 = threading.Thread(target=pipe, args=(client_sock, backend, "c2b"), daemon=True)
    t2 = threading.Thread(target=pipe, args=(backend, client_sock, "b2c"), daemon=True)
    t1.start(); t2.start()
    t1.join(timeout=TIMEOUT); t2.join(timeout=TIMEOUT)
    try: client_sock.close()
    except: pass
    try: backend.close()
    except: pass

def main():
    global LISTEN_HOST, LISTEN_PORT, BACKEND_HOST, BACKEND_PORT
    LISTEN_HOST = os.environ.get("WS_HOST", LISTEN_HOST)
    LISTEN_PORT = int(os.environ.get("WS_PORT", LISTEN_PORT))
    BACKEND_HOST = os.environ.get("WS_BACKEND_HOST", BACKEND_HOST)
    BACKEND_PORT = int(os.environ.get("WS_BACKEND_PORT", BACKEND_PORT))
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((LISTEN_HOST, LISTEN_PORT))
    server.listen(MAX_CLIENTS)
    def shutdown(sig, frame):
        server.close(); sys.exit(0)
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    while True:
        try:
            csock, addr = server.accept()
            threading.Thread(target=handle, args=(csock, addr), daemon=True).start()
        except KeyboardInterrupt: break
        except: pass

if __name__ == "__main__":
    main()
PYEOF
        chmod +x "$deploy_dir/ws-tunnel.py"
    else
        cp "$src" "$deploy_dir/ws-tunnel.py"
        chmod +x "$deploy_dir/ws-tunnel.py"
    fi

    log "WebSocket tunnel deployed to $deploy_dir/ws-tunnel.py"

    # Create systemd service
    cat > /etc/systemd/system/ws-tunnel.service <<SYSTEMD
[Unit]
Description=Custom Python WebSocket Tunnel
After=network.target

[Service]
Type=simple
Environment="WS_HOST=127.0.0.1"
Environment="WS_PORT=${listen_port}"
Environment="WS_BACKEND_HOST=${backend_host}"
Environment="WS_BACKEND_PORT=${backend_port}"
ExecStart=/usr/bin/python3 /opt/vpn-ssh/ws-tunnel.py
Restart=always
RestartSec=3
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
SyslogIdentifier=ws-tunnel

[Install]
WantedBy=multi-user.target
SYSTEMD

    enable_service ws-tunnel

    if port_in_use "$listen_port"; then
        log "WS Tunnel running on port $listen_port ✓"
    else
        warn "WS Tunnel mungkin tidak listen — cek: systemctl status ws-tunnel"
    fi
}