#!/usr/bin/env bash
# Restore the exact original Janus container following a controlled cutover.
# This script MUST NOT be run until the cutover has renamed the original
# container from janus-gateway to janus-gateway-rollback-20261027.
# It never restarts the Docker daemon and never removes containers or images.
set -euo pipefail

original=janus-gateway-rollback-20261027
active=janus-gateway
failed=janus-gateway-failed-20261027
original_tag=local/janus-rollback:1.1.4-20261027

exists() { docker container inspect "$1" >/dev/null 2>&1; }
die() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

# All guards run before modifying anything.
exists "$original" || die "Original rollback container '$original' is absent. Nothing changed."
expected_image=$(docker image inspect "$original_tag" --format '{{.Id}}') \
  || die "Preserved original image tag '$original_tag' is absent."
actual_image=$(docker container inspect "$original" --format '{{.Image}}') \
  || die "Cannot inspect original container."
[[ "$actual_image" == "$expected_image" ]] \
  || die "Original container image differs from the preserved rollback image."
if exists "$failed"; then
  die "A container named '$failed' already exists; preserve it and resolve name collision manually."
fi
if exists "$active"; then
  active_image=$(docker container inspect "$active" --format '{{.Image}}')
  [[ "$active_image" != "$expected_image" ]] \
    || die "'$active' already uses the preserved original image; refusing ambiguous rollback."
fi

echo "Rollback prechecks passed. Restoring original Janus..."
if exists "$active"; then
  # Prevent the replacement from restarting and reclaiming 8188.
  docker update --restart=no "$active" >/dev/null
  docker stop --time 30 "$active"
  docker rename "$active" "$failed"
  echo "Replacement preserved as stopped container '$failed'."
fi

docker rename "$original" "$active"
docker update --restart=unless-stopped "$active" >/dev/null
docker start "$active" >/dev/null

state=$(docker container inspect "$active" --format '{{.State.Status}}')
image=$(docker container inspect "$active" --format '{{.Image}}')
[[ "$state" == running && "$image" == "$expected_image" ]] \
  || die "Original restoration requires manual inspection: state=$state."
echo "PASS: Original Janus container restored and running as '$active'."
echo "Check Nextcloud Talk calls and signaling; the script does not verify live media."
