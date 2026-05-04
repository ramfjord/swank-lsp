#!/usr/bin/env bash
#
# Bridge nvim's stdio LSP transport to a swank-lsp TCP server already
# running in your dev image.
#
# Use case: you have an SBCL+swank running for vlime; you've also
# loaded :swank-lsp in that same image and started its LSP server on
# TCP. nvim shouldn't spawn a fresh SBCL -- it should just connect.
#
# Reads SWANK_LSP_PORT (default 7777). Fails fast with a useful
# message if nothing is listening on that port.
#
# In your shell, before launching nvim:
#
#   export SWANK_LSP_PORT=7777
#
# In your dev image:
#
#   (ql:quickload :swank-lsp)
#   (swank-lsp:start-server :transport :tcp :port 7777)
#
# The nvim plugin (when it sees SWANK_LSP_PORT set in the env it was
# launched with) calls THIS script as its LSP cmd, which then proxies
# stdin/stdout to/from the TCP server.

set -euo pipefail

PORT="${SWANK_LSP_PORT:-7777}"

if ! command -v socat >/dev/null 2>&1; then
  echo "swank-lsp-attach: socat not on PATH; install it (\`pacman -S socat\`)." >&2
  exit 127
fi

# One-shot connection check so the user gets a clear error if the
# image isn't listening, instead of a silent dead LSP.
if ! exec 3<>"/dev/tcp/127.0.0.1/$PORT" 2>/dev/null; then
  echo "swank-lsp-attach: nothing listening on 127.0.0.1:$PORT." >&2
  echo "swank-lsp-attach: in your dev image, run:" >&2
  echo "  (ql:quickload :swank-lsp)" >&2
  echo "  (swank-lsp:start-server :transport :tcp :port $PORT)" >&2
  exit 1
fi
exec 3<&-
exec 3>&-

exec socat - "TCP:127.0.0.1:${PORT}"
