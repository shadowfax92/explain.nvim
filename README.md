# explain.nvim

Learn unfamiliar code with an agent, inside Neovim. Ask Claude Code, Codex or
any agent with a shell to explain something; it leaves a **tour**: ordered,
highlighted ranges in your real files, each with a short note. You read every
step in its full file, with LSP and your usual motions, and reply under any step
or ask about any selection. The agent answers in the same thread.

```
:Explain start      →  copies "Annotate code for me … curl -s http://127.0.0.1:47123/9f3c2a1e/"
paste into agent    →  "…walk me through how a request is routed"
agent               →  curl GET (reads the guide), create_tour, add_step × n
you                 →  ]x through the steps, <leader>kr to reply, <leader>ka on a selection
agent               →  woken by a one-line nudge in its herdr pane, answers with reply
```

It is off by default: nothing listens until `:Explain start`, and
`:Explain stop` (or quitting Neovim) drops every tour. Each Neovim instance
gets its own random port and secret path.

Requires Neovim 0.10+ (developed on 0.12) and `curl` on the agent's side. No
Lua dependencies. [herdr](https://github.com/herdrdev/herdr) is optional:
with it, your replies wake an agent whose turn has ended.

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

`setup()` is optional; the defaults are below.

```lua
require("explain").setup({
  -- Global keymaps exist only while explain runs; false skips one.
  keymaps = {
    next = "]x",
    prev = "[x",
    reply = "<leader>kr",
    ask = "<leader>ka", -- visual mode
    resolve = "<leader>kx",
    panel = "<leader>kp",
    tours = "<leader>kt",
    highlights = "<leader>kh",
  },
  -- Wake an idle agent through its herdr pane when you write.
  nudge = true,
})
```

Statusline (lualine):

```lua
sections = { lualine_x = { function() return require("explain").statusline() end } }
```

It shows `◆ explain :47123 · 2 new` while running and nothing otherwise.

## Reading a tour

The first tour opens a panel on the right without taking focus: the tour
title, its steps, and the current step's thread. Moving to a step opens its
file in your code window. The current step's lines get an amber band with a
yellow sign bar; other steps in open files get a dimmer band and a label at the
end of their first line. Questions you asked are blue. Bands follow your edits.
`<leader>kh` hides the band fill when it gets in the way of reading; the
sign bars and labels stay so you still see where each step is.

| Key | Where | Action |
| --- | --- | --- |
| `]x` / `[x` | anywhere | next / previous step |
| `<leader>kr` | normal | reply on the current step |
| `<leader>ka` | visual | ask about the selection (becomes a step after the current one) |
| `<leader>kx` | normal | resolve / reopen the current step |
| `<leader>kp` | normal | toggle the panel |
| `<leader>kt` | normal | switch tour |
| `<leader>kh` | normal | hide / show the band fill |
| `<CR>` | panel | jump to the step under the cursor |
| `<Tab>` / `<S-Tab>` | panel | next / previous step, focus stays in the panel |
| `r`, `x`, `gf`, `q` | panel | reply, resolve, open a `path:line` reference, close |

The composer opens below the panel in insert mode. `<C-s>` sends from insert or
normal mode, `<CR>` sends from normal mode, `q` or `<Esc>` in normal mode
cancels.

Commands: `:Explain start | stop | url | panel | tours | next | prev`.
`:Explain` alone starts, or toggles the panel when running.

## For agents

`GET <url>` returns a plain-text guide with every tool, its arguments and a
copy-paste `curl` example, so the pasted line is all an agent needs.
The wire format follows MCP (spec 2026-07-28): `GET <url>tools` is a
`tools/list` result and `POST <url>tools/<name>` returns a `CallToolResult`
(`content`, `structuredContent`, `isError`).

| Tool | Purpose |
| --- | --- |
| `create_tour` | start a tour (`title`, `agent`, `summary?`) |
| `add_step` | highlight `path` lines `start_line`–`end_line` with a `title` and `note`; echoes the first and last lines so the agent can check the range |
| `update_step` | revise a step's title, note or range |
| `reply` | post in a step's thread |
| `read_messages` | the human's replies and questions after a cursor |
| `wait_for_human` | the same, but holds the request open up to 50 s |
| `get_tour` | list tours, or read one with live ranges and threads |

Agents send `X-Herdr-Pane: $HERDR_PANE_ID` with each call. When you write and
no `wait_for_human` is open, explain types one line into that pane
(`herdr pane run`), telling the agent to call `read_messages`.

Tool mistakes (a line past the end of the file, an unknown step) come back as
`isError` results whose text says how to fix the call; protocol errors use 4xx
statuses.

## How it works

```
agent ──curl──> transport ──> api ──> session ──events──> controller
                (127.0.0.1,           (tours, steps,      ├─> marks  (bands, labels, live ranges)
                 secret path,          threads, waits)    ├─> panel  (steps, thread, composer)
                 Origin check)                            └─> nudge  (agent's herdr pane)
```

- **Session**: in-memory tours, steps, threads and long-polls behind the tool table.
- **Transport**: a small HTTP/1.1 server on libuv; handlers always run on the main loop.
- **Agent API**: the guide and MCP-shaped JSON.
- **Marks**: one extmark per step draws the band and sign on every line and follows edits.
- **Panel**: a scratch buffer wrapped to its width, plus the composer.
- **Controller**: view state, coalesced rendering, keymaps, nudges.

Only `127.0.0.1` is bound, every route sits under a random path segment, and
requests with a foreign `Origin` header are refused (MCP's DNS-rebinding rule).
Anything that can reach your loopback interface and knows the path can post
notes, so treat the URL like a session token.

## Development

```sh
make test              # every spec, each in its own headless Neovim
make test FILTER=panel # one spec file
```

Specs drive modules through their interfaces: the session through tool calls,
the transport and controller with real `curl` requests, marks and panel by
reading the rendered screen and buffer.
