#!/usr/bin/env bash
# Guarded trial migration of existing host-network Janus.
# Default --check performs read-only checks. --execute requires interactive consent.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mode="${1:---check}"
[[ $# -le 1 && ( "$mode" == --check || "$mode" == --execute ) ]] || {
  echo "Usage: bash scripts/cutover.sh [--check|--execute]" >&2; exit 2;
}
active=janus-gateway
original=janus-gateway-rollback-20261027
failed=janus-gateway-failed-20261027
test_container=janus-v143-securetest
old_tag=local/janus-rollback:1.1.4-20261027
new_tag=local/janus-nextcloud:1.4.3-secure
backup=/mnt/tank/janus-upgrade-backups/precutover-20261027

exists() { docker container inspect "$1" >/dev/null 2>&1; }
abort() { echo "ABORT: $*" >&2; exit 1; }
field() { docker inspect "$1" --format "$2"; }

echo "=== Read-only cutover prechecks ==="
[[ -f scripts/rollback.sh ]] || abort "Missing rollback script"
[[ -s "$backup/janus-container.json" && -s "$backup/janus.jcfg" ]] \
  || abort "Missing container/config backup"
python3 -m json.tool "$backup/janus-container.json" >/dev/null \
  || abort "Invalid saved Docker inspect JSON"
exists "$active" || abort "Production Janus is missing"
! exists "$original" || abort "Rollback container name is already used"
! exists "$failed" || abort "Failed replacement container name is already used"
[[ "$(field "$active" '{{.State.Status}}')" == running ]] \
  || abort "Production Janus is not running"
[[ "$(field "$active" '{{.HostConfig.NetworkMode}}')" == host ]] \
  || abort "Production Janus is not host-networked"
[[ "$(field "$active" '{{.HostConfig.RestartPolicy.Name}}')" == unless-stopped ]] \
  || abort "Unexpected original restart policy"
old_id=$(docker image inspect "$old_tag" --format '{{.Id}}') \
  || abort "Preserved original image missing"
new_id=$(docker image inspect "$new_tag" --format '{{.Id}}') \
  || abort "Candidate image missing"
[[ "$old_id" != "$new_id" ]] || abort "Old and new image IDs are identical"
[[ "$(field "$active" '{{.Image}}')" == "$old_id" ]] \
  || abort "Production image does not match rollback tag"
docker exec "$active" cat /usr/local/etc/janus/janus.jcfg | cmp - "$backup/janus.jcfg" >/dev/null \
  || abort "Saved original config no longer matches production"
exists "$test_container" || abort "Isolated test container missing"
[[ "$(field "$test_container" '{{.State.Status}}')" == running ]] \
  || abort "Isolated test is no longer running"
[[ "$(field "$test_container" '{{.Image}}')" == "$new_id" ]] \
  || abort "Isolated test image does not match candidate tag"
[[ "$(field "$test_container" '{{.HostConfig.NetworkMode}}')" == bridge ]] \
  || abort "Isolated test network mode has changed"
[[ "$(field "$test_container" '{{.HostConfig.ReadonlyRootfs}}')" == true ]] \
  || abort "Isolated test filesystem isn't read-only"
[[ "$(field nextcloud-signaling '{{.State.Status}}')" == running ]] \
  || abort "Nextcloud signaling is not running"

echo "PASS: Production Janus, preserved image, backups, candidate, isolated test and signaling"
echo "Original image: $old_id"
echo "Candidate image: $new_id"
if [[ "$mode" == --check ]]; then
  echo "CHECK ONLY: No containers were stopped, renamed or started."
  exit 0
fi

echo "WARNING: A trial cutover interrupts active Nextcloud Talk calls."
echo "Rollback command: cd /mnt/tank/apps/janus-nextcloud-secure-build && bash scripts/rollback.sh"
read -r -p 'Type CUTOVER to proceed: ' answer
[[ "$answer" == CUTOVER ]] || abort "Not confirmed; no changes made"

recover_on_error() {
  local status="$1"
  trap - ERR INT TERM
  echo "FAIL: Trial cutover failed (code $status). Attempting rollback." >&2
  if exists "$original"; then
    if bash scripts/rollback.sh; then
      echo "PASS: Automatic rollback completed." >&2
    else
      echo "URGENT: Automatic rollback failed. Inspect the stopped/renamed containers manually." >&2
    fi
  elif exists "$active" && [[ "$(field "$active" '{{.Image}}')" == "$old_id" ]]; then
    docker update --restart=unless-stopped "$active" >/dev/null || true
    docker start "$active" >/dev/null || true
    echo "Original container restored in place; verify status." >&2
  else
    echo "URGENT: Original container not found under the expected names." >&2
  fi
  exit "$status"
}
trap 'recover_on_error "$?"' ERR
trap 'recover_on_error 130' INT
trap 'recover_on_error 143' TERM

echo "=== Preserve and stop original ==="
docker update --restart=no "$active" >/dev/null
docker stop --time 30 "$active" >/dev/null
docker rename "$active" "$original"
echo "PASS: Original container preserved as $original"

echo "=== Start candidate in host networking ==="
docker run -d --name "$active" --network host --restart unless-stopped --init \
  --user 10001:10001 --cap-drop ALL \
  --security-opt no-new-privileges:true --read-only \
  --tmpfs /tmp:rw,nosuid,noexec,size=64m \
  --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
  "$new_tag" >/dev/null

ready=false
for attempt in $(seq 1 30); do
  [[ "$(field "$active" '{{.State.Status}}')" == running ]] || break
  logs=$(docker logs "$active" 2>&1)
  if [[ "$logs" == *"JANUS TextRoom plugin initialized!"* &&
        "$logs" == *"JANUS VideoRoom plugin initialized!"* &&
        "$logs" == *"Websockets server started (port 8188)"* ]]; then
    ready=true
    break
  fi
  sleep 1
done
[[ "$ready" == true ]] || {
  docker logs "$active" --tail 55 >&2
  false
}

# Check the loopback WebSocket API from inside the host-network container.
docker exec -i "$active" python3 - <<'PY'
import base64, hashlib, os, socket
key = base64.b64encode(os.urandom(16)).decode()
req = ("GET / HTTP/1.1\r\nHost: 127.0.0.1:8188\r\nUpgrade: websocket\r\n"
       "Connection: Upgrade\r\nSec-WebSocket-Protocol: janus-protocol\r\n"
       f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
with socket.create_connection(("127.0.0.1", 8188), timeout=6) as s:
    s.settimeout(6)
    s.sendall(req.encode())
    data = b""
    while b"\r\n\r\n" not in data and len(data) < 8192:
        part = s.recv(8192)
        if not part:
            break
        data += part
    status = data.partition(b"\r\n")[0].decode(errors="replace")
    expected = base64.b64encode(hashlib.sha1(
        (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
    ).digest())
    assert " 101 " in status, status
    assert b"sec-websocket-accept: " + expected.lower() in data.lower(), (
        "Invalid WebSocket accept key"
    )
print("PASS: Candidate host-network Janus WebSocket responds on loopback:8188")
PY

trap - ERR INT TERM
echo "PASS: New Janus initialized VideoRoom, TextRoom and WebSocket on host networking."
echo "TRIAL ONLY: Test real Nextcloud Talk audio/video across separate networks."
echo "If calls fail: cd /mnt/tank/apps/janus-nextcloud-secure-build && bash scripts/rollback.sh"
echo "Preserve the stopped original container until calls and reboot recovery are verified."
