#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_USER="${PI_USER:-pi-zero-1}"
PI_HOST="${PI_HOST:-192.168.0.137}"
PI_PASS="${PI_PASS:-}"
REMOTE="${PI_USER}@${PI_HOST}"

ssh_base=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
scp_base=(scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

if [[ -n "${PI_PASS}" ]]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "PI_PASS is set but sshpass is not installed." >&2
    exit 1
  fi
  ssh_base=(sshpass -p "${PI_PASS}" "${ssh_base[@]}")
  scp_base=(sshpass -p "${PI_PASS}" "${scp_base[@]}")
fi

run_ssh() {
  "${ssh_base[@]}" "${REMOTE}" "$@"
}

run_scp() {
  "${scp_base[@]}" "$@"
}

run_scp "${ROOT_DIR}/pi/bridge_streamer.py" "${REMOTE}:/tmp/bridge_streamer.py"
run_scp "${ROOT_DIR}/pi/arducam-bridge.service" "${REMOTE}:/tmp/arducam-bridge.service"

run_ssh "sudo install -d -m 755 /opt/arducam-bridge"
run_ssh "sudo install -m 755 /tmp/bridge_streamer.py /opt/arducam-bridge/bridge_streamer.py"
run_ssh "sed 's/__PI_USER__/${PI_USER}/g' /tmp/arducam-bridge.service | sudo tee /etc/systemd/system/arducam-bridge.service >/dev/null"
run_ssh "printf '%s\n' 'STREAM_ARGS=--host 0.0.0.0 --port 7123 --width 1280 --height 720 --framerate 6 --quality 65' | sudo tee /etc/default/arducam-bridge >/dev/null"
run_ssh "sudo systemctl daemon-reload && sudo systemctl enable arducam-bridge.service && sudo systemctl restart arducam-bridge.service"
run_ssh "systemctl --no-pager --full status arducam-bridge.service | sed -n '1,20p'"
run_ssh "hostname -I | awk '{print \$1}' | xargs -I{} printf 'Snapshot: http://{}:7123/snapshot.jpg\nStream: http://{}:7123/stream.mjpg\n'"
