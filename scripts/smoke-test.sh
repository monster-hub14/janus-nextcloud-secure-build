#!/usr/bin/env bash
set -euo pipefail
image=local/janus-nextcloud:1.4.3-secure
name=janus-v143-securetest
if docker container inspect "$name" >/dev/null 2>&1; then
  echo "Test container $name exists; refusing to overwrite" >&2
  exit 1
fi
# All networking is inside this container; no ports published to NAS host.
docker run -d --name "$name" --network bridge --restart no \
  --cap-drop ALL --security-opt no-new-privileges:true \
  --read-only --tmpfs /tmp:rw,nosuid,noexec,size=64m \
  "$image" >/dev/null
sleep 7
printf '%s\n' '=== Container ==='
docker inspect "$name" --format 'Status={{.State.Status}} Exit={{.State.ExitCode}} Network={{.HostConfig.NetworkMode}} Published={{json .HostConfig.PortBindings}}'
printf '\n%s\n' '=== Key startup logs ==='
docker logs "$name" 2>&1 | grep -Ei 'version:|TextRoom plugin initialized|VideoRoom plugin initialized|Websockets server started|AES-GCM|Data Channels support not compiled|\[ERR\]|\[WARN\]' | tail -n 35 || true
printf '\n%s\n' '=== Local WebSocket upgrade handshake (inside isolated container) ==='
docker exec -i "$name" python3 - <<'PY'
import socket,base64,os
key = base64.b64encode(os.urandom(16)).decode()
request=("GET / HTTP/1.1\r\nHost: 127.0.0.1:8188\r\nUpgrade: websocket\r\n"
         "Connection: Upgrade\r\nSec-WebSocket-Protocol: janus-protocol\r\n"
         f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
with socket.create_connection(('127.0.0.1',8188),timeout=5) as s:
    s.sendall(request.encode()); result=s.recv(1024).decode(errors='replace')
    line=result.split('\r\n',1)[0]
    print(line)
    if ' 101 ' not in line:
        raise SystemExit('FAIL: no WebSocket 101 response')
print('PASS: Janus WebSocket responds within isolated container')
PY
printf '\nTEST ONLY. Existing production Janus is unchanged.\n'
