#!/usr/bin/env python3
"""
Raw WebSocket Tunnel Server — NO external libraries.
Pure Python stdlib only. Implementation mengikuti RFC 6455.

Mendukung:
- WebSocket handshake manual (SHA1 + base64)
- Frame encode/decode manual (semua opcode)
- Multi-threading (threading.Thread)
- Rate limiting per IP
- Backend forwarding ke SSH/Dropbear lokal
- Graceful shutdown (SIGTERM/SIGINT)
- Structured JSON logging
- Custom HTTP upgrade header parsing
- Fragmentasi frame
- Ping/Pong keepalive
- Masking/unmasking payload
"""

import socket
import struct
import hashlib
import base64
import threading
import sys
import os
import json
import time
import signal
import re

# ── Configuration ─────────────────────────────────────────
LISTEN_HOST = os.environ.get("WS_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("WS_PORT", "8880"))
BACKEND_HOST = os.environ.get("WS_BACKEND_HOST", "127.0.0.1")
BACKEND_PORT = int(os.environ.get("WS_BACKEND_PORT", "22"))
MAX_CLIENTS = int(os.environ.get("WS_MAX_CLIENTS", "500"))
RATE_LIMIT = int(os.environ.get("WS_RATE_LIMIT", "30"))
RATE_WINDOW = int(os.environ.get("WS_RATE_WINDOW", "60"))
TIMEOUT = int(os.environ.get("WS_TIMEOUT", "3600"))
BUFFER_SIZE = int(os.environ.get("WS_BUFFER", "8192"))
MAX_HEADER_SIZE = int(os.environ.get("WS_MAX_HEADER", "16384"))
MAX_FRAME_SIZE = int(os.environ.get("WS_MAX_FRAME", "2097152"))
HANDSHAKE_TIMEOUT = int(os.environ.get("WS_HANDSHAKE_TIMEOUT", "15"))
LOG_FILE = os.environ.get("WS_LOG", "/opt/autoscript/logs/ws-tunnel.log")

# ── Globals ───────────────────────────────────────────────
clients = {}
rate_map = {}
lock = threading.Lock()
client_slots = threading.BoundedSemaphore(MAX_CLIENTS)
running = True

# ── Logging ───────────────────────────────────────────────
def log(level, msg, **kwargs):
    entry = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "level": level,
        "msg": msg,
        **kwargs
    }
    print(json.dumps(entry), flush=True)
    if LOG_FILE:
        try:
            with open(LOG_FILE, "a") as f:
                f.write(json.dumps(entry) + "\n")
        except Exception:
            pass

# ── WebSocket Utilities ───────────────────────────────────
WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

OP_CONT  = 0x0  # continuation
OP_TEXT  = 0x1  # text frame
OP_BIN   = 0x2  # binary frame
OP_CLOSE = 0x8  # close
OP_PING  = 0x9  # ping
OP_PONG  = 0xA  # pong

def ws_accept_key(client_key):
    """Generate Sec-WebSocket-Accept key."""
    sha1 = hashlib.sha1((client_key + WS_MAGIC).encode()).digest()
    return base64.b64encode(sha1).decode()

def decode_frame(data):
    """
    Decode a single WebSocket frame.
    Returns (opcode, payload, is_fin, is_masked, remaining_bytes)
    Returns (None, None, None, None, data) if incomplete.
    """
    if len(data) < 2:
        return (None, None, None, None, b"", data)

    byte0 = data[0]
    byte1 = data[1]

    is_fin = bool(byte0 & 0x80)
    opcode = byte0 & 0x0F
    is_masked = bool(byte1 & 0x80)
    payload_len = byte1 & 0x7F

    offset = 2

    if payload_len == 126:
        if len(data) < 4:
            return (None, None, None, None, b"", data)
        payload_len = struct.unpack(">H", data[2:4])[0]
        offset = 4
    elif payload_len == 127:
        if len(data) < 10:
            return (None, None, None, None, b"", data)
        payload_len = struct.unpack(">Q", data[2:10])[0]
        offset = 10

    mask_key = b""
    if is_masked:
        if len(data) < offset + 4:
            return (None, None, None, None, b"", data)
        mask_key = data[offset:offset + 4]
        offset += 4

    if payload_len > MAX_FRAME_SIZE:
        return ("TOO_LARGE", None, is_fin, is_masked, b"")

    total_len = offset + payload_len
    if len(data) < total_len:
        return (None, None, None, None, b"", data)

    payload = data[offset:total_len]
    remaining = data[total_len:]

    if is_masked and mask_key:
        payload = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))

    return (opcode, payload, is_fin, is_masked, remaining)


def encode_frame(opcode, payload, is_fin=True, mask=False):
    """Encode a single WebSocket frame. Client→Server frames are masked."""
    frame = bytearray()
    first_byte = opcode & 0x0F
    if is_fin:
        first_byte |= 0x80
    frame.append(first_byte)

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
        import random as _rand
        mk = bytes(_rand.randint(0, 255) for _ in range(4))
        frame.extend(mk)
        payload = bytes(b ^ mk[i % 4] for i, b in enumerate(payload))

    frame.extend(payload)
    return bytes(frame)


# ── Handshake Parsing ─────────────────────────────────────
def parse_request(raw):
    """
    Parse raw HTTP upgrade request.
    Returns dict with: method, path, headers, body, raw_headers_text
    """
    result = {"method": "", "path": "", "headers": {}, "body": b"", "raw": raw}

    # Split headers and body
    parts = raw.split(b"\r\n\r\n", 1)
    header_block = parts[0]
    result["body"] = parts[1] if len(parts) > 1 else b""

    lines = header_block.split(b"\r\n")
    if not lines:
        return result

    # First line: METHOD PATH PROTO
    first = lines[0].decode("utf-8", errors="replace")
    match = re.match(r"^(\S+)\s+(\S+)\s+HTTP", first)
    if match:
        result["method"] = match.group(1)
        result["path"] = match.group(2)

    # Headers
    for line in lines[1:]:
        try:
            text = line.decode("utf-8", errors="replace")
            if ": " in text:
                k, v = text.split(": ", 1)
                result["headers"][k.lower().strip()] = v.strip()
        except Exception:
            pass

    result["raw_headers_text"] = header_block.decode("utf-8", errors="replace")
    return result


def do_handshake(sock):
    """
    Perform WebSocket handshake.
    Returns (success: bool, remaining_bytes: bytes, req: dict)
    """
    previous_timeout = sock.gettimeout()
    sock.settimeout(HANDSHAKE_TIMEOUT)
    data = b""
    while b"\r\n\r\n" not in data:
        if len(data) >= MAX_HEADER_SIZE:
            return (False, b"", {"error": "headers too large"})
        try:
            chunk = sock.recv(min(4096, MAX_HEADER_SIZE - len(data)))
        except Exception:
            return (False, b"", {"error": "recv failed"})
        if not chunk:
            return (False, b"", {"error": "connection closed"})
        data += chunk

    # Parse request
    header_end = data.index(b"\r\n\r\n") + 4
    raw_headers = data[:header_end]
    remaining = data[header_end:]
    req = parse_request(raw_headers)

    # Check for WebSocket upgrade
    upgrade = req["headers"].get("upgrade", "").lower()
    connection = req["headers"].get("connection", "").lower()
    version = req["headers"].get("sec-websocket-version", "")
    if req.get("method") != "GET" or "websocket" not in upgrade or "upgrade" not in connection:
        return (False, remaining, {"error": "invalid websocket upgrade", "req": req})
    if version and version != "13":
        return (False, remaining, {"error": "unsupported websocket version", "req": req})

    client_key = req["headers"].get("sec-websocket-key", "")
    if not client_key:
        sock.settimeout(previous_timeout)
        return (False, remaining, {"error": "missing sec-websocket-key"})

    # Build response
    accept = ws_accept_key(client_key)
    response = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n"
        "\r\n"
    )

    try:
        sock.sendall(response.encode())
    except Exception:
        sock.settimeout(previous_timeout)
        return (False, remaining, {"error": "send response failed"})

    sock.settimeout(previous_timeout)
    return (True, remaining, req)


# ── Rate Limiter ──────────────────────────────────────────
def rate_check(ip):
    now = time.time()
    with lock:
        if ip not in rate_map:
            rate_map[ip] = []
        # Clean old entries
        rate_map[ip] = [t for t in rate_map[ip] if now - t < RATE_WINDOW]
        if len(rate_map[ip]) >= RATE_LIMIT:
            return False
        rate_map[ip].append(now)
        return True

def ban_ip(ip, duration=300):
    """Track banned IPs."""
    log("warn", f"IP banned: {ip}", ip=ip, duration=duration)
    with lock:
        # Simple: store ban time
        rate_map[f"banned:{ip}"] = [time.time() + duration]

def is_banned(ip):
    with lock:
        key = f"banned:{ip}"
        if key in rate_map:
            now = time.time()
            if rate_map[key] and rate_map[key][0] > now:
                return True
            else:
                del rate_map[key]
        return False


# ── Connection Handler ────────────────────────────────────
def pipe_ws_to_tcp(client_sock, backend_sock, direction):
    """
    Direction: 'c2b' (client→backend) or 'b2c' (backend→client)
    """
    buf = b""
    other = "c2b" if direction == "b2c" else "b2c"

    try:
        while running:
            if direction == "c2b":
                src, dst = client_sock, backend_sock
            else:
                src, dst = backend_sock, client_sock

            try:
                chunk = src.recv(BUFFER_SIZE)
            except (socket.timeout, ConnectionError, OSError):
                break
            if not chunk:
                break

            if direction == "c2b":
                # Client → Backend: decode WS frames → raw TCP
                buf += chunk
                while True:
                    opcode, payload, is_fin, is_masked, remaining = decode_frame(buf)
                    if opcode is None:
                        break
                    if opcode == "TOO_LARGE":
                        log("warn", "WebSocket frame too large", ip="unknown")
                        return
                    buf = remaining

                    if is_masked is False and opcode != OP_CLOSE:
                        continue

                    if opcode == OP_CLOSE:
                        return
                    elif opcode == OP_PING:
                        # Respond with pong
                        pong = encode_frame(OP_PONG, payload)
                        client_sock.sendall(pong)
                    elif opcode in (OP_TEXT, OP_BIN):
                        try:
                            dst.sendall(payload)
                        except Exception:
                            return
                    elif opcode == OP_CONT:
                        try:
                            dst.sendall(payload)
                        except Exception:
                            return
            else:
                # Backend → Client: raw TCP → encode WS frames
                frame = encode_frame(OP_BIN, chunk)
                try:
                    dst.sendall(frame)
                except Exception:
                    break

    except Exception as e:
        log("debug", f"pipe error [{direction}]", error=str(e))
    finally:
        pass


def handle_client(client_sock, addr):
    try:
        _handle_client(client_sock, addr)
    finally:
        client_slots.release()


def _handle_client(client_sock, addr):
    ip = addr[0]
    port = addr[1]

    # Rate check
    if not rate_check(ip) or is_banned(ip):
        log("warn", f"Rate limited", ip=ip, port=port)
        client_sock.close()
        return

    # Auth fail counter
    auth_fails = 0

    # WebSocket handshake
    ok, remaining, req = do_handshake(client_sock)
    if not ok:
        log("info", f"Handshake failed", ip=ip, reason=req.get("error", "unknown"))
        client_sock.close()
        return

    log("info", f"Client connected",
        ip=ip,
        method=req.get("method", ""),
        path=req.get("path", ""),
        headers=req.get("headers", {}))

    # Connect to backend
    try:
        backend_sock = socket.create_connection(
            (BACKEND_HOST, BACKEND_PORT), timeout=5
        )
        backend_sock.settimeout(None)
    except Exception as e:
        log("error", f"Backend connect failed", ip=ip, error=str(e))
        close_frame = encode_frame(OP_CLOSE, struct.pack(">H", 1011))
        try:
            client_sock.sendall(close_frame)
        except Exception:
            pass
        client_sock.close()
        return

    # Forward any remaining bytes from handshake to backend
    if remaining:
        try:
            backend_sock.sendall(remaining)
        except Exception:
            pass

    # Create pipe threads
    t_c2b = threading.Thread(
        target=pipe_ws_to_tcp,
        args=(client_sock, backend_sock, "c2b"),
        daemon=True
    )
    t_b2c = threading.Thread(
        target=pipe_ws_to_tcp,
        args=(client_sock, backend_sock, "b2c"),
        daemon=True
    )

    t_c2b.start()
    t_b2c.start()

    # Wait with timeout
    t_c2b.join(timeout=TIMEOUT)
    t_b2c.join(timeout=TIMEOUT)

    # Cleanup
    try:
        client_sock.close()
    except Exception:
        pass
    try:
        backend_sock.close()
    except Exception:
        pass

    log("info", f"Client disconnected", ip=ip)


# ── Main Server ───────────────────────────────────────────
def main():
    global running

    log("info", "WS Tunnel starting",
        listen=f"{LISTEN_HOST}:{LISTEN_PORT}",
        backend=f"{BACKEND_HOST}:{BACKEND_PORT}",
        max_clients=MAX_CLIENTS,
        rate_limit=RATE_LIMIT,
        rate_window=RATE_WINDOW)

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)

    # TCP keepalive tuning
    server.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 60)
    server.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 10)
    server.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 5)

    try:
        server.bind((LISTEN_HOST, LISTEN_PORT))
    except OSError as e:
        log("error", f"Bind failed: {e}")
        sys.exit(1)

    server.listen(MAX_CLIENTS)

    def graceful_shutdown(signum, frame):
        global running
        log("info", f"Shutting down (signal {signum})...")
        running = False
        try:
            server.close()
        except Exception:
            pass

    signal.signal(signal.SIGTERM, graceful_shutdown)
    signal.signal(signal.SIGINT, graceful_shutdown)

    while running:
        try:
            client_sock, addr = server.accept()
            if not client_slots.acquire(blocking=False):
                client_sock.close()
                continue
            client_sock.settimeout(TIMEOUT)
            try:
                t = threading.Thread(
                    target=handle_client,
                    args=(client_sock, addr),
                    daemon=True
                )
                t.start()
            except Exception:
                client_slots.release()
                client_sock.close()
                raise
            log("debug", f"Active threads: {threading.active_count()}")
        except socket.timeout:
            continue
        except OSError:
            if not running:
                break
        except Exception as e:
            log("error", f"Accept error: {e}")
            continue

    log("info", "WS Tunnel stopped")
    sys.exit(0)


if __name__ == "__main__":
    main()