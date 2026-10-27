#!/usr/bin/env bash
# Exercise the Janus WebSocket JSON API only inside the existing isolated test container.
# Does not call or modify the host-network production janus-gateway.
set -euo pipefail

container=janus-v143-securetest
status=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || true)
if [[ "$status" != running ]]; then
  echo "FAIL: isolated test container $container is not running" >&2
  exit 1
fi

docker exec -i "$container" python3 - <<'PY'
import base64
import hashlib
import json
import os
import socket
import struct

def exact(stream, length):
    data = stream.read(length)
    if data is None or len(data) != length:
        raise RuntimeError("Unexpected end of WebSocket connection")
    return data

with socket.create_connection(("127.0.0.1", 8188), timeout=6) as sock:
    sock.settimeout(6)
    stream = sock.makefile("rb")
    key = base64.b64encode(os.urandom(16)).decode()
    request = (
        "GET / HTTP/1.1\r\n"
        "Host: 127.0.0.1:8188\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Protocol: janus-protocol\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    sock.sendall(request.encode())
    status_line = stream.readline().decode().strip()
    headers = {}
    while True:
        line = stream.readline().decode().strip()
        if not line:
            break
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.lower()] = v.strip()

    if " 101 " not in status_line:
        raise RuntimeError(f"WebSocket upgrade failed: {status_line}")
    expected_accept = base64.b64encode(hashlib.sha1(
        (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
    ).digest()).decode()
    if headers.get("sec-websocket-accept") != expected_accept:
        raise RuntimeError("Invalid WebSocket accept response")
    print("PASS: Janus WebSocket protocol handshake")

    def send_json(obj):
        payload = json.dumps(obj, separators=(",", ":")).encode()
        mask = os.urandom(4)
        length = len(payload)
        if length < 126:
            size = bytes([0x81, 0x80 | length])
        elif length < 65536:
            size = bytes([0x81, 0x80 | 126]) + struct.pack("!H", length)
        else:
            size = bytes([0x81, 0x80 | 127]) + struct.pack("!Q", length)
        masked = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))
        sock.sendall(size + mask + masked)

    def receive_json():
        while True:
            first, second = exact(stream, 2)
            opcode = first & 0x0f
            length = second & 0x7f
            if length == 126:
                length = struct.unpack("!H", exact(stream, 2))[0]
            elif length == 127:
                length = struct.unpack("!Q", exact(stream, 8))[0]
            if second & 0x80:
                mask = exact(stream, 4)
            else:
                mask = None
            payload = exact(stream, length)
            if mask is not None:
                payload = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))
            if opcode == 8:
                raise RuntimeError("Janus closed the WebSocket connection")
            if opcode != 1:
                raise RuntimeError(f"Unexpected WebSocket opcode: {opcode}")
            return json.loads(payload)

    counter = 0

    def call(data):
        global counter
        counter += 1
        transaction = f"isolated-api-test-{counter}"
        data["transaction"] = transaction
        send_json(data)
        for _ in range(10):
            reply = receive_json()
            if reply.get("transaction") == transaction:
                if reply.get("janus") != "success":
                    raise RuntimeError(f"Janus API rejected request: {reply}")
                return reply
        raise RuntimeError(f"No reply for transaction {transaction}")

    session_id = None
    try:
        response = call({"janus": "create"})
        session_id = response["data"]["id"]
        print("PASS: Janus session created")
        for plugin in ("janus.plugin.videoroom", "janus.plugin.textroom"):
            response = call({
                "janus": "attach",
                "session_id": session_id,
                "plugin": plugin
            })
            if not isinstance(response.get("data", {}).get("id"), int):
                raise RuntimeError(f"Missing handle ID for {plugin}")
            print(f"PASS: Plugin attached: {plugin}")
    finally:
        if session_id is not None:
            call({"janus": "destroy", "session_id": session_id})
            print("PASS: Test session destroyed")

    stream.close()
    print("PASS: Isolated Janus WebSocket API functional")
PY
