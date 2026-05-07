-- swank-lsp.nvim: Common Lisp LSP backed by swank.
--
-- Speaks vanilla LSP, attaches to a running swank-lsp image when one
-- is discoverable, otherwise auto-spawns a fresh SBCL per nvim attach.
-- Registers via nvim-lspconfig so LazyVim's default LSP keymaps
-- (gd, K, gK, gr, ...) wire up automatically.
--
-- Quickstart (lazy.nvim):
--
--   {
--     "ramfjord/swank-lsp",                    -- or your fork
--     dependencies = { "neovim/nvim-lspconfig" },
--     config = function() require("swank-lsp").setup({}) end,
--   }
--
-- All configuration is optional; setup({}) uses sensible defaults.
-- See M.defaults below for what they are and how to override them.

local M = {}

-- Plugin root: the swank-lsp project directory (contains bin/, src/,
-- swank-lsp.asd, ...). Auto-detected from this file's path so it works
-- whether the user clones to ~/projects/swank-lsp or lazy.nvim installs
-- it under ~/.local/share/nvim/lazy/swank-lsp.
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")

M.defaults = {
  -- Where swank-lsp is installed (auto-detected from this plugin's path).
  -- Override only if you keep the Lisp side and the nvim plugin separate.
  swank_lsp_root = plugin_root,

  -- Filetypes to attach to. Lisp is obvious; elp is for ERB-style
  -- Common Lisp templates. Drop "elp" if you don't have elp.nvim.
  filetypes = { "lisp", "elp" },

  -- Files used to locate the project root. The first one found
  -- walking up from the buffer determines the LSP's root_dir, which
  -- is also where we look for project-local .swank-lsp-port.
  root_markers = { ".git", "qlfile", "qlfile.lock" },

  -- Belt-and-suspenders LSP keymaps. LazyVim's defaults usually cover
  -- gd/K/gK/gr via Snacks, but the filter mechanism doesn't always
  -- catch swank-lsp; this re-binds them on LspAttach as a backup. If
  -- LazyVim's bindings already cover them, the rebind is a no-op.
  install_keymaps = true,

  -- Gate position-bearing requests on .elp buffers to <% %> code regions.
  -- Auto-detected: enabled iff elp.nvim is loadable. Set to false to
  -- force-disable, true to require it (errors at setup if absent).
  elp_gate = "auto",

  -- Client-side ELP template-tag stripping. The server does this
  -- natively when ELP is loaded into the image (ELP self-registers
  -- as a byte-stream translator with swank-lsp), so leave this off
  -- for the normal "attached image" case. Set to true only if you're
  -- using auto-spawn mode and your auto-spawn image doesn't load ELP.
  -- Auto-detected: defaults to false; set true to force the client
  -- transform on top of (or instead of) the server's.
  elp_extract = false,

  -- Package to inject into the client-side extracted text. Only used
  -- when elp_extract is true (i.e., the server isn't doing the
  -- translation). The server-side translator reads .elp-package
  -- markers walking up from the file's directory, so this option is
  -- only relevant for client-side fallback mode.
  elp_package = nil,
}

-- ─────────────────────── port-discovery helpers ───────────────────────

local function read_port_file(p)
  if vim.fn.filereadable(p) == 1 then
    local s = (vim.fn.readfile(p)[1] or ""):gsub("%s+", "")
    if s ~= "" then return s end
  end
end

-- Resolve which command + env to use for attaching this buffer's LSP.
-- Priority order:
--   1. $SWANK_LSP_PORT — explicit override, useful for quick tests
--   2. <project-root>/.swank-lsp-port — image started in the project
--      being edited (e.g. via that project's start-image.sh)
--   3. <swank_lsp_root>/.swank-lsp-port — swank-lsp's own dev image,
--      for working ON swank-lsp itself
--   4. Auto-spawn fresh SBCL per attach (qlot if available, else bare sbcl)
--
-- Returns (cmd_table, cmd_env_table_or_nil).
local function resolve_cmd(opts, root_dir)
  local attach_shim = opts.swank_lsp_root .. "/bin/swank-lsp-attach.sh"
  local stdio_script = opts.swank_lsp_root .. "/bin/swank-lsp-stdio.lisp"

  local function attach(port)
    return { attach_shim }, { SWANK_LSP_PORT = port }
  end

  -- 1. env override
  local user_port = os.getenv("SWANK_LSP_PORT")
  if user_port and user_port ~= "" and vim.fn.executable(attach_shim) == 1 then
    return attach(user_port)
  end

  -- 2. project-local
  if root_dir then
    local local_port = read_port_file(root_dir .. "/.swank-lsp-port")
    if local_port and vim.fn.executable(attach_shim) == 1 then
      return attach(local_port)
    end
  end

  -- 3. swank-lsp's own dev image
  local global_port = read_port_file(opts.swank_lsp_root .. "/.swank-lsp-port")
  if global_port and vim.fn.executable(attach_shim) == 1 then
    return attach(global_port)
  end

  -- 4. auto-spawn
  local qlot = vim.fn.expand("~/.roswell/bin/qlot")
  if vim.fn.executable(qlot) == 1 then
    return { qlot, "exec", "sbcl", "--noinform", "--script", stdio_script }
  end
  return { "sbcl", "--noinform", "--script", stdio_script }
end

-- ─────────────────────── ELP content extraction ───────────────────────

-- Replace the leading bytes of TEXT with "(in-package :PKG) " so
-- symbols in the rest of the buffer resolve in PKG. The injected
-- form is the same length as what it overwrites — preserving byte
-- offsets so positions in the original buffer round-trip cleanly.
-- If TEXT's leading whitespace is shorter than the form, returns
-- TEXT unchanged (positions matter more than getting the package).
local function inject_in_package(text, pkg)
  if not pkg or pkg == "" then return text end
  local form = "(in-package :" .. pkg .. ") "
  -- Find the first non-whitespace, non-newline byte. We can only
  -- replace bytes up to that point without disturbing column maps.
  local first_real = text:find("[^%s]") or (#text + 1)
  if first_real <= #form then return text end
  -- Pad form with spaces to fill the leading-whitespace span exactly,
  -- then keep the rest of the buffer verbatim. Newlines in the prefix
  -- are preserved by replacing only spaces, not the whole prefix.
  -- Simpler approach: replace the FIRST `\n` (or beginning) with the
  -- form. Even simpler that we go with: prepend form + space-pad to
  -- the position of the first real byte, only if no `\n` falls within
  -- those bytes (otherwise we'd shift line numbers).
  local first_newline = text:find("\n") or (#text + 1)
  if first_newline <= #form then return text end
  return form .. string.rep(" ", first_real - #form - 1) .. text:sub(first_real)
end

-- Transform a textDocument/didOpen or didChange params for an .elp
-- buffer: replace the document text with elp.extract_code_text's
-- output, optionally prepended with (in-package :PKG). Mutates and
-- returns PARAMS. No-op for non-elp URIs.
local function transform_elp_params(method, params, opts)
  if not params or not params.textDocument then return params end
  local uri = params.textDocument.uri
  if not (uri and uri:match("%.elp$")) then return params end

  local elp_ok, elp = pcall(require, "elp")
  if not elp_ok then return params end

  local bufnr = vim.uri_to_bufnr(uri)
  if not vim.api.nvim_buf_is_loaded(bufnr) then return params end

  local extracted = elp.extract_code_text(bufnr)
  if not extracted then return params end
  extracted = inject_in_package(extracted, opts.elp_package)

  if method == "textDocument/didOpen" then
    params.textDocument.text = extracted
  elseif method == "textDocument/didChange" then
    -- Full-sync mode: contentChanges has one entry { text = "..." }.
    -- Incremental sync (range + text) isn't handled — most LSP
    -- servers (and swank-lsp's defaults) negotiate full sync.
    if params.contentChanges and #params.contentChanges == 1
       and params.contentChanges[1].text
       and not params.contentChanges[1].range then
      params.contentChanges[1].text = extracted
    end
  end
  return params
end

-- ─────────────────────── LspAttach autocmds ───────────────────────

-- Belt-and-suspenders keymaps. Bound on LspAttach instead of globally
-- because LazyVim's Snacks-driven keymap filter doesn't always catch
-- swank-lsp even though `supports_method` returns true. Re-binding
-- here is a no-op when LazyVim's bindings already work.
local function install_keymap_autocmd()
  vim.api.nvim_create_autocmd("LspAttach", {
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if not client or client.name ~= "swank_lsp" then return end
      local opts = { buffer = args.buf, silent = true }
      local map = function(mode, lhs, rhs, desc)
        vim.keymap.set(mode, lhs, rhs,
                       vim.tbl_extend("force", opts, { desc = desc }))
      end
      map("n", "gd",    vim.lsp.buf.definition,      "Goto Definition")
      -- K intentionally not bound: LazyVim binds it globally for any LSP,
      -- and elp.nvim's ftplugin sets a buffer-local K that gates Lisp
      -- hover vs keywordprg fallback. Re-binding here would clobber it.
      map("n", "gK",    vim.lsp.buf.signature_help,  "Signature Help")
      map("i", "<C-k>", vim.lsp.buf.signature_help,  "Signature Help")
      map("n", "gr",    vim.lsp.buf.references,      "References")
      map("n", "gD",    vim.lsp.buf.declaration,     "Goto Declaration")
    end,
    desc = "swank-lsp: bind gd/gK/gr (Snacks filter doesn't always catch them)",
  })
end

-- Gate position-bearing requests on .elp buffers to <% %> code regions.
-- swank-lsp attaches to the whole .elp buffer (didOpen needs the full
-- document text), but hover / definition / references / signatureHelp /
-- completion / documentHighlight / prepareRename only make sense on
-- Lisp text. Wrapping client.request once at the LSP layer gates every
-- position-bearing feature in one place — no per-key boilerplate, and
-- features added later (rename, codeLens at a position, ...) inherit
-- the gate for free.
--
-- Outside <% %>, the request short-circuits: the handler is invoked
-- with a nil result and the call returns a bogus id. Anything LazyVim/
-- Snacks/Telescope drives through the LSP silently shows "no info" for
-- non-Lisp regions, the same way it would on a buffer with no LSP.
local function install_elp_gate_autocmd()
  vim.api.nvim_create_autocmd("LspAttach", {
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if not client or client.name ~= "swank_lsp" then return end
      if client.__elp_gate_installed then return end
      client.__elp_gate_installed = true

      local elp_ok, elp = pcall(require, "elp")
      if not elp_ok then return end

      local orig = client.request
      client.request = function(self, method, params, handler, req_bufnr)
        local pos = params and params.position
        local td = params and params.textDocument
        if pos and td and td.uri then
          local target = vim.uri_to_bufnr(td.uri)
          if vim.api.nvim_buf_is_valid(target)
             and vim.bo[target].filetype == "elp"
             and not elp.position_in_code(target, pos.line, pos.character)
          then
            if handler then
              vim.schedule(function()
                handler(nil, nil,
                        { method = method, client_id = self.id, bufnr = target })
              end)
            end
            return 0
          end
        end
        return orig(self, method, params, handler, req_bufnr)
      end
    end,
    desc = "swank-lsp: gate .elp position requests to <% %> regions",
  })
end

-- ─────────────────────── public entry point ───────────────────────

-- Install the elp transform on a fresh client. Wraps client.notify so
-- we intercept didOpen/didChange before the server sees them. Idempotent
-- via a flag on the client object.
local function install_elp_extract(client, opts)
  if client.__elp_extract_installed then return end
  client.__elp_extract_installed = true
  local original_notify = client.notify
  client.notify = function(self, method, params, ...)
    if method == "textDocument/didOpen"
       or method == "textDocument/didChange" then
      params = transform_elp_params(method, params, opts)
    end
    return original_notify(self, method, params, ...)
  end
end

function M.setup(user_opts)
  local opts = vim.tbl_deep_extend("force", M.defaults, user_opts or {})

  local lspconfig = require("lspconfig")
  local configs = require("lspconfig.configs")

  -- Idempotent registration: defining configs.swank_lsp twice errors.
  if not configs.swank_lsp then
    configs.swank_lsp = {
      default_config = {
        -- Placeholder; on_new_config replaces with the resolved cmd
        -- per-attach so per-project port discovery works.
        cmd = { "sbcl" },
        cmd_cwd = opts.swank_lsp_root,
        filetypes = opts.filetypes,
        root_dir = function(fname)
          return vim.fs.root(fname, opts.root_markers)
            or vim.fs.dirname(fname)
        end,
        on_new_config = function(config, root_dir)
          local cmd, cmd_env = resolve_cmd(opts, root_dir)
          config.cmd = cmd
          config.cmd_env = cmd_env
        end,
        on_init = function(client)
          local elp_extract_enabled =
            opts.elp_extract == true
            or (opts.elp_extract == "auto" and pcall(require, "elp"))
          if elp_extract_enabled then
            install_elp_extract(client, opts)
          end
          return true
        end,
        -- LSP 3.17 position-encoding negotiation. nvim defaults to
        -- utf-16; we offer utf-8 too so swank-lsp can pick whichever
        -- matches its native char model.
        capabilities = vim.tbl_deep_extend("force",
          vim.lsp.protocol.make_client_capabilities(),
          { general = { positionEncodings = { "utf-8", "utf-16" } } }),
        settings = {},
      },
      docs = {
        description = [[
swank-lsp: a Common Lisp LSP server backed by swank, with semantic
local jump-to-definition (handles let/lambda/dolist/loop binders that
slime-mdot-fu doesn't reach) and macro-introduced binding navigation.
        ]],
      },
    }
  end

  lspconfig.swank_lsp.setup({})

  if opts.install_keymaps then install_keymap_autocmd() end

  -- Three-state elp_gate: "auto" (install iff elp.nvim is loadable),
  -- true (force install — errors at runtime if elp.nvim is missing),
  -- false (skip).
  if opts.elp_gate == true
     or (opts.elp_gate == "auto" and pcall(require, "elp")) then
    install_elp_gate_autocmd()
  end
end

return M
