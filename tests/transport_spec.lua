local h = dofile("tests/helpers.lua")
local transport = require("explain.transport")

-- Runs curl without blocking the loop the server lives on. Returns status and body.
local function curl(args)
  local result = h.await(function(done)
    local argv = { "curl", "-s", "-o", "-", "-w", "\n%{http_code}", "--max-time", "5" }
    vim.list_extend(argv, args)
    vim.system(argv, { text = true }, function(out)
      done(out)
    end)
  end, 8000)
  local body, status = result.stdout:match("^(.*)\n(%d+)$")
  return tonumber(status), body
end

local function echo_server(opts)
  opts = opts or {}
  local seen = {}
  local server = assert(transport.start({
    token = "k7f2",
    max_body = opts.max_body,
    handler = opts.handler or function(req, respond)
      seen[#seen + 1] = req
      respond(200, { ["Content-Type"] = "text/plain" }, req.method .. " " .. req.path .. " " .. #req.body)
    end,
  }))
  return server, seen
end

local cases = {}

cases["serves requests under the token root on localhost"] = function()
  local server, seen = echo_server()
  h.ok(server.port > 0)
  h.eq(("http://127.0.0.1:%d/k7f2/"):format(server.port), server.url)
  local status, body = curl({ server.url .. "tools?x=1" })
  server:stop()
  h.eq(200, status)
  h.eq("GET /tools 0", body)
  h.eq(server.url, seen[1].base_url)
end

cases["requests outside the token root never reach the handler"] = function()
  local server, seen = echo_server()
  local status = curl({ ("http://127.0.0.1:%d/other/"):format(server.port) })
  server:stop()
  h.eq(404, status)
  h.eq(0, #seen)
end

cases["a foreign Origin is refused, the server's own is allowed"] = function()
  local server, seen = echo_server()
  local refused = curl({ "-H", "Origin: http://evil.example", server.url })
  local allowed = curl({ "-H", ("Origin: http://localhost:%d"):format(server.port), server.url })
  server:stop()
  h.eq(403, refused)
  h.eq(200, allowed)
  h.eq(1, #seen)
end

cases["bodies arrive intact, including large and multibyte ones"] = function()
  local received
  local server = echo_server({
    handler = function(req, respond)
      received = req
      respond(200, {}, "ok")
    end,
  })
  local payload = string.rep("é→", 30000) .. "end"
  local path = vim.fn.tempname()
  vim.fn.writefile({ payload }, path, "b")
  local status = curl({ "-X", "POST", "-H", "X-Herdr-Pane: w1Q:pR", "--data-binary", "@" .. path, server.url .. "tools/reply" })
  server:stop()
  h.eq(200, status)
  h.eq(payload, received.body)
  h.eq("w1Q:pR", received.headers["x-herdr-pane"])
  h.eq("POST", received.method)
end

cases["Expect: 100-continue is honoured"] = function()
  local server = echo_server()
  local status, body = curl({ "-H", "Expect: 100-continue", "--data-binary", "hello", server.url })
  server:stop()
  h.eq(200, status)
  h.eq("POST / 5", body)
end

cases["bodies over the cap get 413"] = function()
  local server, seen = echo_server({ max_body = 10 })
  local status = curl({ "--data-binary", string.rep("x", 50), server.url })
  local path = vim.fn.tempname()
  vim.fn.writefile({ string.rep("y", 300000) }, path, "b")
  local streamed = curl({ "--data-binary", "@" .. path, server.url })
  vim.wait(100)
  server:stop()
  h.eq(413, status)
  h.eq(413, streamed)
  h.eq(0, #seen, "bytes after the early reply must not dispatch")
end

cases["handlers run on the main loop and may answer later"] = function()
  local pending
  local server = echo_server({
    handler = function(_, respond)
      vim.api.nvim_get_current_buf() -- raises E5560 in a fast callback
      pending = respond
    end,
  })
  local result
  vim.system({ "curl", "-s", "-w", "\n%{http_code}", "--max-time", "5", server.url }, { text = true }, function(out)
    result = out
  end)
  h.wait_for(function()
    return pending ~= nil
  end)
  pending(200, {}, "late")
  h.wait_for(function()
    return result ~= nil
  end)
  server:stop()
  h.eq("late\n200", result.stdout)
end

cases["stop answers requests still waiting with 503"] = function()
  local server = echo_server({ handler = function() end })
  local result
  vim.system({ "curl", "-s", "-w", "\n%{http_code}", "--max-time", "5", server.url }, { text = true }, function(out)
    result = out
  end)
  vim.wait(300)
  server:stop()
  h.wait_for(function()
    return result ~= nil
  end)
  h.contains(result.stdout, "503")
end

return cases
