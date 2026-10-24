---Transport is a minimal HTTP/1.1 server on 127.0.0.1 built on libuv. It owns
---everything about the socket: incremental parsing, body limits, the secret
---token root, the Origin check against DNS rebinding, and closing every
---connection after one response. Handlers only ever see parsed requests, and
---only on the main loop.
---
---  libuv read callback (fast context: no editor API)
---    -> parse head and body
---    -> vim.schedule -> handler(req, respond)   (main loop)
---    -> respond() may run immediately or later (long-polls)
local M = {}

local REASONS = {
  [100] = "Continue",
  [200] = "OK",
  [400] = "Bad Request",
  [403] = "Forbidden",
  [404] = "Not Found",
  [405] = "Method Not Allowed",
  [411] = "Length Required",
  [413] = "Payload Too Large",
  [431] = "Request Header Fields Too Large",
  [500] = "Internal Server Error",
  [503] = "Service Unavailable",
}
local MAX_HEAD = 64 * 1024

local Server = {}
Server.__index = Server

---@class explain.Request
---@field method string
---@field path string    path below the token root, e.g. "/tools/reply"
---@field headers table<string, string>  lower-cased names
---@field body string
---@field base_url string  e.g. "http://127.0.0.1:47123/k7f2/"

---Starts listening on 127.0.0.1. Returns the server, or nil and an error.
---@param opts { token: string, handler: fun(req: explain.Request, respond: fun(status: integer, headers: table, body: string)), port?: integer, max_body?: integer }
function M.start(opts)
  local tcp = assert(vim.uv.new_tcp())
  local bound, bind_err = tcp:bind("127.0.0.1", opts.port or 0)
  if not bound then
    tcp:close()
    return nil, "cannot bind 127.0.0.1: " .. tostring(bind_err)
  end
  local server = setmetatable({
    tcp = tcp,
    token = opts.token,
    handler = opts.handler,
    max_body = opts.max_body or 1024 * 1024,
    connections = {},
  }, Server)
  local listening, listen_err = tcp:listen(64, function(err)
    if not err then
      server:_accept()
    end
  end)
  if not listening then
    tcp:close()
    return nil, "cannot listen: " .. tostring(listen_err)
  end
  server.port = tcp:getsockname().port
  server.url = ("http://127.0.0.1:%d/%s/"):format(server.port, server.token)
  server.origins = {
    [("http://127.0.0.1:%d"):format(server.port)] = true,
    [("http://localhost:%d"):format(server.port)] = true,
  }
  return server
end

local function encode(status, headers, body)
  body = body or ""
  local lines = { ("HTTP/1.1 %d %s"):format(status, REASONS[status] or "Status") }
  for name, value in pairs(headers or {}) do
    lines[#lines + 1] = name .. ": " .. value
  end
  lines[#lines + 1] = "Content-Length: " .. #body
  lines[#lines + 1] = "Connection: close"
  return table.concat(lines, "\r\n") .. "\r\n\r\n" .. body
end

function Server:_accept()
  local client = vim.uv.new_tcp()
  self.tcp:accept(client)
  local conn = { client = client, buffer = "" }
  self.connections[conn] = true

  -- Answers once, then closes. Safe to call from any context, any number of times.
  conn.respond = function(status, headers, body)
    if conn.done then
      return
    end
    conn.done = true
    self.connections[conn] = nil
    if client:is_closing() then
      return
    end
    client:write(encode(status, headers, body), function()
      if not client:is_closing() then
        client:shutdown(function()
          client:close()
        end)
      end
    end)
  end

  client:read_start(function(err, chunk)
    if err or not chunk then
      -- The peer went away. A late respond() becomes a no-op.
      conn.done = true
      self.connections[conn] = nil
      if not client:is_closing() then
        client:close()
      end
      return
    end
    -- Ignore bytes after dispatch, or after an early error reply (413 etc.)
    -- while the client is still uploading.
    if conn.dispatched or conn.done then
      return
    end
    conn.buffer = conn.buffer .. chunk
    self:_advance(conn)
  end)
end

local function plain(conn, status, message)
  conn.respond(status, { ["Content-Type"] = "text/plain; charset=utf-8" }, message .. "\n")
end

-- Parses as much of the request as has arrived. Runs in libuv's fast context.
function Server:_advance(conn)
  if not conn.head then
    local head_end = conn.buffer:find("\r\n\r\n", 1, true)
    if not head_end then
      if #conn.buffer > MAX_HEAD then
        plain(conn, 431, "request head too large")
      end
      return
    end
    local lines = vim.split(conn.buffer:sub(1, head_end - 1), "\r\n", { plain = true })
    local method, target = (lines[1] or ""):match("^(%u+) (%S+) HTTP/1%.%d$")
    if not method then
      return plain(conn, 400, "malformed request line")
    end
    local headers = {}
    for index = 2, #lines do
      local name, value = lines[index]:match("^([^:]+):%s*(.-)%s*$")
      if name then
        headers[name:lower()] = value
      end
    end
    conn.head = { method = method, target = target:gsub("%?.*$", ""), headers = headers }
    conn.body_start = head_end + 4
    if headers["transfer-encoding"] then
      return plain(conn, 411, "send a Content-Length body; chunked encoding is not supported")
    end
    conn.length = tonumber(headers["content-length"] or "0")
    if not conn.length or conn.length < 0 then
      return plain(conn, 400, "invalid Content-Length")
    end
    if conn.length > self.max_body then
      return plain(conn, 413, ("body over %d bytes"):format(self.max_body))
    end
    local received = #conn.buffer - conn.body_start + 1
    if (headers.expect or ""):lower() == "100-continue" and received < conn.length then
      conn.client:write("HTTP/1.1 100 Continue\r\n\r\n")
    end
  end
  if #conn.buffer - conn.body_start + 1 < conn.length then
    return
  end
  conn.dispatched = true
  self:_dispatch(conn, conn.buffer:sub(conn.body_start, conn.body_start + conn.length - 1))
end

function Server:_dispatch(conn, body)
  local head = conn.head
  local origin = head.headers.origin
  if origin and not self.origins[origin] then
    return plain(conn, 403, "cross-origin requests are refused")
  end
  local root = "/" .. self.token
  local path
  if head.target == root then
    path = "/"
  elseif head.target:sub(1, #root + 1) == root .. "/" then
    path = head.target:sub(#root + 1)
  else
    return plain(conn, 404, "not found")
  end
  local req = { method = head.method, path = path, headers = head.headers, body = body, base_url = self.url }
  vim.schedule(function()
    local ok, err = pcall(self.handler, req, conn.respond)
    if not ok then
      plain(conn, 500, "internal error: " .. tostring(err))
    end
  end)
end

---Closes the listener and answers every request still in flight with 503.
function Server:stop()
  if self.stopped then
    return
  end
  self.stopped = true
  if not self.tcp:is_closing() then
    self.tcp:close()
  end
  local open = vim.tbl_keys(self.connections)
  for _, conn in ipairs(open) do
    plain(conn, 503, "explain stopped")
  end
end

return M
