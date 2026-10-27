#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '=== Existing Janus (read only) ==='
docker inspect janus-gateway --format 'Status={{.State.Status}} Restarts={{.RestartCount}} Image={{.Config.Image}}'
printf '\n%s\n' '=== Docker image storage / memory ==='
docker info --format 'Docker root directory: {{.DockerRootDir}}'
df -h /mnt/.ix-apps/docker /mnt/tank | awk 'NR==1 || !seen[$1]++'
free -h | head -n 3
printf '\nNo changes made. Do not build if Docker storage is nearly full.\n'
