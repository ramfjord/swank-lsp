#!/usr/bin/env bash
#
# Smoke-test that swank-lsp attaches via nvim's lspconfig and that
# basic requests round-trip. Used as Phase 1's "does it actually work
# in an editor" gate.
#
# Requires:
#   - nvim with the swank-lsp.lua plugin file installed in ~/.config/nvim
#   - swank-lsp built (qlot install + asdf:load-system once)
#
# Usage:  ./bin/nvim-headless-verify.sh

set -euo pipefail

TEST_FILE=${TMPDIR:-/tmp}/swank-lsp-headless-test.lisp
cat > "$TEST_FILE" <<'EOF'
(in-package :cl-user)
(defun foo (x y) (list x y))
EOF

run_check() {
  local label=$1
  local cursor_line=$2
  local cursor_col=$3
  local method=$4
  local match_pattern=$5

  echo "=== $label ==="
  local out
  out=$(nvim --headless \
    -c "edit $TEST_FILE" \
    -c "lua vim.defer_fn(function()
          vim.api.nvim_win_set_cursor(0, {$cursor_line, $cursor_col})
          local clients = vim.lsp.get_clients({bufnr=0})
          local sl = nil
          for _, c in ipairs(clients) do
            if c.name == 'swank-lsp' then sl = c end
          end
          if not sl then
            print('FAIL: swank-lsp not attached (clients: ' ..
              vim.inspect(vim.tbl_map(function(c) return c.name end, clients)) .. ')')
            vim.cmd('qa!')
            return
          end
          local enc = sl.offset_encoding
          local pos = vim.lsp.util.make_position_params(0, enc).position
          local results = vim.lsp.buf_request_sync(0, '$method', {
            textDocument = vim.lsp.util.make_text_document_params(),
            position = pos,
          }, 5000)
          if not results then
            print('FAIL: no response for $method')
          else
            -- Inline the result on a single line so a `tail -1` lands
            -- on the marker line.
            local s = vim.inspect(results, {newline = ' ', indent = ''})
            print('OK: $method ' .. s:sub(1, 400))
          end
          vim.cmd('qa!')
        end, 12000)" 2>&1 | grep -oE "(OK|FAIL): [^|]*" | tail -1)
  echo "$out"
  if echo "$out" | grep -q "FAIL"; then
    echo "  >>> verification failed"
    return 1
  fi
  if [ -n "$match_pattern" ] && ! echo "$out" | grep -q "$match_pattern"; then
    echo "  >>> output didn't match expected pattern: $match_pattern"
    return 1
  fi
  return 0
}

# Cursor on `list` in (defun foo (x y) (list x y)) — line 2, col 18
run_check "hover"      2 18 "textDocument/hover"      "Documentation"
run_check "definition" 2 18 "textDocument/definition" "uri ="

# --- Local-resolution check (Phase 2) ---
# Cursor on the use of `x` in (let ((x 1)) (list x)) — should resolve
# to the binder in the SAME file (the result's Location URI must equal
# the temp file's URI), not fall through to swank (which would point at
# sbcl-source).
LOCAL_TEST_FILE=${TMPDIR:-/tmp}/swank-lsp-headless-local.lisp
cat > "$LOCAL_TEST_FILE" <<'EOF'
(let ((x 1)) (list x))
EOF

# Buffer contents (line 1, 0-based col):
#   "(let ((x 1)) (list x))"
#   col 0 1 2 3 4 5 6 7 8 9 ... 19=x ...
# So cursor at line 1, col 19 lands on the use-site `x`.
echo "=== local-definition ==="
LOCAL_OUT=$(nvim --headless \
  -c "edit $LOCAL_TEST_FILE" \
  -c "lua vim.defer_fn(function()
        vim.api.nvim_win_set_cursor(0, {1, 19})
        local clients = vim.lsp.get_clients({bufnr=0})
        local sl = nil
        for _, c in ipairs(clients) do
          if c.name == 'swank-lsp' then sl = c end
        end
        if not sl then print('FAIL: swank-lsp not attached'); vim.cmd('qa!'); return end
        local enc = sl.offset_encoding
        local pos = vim.lsp.util.make_position_params(0, enc).position
        local results = vim.lsp.buf_request_sync(0, 'textDocument/definition', {
          textDocument = vim.lsp.util.make_text_document_params(),
          position = pos,
        }, 5000)
        if not results then print('FAIL: no response'); vim.cmd('qa!'); return end
        local expected_uri = 'file://$LOCAL_TEST_FILE'
        -- Walk into result.result to find the Location URI (avoid matching
        -- the params.textDocument.uri which always equals the buffer URI).
        local _, payload = next(results)
        if not payload or not payload.result then
          print('FAIL: no result in response: ' .. vim.inspect(results, {newline=' ', indent=''}):sub(1,400))
          vim.cmd('qa!'); return
        end
        local r = payload.result
        local result_uri = nil
        if type(r) == 'table' and r.uri then result_uri = r.uri end
        if type(r) == 'table' and r[1] and r[1].uri then result_uri = r[1].uri end
        if result_uri == expected_uri then
          print('OK: local-definition uri=' .. result_uri .. ' range=' .. vim.inspect(r.range or r[1].range, {newline=' ', indent=''}))
        else
          print('FAIL: expected URI ' .. expected_uri .. ' got ' .. tostring(result_uri))
        end
        vim.cmd('qa!')
      end, 12000)" 2>&1 | grep -oE "(OK|FAIL): [^|]*" | tail -1)
echo "$LOCAL_OUT"
if echo "$LOCAL_OUT" | grep -q "FAIL"; then
  echo "  >>> local-definition verification failed"
  exit 1
fi

# Cursor inside (forma — completion
cat > "$TEST_FILE" <<'EOF'
(in-package :cl-user)
(forma
EOF
run_check "completion" 2 6 "textDocument/completion" "items ="

echo ""
echo "All checks passed."
