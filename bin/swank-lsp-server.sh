#!/usr/bin/env bash
#
# Manage a long-running swank-lsp dev image. Mode-1 (attach) lifecycle
# in one place: start/stop/bounce/status. The verify script and any
# nvim attach mode read .swank-lsp-port written here.
#
# Usage:
#   bin/swank-lsp-server.sh start    # idempotent
#   bin/swank-lsp-server.sh stop     # kills, removes .swank-lsp-port
#   bin/swank-lsp-server.sh bounce   # stop + start
#   bin/swank-lsp-server.sh status

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PORT_FILE="$ROOT/.swank-lsp-port"
PID_FILE="$ROOT/.swank-lsp.pid"
LOG_FILE="$ROOT/.swank-lsp-server.log"

is_alive() {
  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

cmd_status() {
  if is_alive; then
    local pid port
    pid=$(cat "$PID_FILE")
    port=$(cat "$PORT_FILE" 2>/dev/null || echo '?')
    echo "up (pid $pid, port $port)"
  else
    echo "down"
  fi
}

cmd_stop() {
  if is_alive; then
    local pid
    pid=$(cat "$PID_FILE")
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      is_alive || break
      sleep 0.2
    done
    is_alive && kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE" "$PORT_FILE"
  echo "stopped"
}

cmd_start() {
  if is_alive; then
    cmd_status
    return 0
  fi
  rm -f "$PORT_FILE"
  cd "$ROOT"
  # nohup so the server outlives this shell. The (loop (sleep 60)) tail
  # keeps the SBCL alive after start-and-publish returns.
  nohup qlot exec sbcl --no-userinit --non-interactive \
    --eval '(ql:quickload :swank-lsp)' \
    --eval "(let ((*default-pathname-defaults* (truename \"$ROOT/\"))) (swank-lsp:start-and-publish :port 0))" \
    --eval '(loop (sleep 60))' \
    >> "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
  # Wait for the port file to materialize (server actually listening).
  for _ in $(seq 1 200); do
    [ -s "$PORT_FILE" ] && break
    sleep 0.1
  done
  if ! [ -s "$PORT_FILE" ]; then
    echo "FAIL: .swank-lsp-port did not appear within 20s; see $LOG_FILE" >&2
    cmd_stop >/dev/null
    return 1
  fi
  cmd_status
}

cmd_bounce() {
  cmd_stop >/dev/null
  cmd_start
}

case "${1:-status}" in
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  bounce) cmd_bounce ;;
  status) cmd_status ;;
  *) echo "usage: $0 {start|stop|bounce|status}" >&2; exit 1 ;;
esac
