---The agent API translates HTTP requests into session tool calls. It owns the
---wire format, which follows MCP so a real /mcp endpoint can reuse it later:
---`GET /tools` is a tools/list result, `POST /tools/<name>` returns a
---CallToolResult, and `GET /` renders the same tool table as a plain-text guide
---that agents read once and then drive with curl. It holds no state.
local M = {}

local JSON = { ["Content-Type"] = "application/json; charset=utf-8" }
local TEXT = { ["Content-Type"] = "text/plain; charset=utf-8" }

-- Hand-written examples read better than ones generated from the schema.
local EXAMPLES = {
  create_tour = { title = "How a request is routed", agent = "claude" },
  add_step = {
    tour_id = 1,
    path = "lua/rill/init.lua",
    start_line = 29,
    end_line = 43,
    title = "The single funnel",
    note = "Every entry point stamps a mode and calls here. See lua/rill/view.lua:88 for what happens next.",
  },
  update_step = { step_id = 2, note = "Sharper explanation." },
  reply = { step_id = 2, text = "Line 31 falls back to getcwd(); your keymap passes cwd explicitly." },
  read_messages = { after = 0 },
  wait_for_human = { after = 0, timeout_s = 45 },
  get_tour = { tour_id = 1 },
}

local PREAMBLE = [[
explain: annotate code for the human in their Neovim
=====================================================

The human wants to understand code. Teach them with a tour: ordered steps,
each highlighting a line range in a real file with a short note. They read
every step inside its full file, and can reply under a step or ask a new
question on any code they select. Answer in that step's thread.

Workflow
1. create_tour with a short title and your name as `agent`.
2. add_step for each place worth reading, in the order a newcomer should
   read them. Notes: 2-4 sentences. Mention other code as path:line.
   Check first_line/last_line in each result to confirm the range.
3. Then either loop on wait_for_human (pass back the cursor it returns),
   or end your turn: when the human writes, a line starting with
   "[explain]" appears in your terminal. Call read_messages then.
4. Answer with reply. Fix a wrong note or range with update_step.

Calling tools
Relative paths resolve against the editor's working directory: %s
POST JSON arguments to %stools/<name>.
Always send your herdr pane so the human's replies can wake you:
  -H "X-Herdr-Pane: $HERDR_PANE_ID"
Results follow MCP's CallToolResult: content[0].text summarises,
structuredContent holds the data, and isError=true means the arguments need
fixing (the text says how). Keep the quoted heredoc so shell characters in
notes stay literal. Full JSON Schemas: GET %stools
]]

local function ordered_properties(schema)
  local keys, seen = {}, {}
  for _, key in ipairs(schema.required or {}) do
    keys[#keys + 1], seen[key] = key, true
  end
  local rest = vim.tbl_filter(function(key)
    return not seen[key]
  end, vim.tbl_keys(schema.properties))
  table.sort(rest)
  return vim.list_extend(keys, rest)
end

local function guide(session, base)
  local out = { PREAMBLE:format(session.cwd, base, base) }
  for _, tool in ipairs(session:tools()) do
    local schema = tool.inputSchema
    local required = {}
    for _, key in ipairs(schema.required or {}) do
      required[key] = true
    end
    out[#out + 1] = ("## %s\n%s\nArguments:"):format(tool.name, tool.description)
    for _, key in ipairs(ordered_properties(schema)) do
      local spec = schema.properties[key]
      out[#out + 1] = ("  %s (%s%s): %s"):format(key, spec.type, required[key] and ", required" or "", spec.description)
    end
    -- Examples start at column 0: an indented EOF would never close the heredoc.
    out[#out + 1] = ("Example:\ncurl -s -X POST %stools/%s -H 'Content-Type: application/json' \\\n"
      .. "  -H \"X-Herdr-Pane: $HERDR_PANE_ID\" --data-binary @- <<'EOF'\n%s\nEOF\n"):format(
      base,
      tool.name,
      vim.json.encode(EXAMPLES[tool.name] or vim.empty_dict())
    )
  end
  return table.concat(out, "\n")
end

local function protocol_error(respond, status, code, message)
  respond(status, JSON, vim.json.encode({ error = { code = code, message = message } }))
end

local function call_tool(session, req, respond, name)
  local args = {}
  if vim.trim(req.body or "") ~= "" then
    local decoded, value = pcall(vim.json.decode, req.body)
    if not decoded then
      return protocol_error(respond, 400, -32700, "request body is not valid JSON: " .. tostring(value))
    end
    args = value
  end
  local ctx = { pane = req.headers["x-herdr-pane"] }
  session:call(name, args, ctx, function(result)
    if result.status == "unknown_tool" then
      return protocol_error(respond, 404, -32602, result.text)
    end
    respond(
      200,
      JSON,
      vim.json.encode({
        content = { { type = "text", text = result.text } },
        structuredContent = result.status == "ok" and (result.data or vim.empty_dict()) or nil,
        isError = result.status ~= "ok",
      })
    )
  end)
end

---Returns the transport handler for one session. Requests carry `base_url`
---(the token root) and lower-cased header names.
function M.handler(session)
  return function(req, respond)
    local path = req.path:gsub("/+$", "")
    if path == "" or path == "/tools" then
      if req.method ~= "GET" then
        return protocol_error(respond, 405, -32600, "use GET for " .. (path == "" and "/" or path))
      end
      if path == "" then
        return respond(200, TEXT, guide(session, req.base_url))
      end
      return respond(200, JSON, vim.json.encode({ tools = session:tools() }))
    end
    local name = path:match("^/tools/([%w_]+)$")
    if not name then
      return protocol_error(respond, 404, -32601, "no such path; GET " .. req.base_url .. " for the guide")
    end
    if req.method ~= "POST" then
      return protocol_error(respond, 405, -32600, "use POST to call a tool")
    end
    local ok, err = pcall(call_tool, session, req, respond, name)
    if not ok then
      vim.notify("[explain] tool " .. name .. " failed: " .. tostring(err), vim.log.levels.DEBUG)
      protocol_error(respond, 500, -32603, "internal error in " .. name .. ": " .. tostring(err))
    end
  end
end

return M
