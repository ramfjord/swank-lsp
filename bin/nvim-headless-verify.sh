#!/usr/bin/env bash
#
# Fast LSP smoke test. Attaches to a running swank-lsp image (Mode 1)
# instead of auto-spawning an SBCL per check. Runs all checks in one
# nvim invocation, polling for client attach -- no fixed defer.
#
# Prereq:
#   bin/swank-lsp-server.sh start   # writes .swank-lsp-port at root
#
# Auto-starts the server if not already up.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PORT_FILE="$ROOT/.swank-lsp-port"

if ! [ -s "$PORT_FILE" ]; then
  echo "no $PORT_FILE; starting server..." >&2
  "$ROOT/bin/swank-lsp-server.sh" start >&2
fi

TEST_FILE=${TMPDIR:-/tmp}/swank-lsp-headless-test.lisp
cat > "$TEST_FILE" <<'EOF'
(in-package :cl-user)
(defun foo (x y) (list x y))
(let ((x 1)) (list x))
EOF

export SWANK_LSP_VERIFY_TEST_FILE="$TEST_FILE"
export SWANK_LSP_VERIFY_LOCAL_URI="file://$TEST_FILE"

OUT=$(nvim --headless -c "luafile $ROOT/bin/swank-lsp-verify.lua" 2>&1)
echo "$OUT" | grep -E '^(OK|FAIL) ' || { echo "no OK/FAIL lines:"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q '^FAIL ' && exit 1 || exit 0
