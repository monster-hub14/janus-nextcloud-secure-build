# Janus Gateway 1.4.3 — Nextcloud Talk / TrueNAS candidate

**Status:** Prepared build and test sources; **NOT yet compiled, security-audited or proven compatible**. No claim of a finished deployable binary. Prepared October 27, 2026.

## Your verified existing constraints

* TrueNAS SCALE 25.04.2.6, pool `tank`, working Docker boot/mount ordering: **do not modify**.
* Existing `janus-gateway` uses host networking and `unless-stopped`, Janus **1.1.4**, no bind mounts, and is healthy.
* Nextcloud signaling uses `ws://127.0.0.1:8188` and host networking.
* Existing `janus.jcfg` ICE ignore list matches `vmnet`; no custom NAT/STUN changes identified.
* Janus old configuration and inspect backup: `/mnt/tank/janus-upgrade-backups/20261027-110436`.
* Candidate `ladamalina/janus-gateway:v1.4.3` FAILED TextRoom due to disabled data channels; do not substitute it.

## Design

* Compile **upstream** Meetecho Janus `v1.4.3` rather than use third-party prebuilt binaries.
* libnice `0.1.23`, libSRTP `v2.8.0` with OpenSSL AES-GCM, `usrsctp` for data channels, libwebsockets `v5.0-stable` for upstream security maintenance.
* This is a **compatibility candidate**: the libwebsockets 5 branch may require build adjustments. The source checkout HEAD for `usrsctp` and moving `v5.0-stable` are recorded into `/opt/janus-build-info`, but not immutable. Pin final revisions after validation.
* Build on Ubuntu 24.04; start as non-root uid 10001, all Docker capabilities dropped, no-new-privileges, read-only filesystem and private tmpfs in the TEST run. The full OS build stage still contains compilers — production hardening and a slim runtime image should be revisited before final deployment.
* Janus generated defaults hardened: WebSocket API only at `127.0.0.1:8188`, HTTP + both Admin APIs off. No API token for now because existing signaling isn't configured to send one; other host-local processes can still reach localhost.
* Host networking **only** during production after tests; test uses isolated bridge networking with **no published ports**.
* Media ICE/NAT/UDP settings are **not** changed. External call performance must be tested by two users on different networks.
* No changes to Docker boot dependencies or other containers.

## Safe steps (each must be reviewed before proceeding)

1. Copy this folder to `/mnt/tank/apps/janus-nextcloud-secure-build` on TrueNAS. Do not modify anything under `/mnt/.ix-apps`.
2. Run `bash scripts/preflight.sh`. Verify sufficient free space on Docker's root and free RAM. Stop here if not adequate.
3. After reviewing versions and sources, run `bash scripts/build.sh`. This **uses NAS CPU, disk, and network**, can take significant time, and could fail without affecting production.
4. Validate with `bash scripts/smoke-test.sh`. Must see `Janus version 1403`, `TextRoom plugin initialized`, `VideoRoom plugin initialized`, WebSockets port 8188 initialized and WebSocket `101 Switching Protocols` response. Must **NOT** see `Data Channels support not compiled` or the AES-GCM missing warning.
5. Review runtime linkage/dependency CVEs, test container logs, startup permissions, and actual WebRTC ICE/media negotiation. Do not switch if any check fails.
6. Before cutover, prepare a rollback, ensure nobody is in calls, preserve previous image/container/restart policies, and inspect the `compose.production.EXAMPLE.yml` before converting it to a production file. *Never* run a general `docker compose up -d` against both test and production definitions.
7. In the maintenance window only, stop/rename old `janus-gateway`, set rollback container restart policy `no`, start pinned new service, verify `127.0.0.1:8188` and confirm a real group video/audio call from outside the LAN; rollback immediately on failure. Cutover changes not automated in this package.
8. After any future NAS reboot, validate Docker service, Nextcloud Talk call, Janus status, health and boot logs before considering the upgrade proven.

## Known limitations / review points

- This package was authored and Python/shell source checked; no Docker daemon is accessible here. **No image was built in this environment**.
- libwebsockets v5.0 API compatibility with Janus 1.4.3 is unverified. Build may fail. Do not fall back to a known vulnerable libwebsockets version without review.
- Update tracking is still required for Ubuntu, Janus, usrsctp, libnice, libwebsockets, libsrtp; rebuild images when security patches arrive.
- Using host networking means localhost APIs are reachable by other processes/containers sharing the host network namespace; stronger service-level authentication could be added after verifying signaling supports the same secret.
- Full host networking and custom media UDP routing require firewall/access review outside the Dockerfile.
- `--read-only` or dropping all capabilities can reveal runtime assumptions; test carefully. Do not loosen restrictions silently.

## Upstream sources

* https://github.com/meetecho/janus-gateway (Janus)
* https://github.com/cisco/libsrtp (libSRTP)
* https://gitlab.freedesktop.org/libnice/libnice (ICE)
* https://github.com/sctplab/usrsctp (WebRTC Data Channels)
* https://github.com/warmcat/libwebsockets (WebSocket transport; maintainers currently recommend v5.0-stable)
