#!/usr/bin/env bash
#
# Bridge nvim's stdio LSP transport to a swank-lsp TCP server already
# running in your dev image.
#
# Use case: you have an SBCL+swank running for vlime; you've also
# loaded :swank-lsp in that same image and started its LSP server on
# TCP. nvim shouldn't spawn a fresh SBCL -- it should just connect.
#
# Port discovery, in order:
#   1. $SWANK_LSP_PORT env var
#   2. ./.swank-lsp-port file in CWD (the image publishes this on
#      start-server; convention mirrors .swank-port for swank itself)
#   3. fail with a helpful message
#
# In your dev image, the recommended startup snippet:
#
#   (ql:quickload :swank-lsp)
#   (swank-lsp:start-and-publish :port 7777)   ; or :port 0 for any-free
#
# That writes .swank-lsp-port to the project root so the editor (and
# anyone else attaching to the image) can discover it without an env
# var. Convention: read the file, never invent a port.

set -euo pipefail

read_port_file() {
  local f=$1
  [ -f "$f" ] || return 1
  local p
  p=$(head -n1 "$f" | tr -d '[:space:]')
  [ -n "$p" ] || return 1
  printf '%s' "$p"
}

resolve_port() {
  if [ -n "${SWANK_LSP_PORT:-}" ]; then
    printf '%s' "$SWANK_LSP_PORT"
    return
  fi
  local p
  if p=$(read_port_file "./.swank-lsp-port"); then
    printf '%s' "$p"
    return
  fi
  echo "swank-lsp-attach: no port discovered." >&2
  echo "swank-lsp-attach: set SWANK_LSP_PORT, or have your image" >&2
  echo "swank-lsp-attach: run (swank-lsp:start-and-publish ...) to" >&2
  echo "swank-lsp-attach: write a .swank-lsp-port file." >&2
  exit 2
}

PORT=$(resolve_port)

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
  echo "  (swank-lsp:start-and-publish :port $PORT)" >&2
  exit 1
fi
exec 3<&-
exec 3>&-

exec socat - "TCP:127.0.0.1:${PORT}"
