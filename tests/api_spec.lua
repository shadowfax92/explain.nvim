local h = dofile("tests/helpers.lua")
local Session = require("explain.session")
local api = require("explain.api")

local BASE = "http://127.0.0.1:47123/k7f2/"

local function request(handler, method, path, body, headers)
  return h.await(function(done)
    handler({ method = method, path = path, headers = headers or {}, body = body or "", base_url = BASE }, function(
      status,
      response_headers,
      response_body
    )
      done({ status = status, headers = response_headers, body = response_body })
    end)
  end)
end

local function json(response)
  return vim.json.decode(response.body)
end

local cases = {}

cases["GET / is a guide that teaches every tool with curl"] = function()
  local session = Session.new({ cwd = vim.fn.getcwd() })
  local response = request(api.handler(session), "GET", "/")
  h.eq(200, response.status)
  h.contains(response.headers["Content-Type"], "text/plain")
  for _, tool in ipairs(session:tools()) do
    h.contains(response.body, "## " .. tool.name)
    h.contains(response.body, "curl -s -X POST " .. BASE .. "tools/" .. tool.name)
  end
  h.contains(response.body, 'X-Herdr-Pane: $HERDR_PANE_ID')
end

cases["GET /tools lists tools in MCP tools/list shape"] = function()
  local session = Session.new({ cwd = vim.fn.getcwd() })
  local body = json(request(api.handler(session), "GET", "/tools"))
  h.eq(#session:tools(), #body.tools)
  local add_step = vim.iter(body.tools):find(function(tool)
    return tool.name == "add_step"
  end)
  h.eq("object", add_step.inputSchema.type)
  h.eq(false, add_step.inputSchema.additionalProperties)
  h.ok(vim.tbl_contains(add_step.inputSchema.required, "start_line"))
end

cases["POST /tools/<name> returns a CallToolResult and records the pane"] = function()
  local session = Session.new({ cwd = vim.fn.getcwd() })
  local handler = api.handler(session)
  local response = request(handler, "POST", "/tools/create_tour", vim.json.encode({ title = "Routing" }), {
    ["x-herdr-pane"] = "w1Q:pR",
  })
  h.eq(200, response.status)
  local body = json(response)
  h.eq(false, body.isError)
  h.eq("text", body.content[1].type)
  h.contains(body.content[1].text, "created tour")
  h.eq(1, body.structuredContent.tour_id)
  h.eq("w1Q:pR", session:snapshot().tours[1].pane)
end

cases["tool errors come back as isError results the agent can act on"] = function()
  local session = Session.new({ cwd = vim.fn.getcwd() })
  local response = request(api.handler(session), "POST", "/tools/reply", vim.json.encode({ step_id = 3, text = "x" }))
  h.eq(200, response.status)
  local body = json(response)
  h.eq(true, body.isError)
  h.contains(body.content[1].text, "step 3 not found")
  h.eq(nil, body.structuredContent)
end

cases["protocol errors use HTTP status and JSON-RPC codes"] = function()
  local handler = api.handler(Session.new({ cwd = vim.fn.getcwd() }))
  local unknown = request(handler, "POST", "/tools/explode", "{}")
  h.eq(404, unknown.status)
  h.eq(-32602, json(unknown).error.code)
  h.contains(json(unknown).error.message, "available: create_tour")

  local malformed = request(handler, "POST", "/tools/create_tour", "{title:")
  h.eq(400, malformed.status)
  h.eq(-32700, json(malformed).error.code)

  h.eq(405, request(handler, "DELETE", "/tools/create_tour").status)
  h.eq(404, request(handler, "GET", "/nowhere").status)
end

cases["an empty body means no arguments"] = function()
  local handler = api.handler(Session.new({ cwd = vim.fn.getcwd() }))
  local body = json(request(handler, "POST", "/tools/get_tour", ""))
  h.eq(false, body.isError)
  h.eq({}, body.structuredContent.tours)
end

cases["a long-poll answers when the human writes"] = function()
  local path, dir = h.file(h.numbered(5))
  local session = Session.new({ cwd = dir })
  local handler = api.handler(session)
  local post = function(name, args)
    return json(request(handler, "POST", "/tools/" .. name, vim.json.encode(args)))
  end
  local tour_id = post("create_tour", { title = "T" }).structuredContent.tour_id
  local step_id = post("add_step", {
    tour_id = tour_id, path = path, start_line = 1, end_line = 2, title = "s", note = "n",
  }).structuredContent.step_id
  local response
  handler({
    method = "POST",
    path = "/tools/wait_for_human",
    headers = {},
    body = vim.json.encode({ after = 0, timeout_s = 5 }),
    base_url = BASE,
  }, function(status, _, body)
    response = { status = status, body = body }
  end)
  h.eq(nil, response)
  session:reply(step_id, "hello")
  h.wait_for(function()
    return response ~= nil
  end, 1000)
  h.eq("hello", vim.json.decode(response.body).structuredContent.messages[1].text)
end


cases["a dropped long-poll stops counting as a listener"] = function()
  local path, dir = h.file(h.numbered(5))
  local session = Session.new({ cwd = dir })
  local handler = api.handler(session)
  local post = function(name, args)
    return json(request(handler, "POST", "/tools/" .. name, vim.json.encode(args)))
  end
  local tour_id = post("create_tour", { title = "T" }).structuredContent.tour_id
  local step_id = post("add_step", {
    tour_id = tour_id, path = path, start_line = 1, end_line = 2, title = "s", note = "n",
  }).structuredContent.step_id
  local hang_up
  handler({
    method = "POST",
    path = "/tools/wait_for_human",
    headers = {},
    body = vim.json.encode({ after = 0, timeout_s = 5 }),
    base_url = BASE,
    on_disconnect = function(fn)
      hang_up = fn
    end,
  }, function() end)
  h.ok(hang_up, "the API forwards the disconnect hook")
  hang_up()
  local nudge
  session:subscribe(function(event)
    nudge = event.needs_nudge
  end)
  session:reply(step_id, "hello?")
  h.eq(true, nudge)
end

cases["internal errors are logged with a traceback"] = function()
  local broken = {
    cwd = "/",
    tools = function()
      return {}
    end,
    call = function()
      error("boom")
    end,
  }
  local response = request(api.handler(broken), "POST", "/tools/anything", "{}")
  h.eq(500, response.status)
  h.contains(table.concat(_G.notifications, "\n"), "stack traceback")
end

return cases
