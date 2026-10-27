#!/usr/bin/env python3
"""Fail-closed, minimal Janus transport hardening of an image's generated defaults.
Does not change ICE/NAT/VideoRoom/media values.
"""
from pathlib import Path
import re
import sys

if len(sys.argv) != 2:
    raise SystemExit("Usage: harden-defaults.py CONFIG_DIRECTORY")
base = Path(sys.argv[1])

def set_value(path: Path, key: str, value: str, anchor: str):
    lines = path.read_text().splitlines(keepends=True)
    active = [(i, x) for i, x in enumerate(lines)
              if not x.lstrip().startswith(("#", "//"))
              and re.match(rf"^\s*{re.escape(key)}\s*=", x)]
    if len(active) > 1:
        raise RuntimeError(f"Duplicate {key} in {path.name}")
    if len(active) == 1:
        idx, old = active[0]
        indent = re.match(r"^\s*", old).group()
        lines[idx] = f"{indent}{key} = {value}\n"
    else:
        anchor_idx = [i for i, x in enumerate(lines)
                      if not x.lstrip().startswith(("#", "//"))
                      and re.match(rf"^\s*{re.escape(anchor)}\s*=", x)]
        if len(anchor_idx) != 1:
            raise RuntimeError(f"Expected one {anchor} in {path.name}; found {len(anchor_idx)}")
        idx = anchor_idx[0]
        indent = re.match(r"^\s*", lines[idx]).group()
        lines.insert(idx + 1, f"{indent}{key} = {value}\n")
    path.write_text("".join(lines))

ws = base / 'janus.transport.websockets.jcfg'
http = base / 'janus.transport.http.jcfg'
if not ws.is_file() or not http.is_file():
    raise SystemExit('Required Janus transport config files missing')
# Host-net deployment: high-performance signaling connects to ws://127.0.0.1:8188.
for k, v, anchor in [
    ('ws', 'true', 'ws_port'),
    ('ws_port', '8188', 'ws'),
    ('ws_ip', '"127.0.0.1"', 'ws_port'),
    ('wss', 'false', 'ws'),
    ('admin_ws', 'false', 'ws')]:
    set_value(ws, k, v, anchor)
# Signaling uses only WebSockets; disable unneeded unauthenticated HTTP API.
for k, v, anchor in [('http','false','port'),('admin_http','false','port')]:
    set_value(http, k, v, anchor)
print('PASS: WebSocket 127.0.0.1:8188 only; HTTP/admin APIs disabled')
