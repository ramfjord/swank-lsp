# swank-lsp

A Common Lisp LSP server that uses **swank as its engine** and speaks
**vanilla LSP** to any client.

Goal: a swank-grade Lisp development experience for any editor with
an LSP client — not just Emacs (SLIME), nvim (vlime/nvlime), or
VS Code (alive). Inherits every swank contrib for free; nvlime/Vlime
can attach to the same image in parallel.

Headline new feature: jump-to-definition that resolves **local
lexical bindings**, with a planned macroexpansion-aware mode that
lets you jump *into* an expansion when the binder only exists
post-expansion.

**Status:** early planning. Nothing implemented yet. See
[`plans/swank-lsp-server.md`](plans/swank-lsp-server.md) for the
phased outline.

Name is provisional.
