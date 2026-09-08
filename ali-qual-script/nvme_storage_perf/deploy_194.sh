#!/bin/bash
# ============================================================================
# deploy_194.sh - example driver: upload the SSD perf suite to a host
#                  and launch it. Requires SSH_HOST and SSHPASS env vars.
#   SSHPASS='***' bash deploy_194.sh [mode]     (default mode: all)
# Steps: strip CRLF -> upload via stdin -> remote bash -n / py_compile ->
#        launch in tmux -> show early run.log lines.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

HOST="${SSH_HOST:?set SSH_HOST, e.g. user@your-host}"
REMOTE_DIR=/root/ali_qual
MODE="${1:-all}"
: "${SSHPASS:?set SSHPASS env before running}"

SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=10)
ssh_do() { sshpass -e ssh "${SSH_OPTS[@]}" "$HOST" "$@"; }

for f in nvme_storage_perf.sh perf_report.py; do
    ssh_do "cat > $REMOTE_DIR/$f" < <(tr -d '\r' < "$f")
    echo "uploaded: $f"
done

ssh_do "bash -n $REMOTE_DIR/nvme_storage_perf.sh && python3 -m py_compile $REMOTE_DIR/perf_report.py"
echo "remote syntax checks passed"

ssh_do "mkdir -p $REMOTE_DIR && tmux kill-session -t ali_qual 2>/dev/null || true"
ssh_do "tmux new-session -d -s ali_qual \"bash $REMOTE_DIR/nvme_storage_perf.sh -m $MODE 2>&1 | tee $REMOTE_DIR/tmux_launch.log\""
echo "launched in tmux session 'ali_qual' (mode=$MODE)"

sleep 5
ssh_do "tmux ls; ls -1t $REMOTE_DIR/NVME_ALI_QUAL_*/run.log 2>/dev/null | head -1 | xargs -r tail -n 30"
