#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Explicit build only — never recreates or stops running containers.
DOCKER_BUILDKIT=1 docker build --progress=plain --tag local/janus-nextcloud:1.4.3-secure .
docker run --rm --network none --entrypoint /opt/janus/bin/janus \
  local/janus-nextcloud:1.4.3-secure --version
