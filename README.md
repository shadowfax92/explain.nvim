<div align="center">

<img src="assets/explain.svg" width="120" alt="explain">

# explain.nvim

**Let an agent walk you through code, inside Neovim.**

[![Neovim 0.10+](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![Lua](https://img.shields.io/badge/built%20with-Lua-2C2D72)](https://www.lua.org/)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

</div>

Ask Claude Code, Codex, or any agent with a shell to explain something. It
leaves a **tour**: ordered, highlighted ranges in your real files, each with a
short note. Read each step in its full file, reply under it, or select code and
ask about it. The agent answers in the same thread.

```
:Explain start   →  copies "Annotate code for me … curl -s http://127.0.0.1:47123/9f3c2a1e/"
paste in agent   →  "…and walk me through how a request is routed"
you              →  ]x through the steps, <leader>kr to reply, <leader>ka on a selection
```

Off by default: nothing listens until `:Explain start`, and `:Explain stop`
drops every tour. With [herdr](https://github.com/herdrdev/herdr), your replies
wake an agent whose turn has ended.

## Install

lazy.nvim:

```lua
{
  "shadowfax92/explain.nvim",
  cmd = "Explain",
  opts = {},
  keys = {
    { "<leader>ks", "<cmd>Explain start<cr>", desc = "explain: start" },
  },
}
```

## Keys

Active only while explain runs.

| Key | Action |
| --- | --- |
| `]x` / `[x` | next / previous step |
| `<leader>kr` | reply on the step |
| `<leader>ka` | ask about the selection (visual) |
| `<leader>kx` | resolve the step |
| `<leader>kp` | toggle the panel |
| `<leader>kt` | switch tour |
| `<leader>kh` | hide / show highlights |

Options, the agent API and highlight groups are in `:help explain`; internals in
[docs/architecture.md](docs/architecture.md).

The server binds only 127.0.0.1 under a random path, so treat the URL like a
session token.

## License

MIT
