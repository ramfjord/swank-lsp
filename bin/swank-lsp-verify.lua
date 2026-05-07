-- Fast in-process verify driven by bin/nvim-headless-verify.sh.
-- Polls for client attach instead of fixed defer; runs all checks in
-- one nvim invocation so we pay LSP startup once.
--
-- Inputs come via env vars set by the bash wrapper:
--   SWANK_LSP_VERIFY_TEST_FILE   absolute path of the test buffer
--   SWANK_LSP_VERIFY_LOCAL_URI   expected file:// URI for local-defn check

local test_file  = vim.env.SWANK_LSP_VERIFY_TEST_FILE
local local_uri  = vim.env.SWANK_LSP_VERIFY_LOCAL_URI

vim.cmd('edit ' .. test_file)

local function get_client()
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do
    if c.name == 'swank_lsp' then return c end
  end
  return nil
end

-- Wait up to 15s for the client to attach AND finish init.
local ok = vim.wait(15000, function()
  local c = get_client()
  return c ~= nil and c.initialized == true
end, 50)

if not ok then
  print('FAIL no swank_lsp attached within 15s')
  vim.cmd('qa!')
end

local function req(method, line, col)
  local results = vim.lsp.buf_request_sync(0, method, {
    textDocument = vim.lsp.util.make_text_document_params(),
    position = { line = line, character = col },
  }, 5000) or {}
  local _, payload = next(results)
  return payload and payload.result
end

-- Leading newline guards against other plugins printing without a
-- trailing newline (vlime's startup banner glues onto our line otherwise).
local function show(label, ok_, extra)
  print('\n' .. (ok_ and 'OK ' or 'FAIL ') .. label .. (extra and (' ' .. extra) or ''))
end

-- Test buffer (0-based line/col):
--   line 0: (in-package :cl-user)
--   line 1: (defun foo (x y) (list x y))         ; col 18 is on `list`
--   line 2: (let ((x 1)) (list x))               ; col 19 is on the body x

-- 1) hover on `list`
do
  local r = req('textDocument/hover', 1, 18)
  show('hover', r ~= nil and r.contents ~= nil)
end

-- 2) definition on `list` (global, falls through to swank)
do
  local r = req('textDocument/definition', 1, 18)
  local has_uri = (type(r) == 'table') and (r.uri or (r[1] and r[1].uri))
  show('definition', has_uri ~= nil)
end

-- 3) local definition: cursor on body x in (let ((x 1)) (list x))
do
  local r = req('textDocument/definition', 2, 19)
  local got_uri = (type(r) == 'table') and (r.uri or (r[1] and r[1].uri)) or nil
  show('local-definition', got_uri == local_uri,
       got_uri and ('uri=' .. got_uri) or '(no uri in response)')
end

vim.cmd('qa!')
