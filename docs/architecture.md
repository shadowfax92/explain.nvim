# explain.nvim architecture

## Agent API

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

## Modules

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
