local h = dofile("tests/helpers.lua")
local Nudge = require("explain.nudge")

local function recorder()
  local calls = {}
  return calls, function(argv)
    calls[#calls + 1] = argv
  end
end

local cases = {}

cases["sends one herdr command per pane after the quiet period"] = function()
  local calls, run = recorder()
  local nudge = Nudge.new({ run = run, delay_ms = 50, herdr = "herdr" })
  nudge:send("w1Q:pR", "[explain] first")
  nudge:send("w1Q:pR", "[explain] second")
  h.eq(0, #calls, "nothing is sent before the quiet period")
  h.wait_for(function()
    return #calls == 1
  end, 1000)
  vim.wait(100)
  h.eq({ { "herdr", "pane", "run", "w1Q:pR", "[explain] second" } }, calls)
end

cases["no pane means no nudge"] = function()
  local calls, run = recorder()
  local nudge = Nudge.new({ run = run, delay_ms = 10, herdr = "herdr" })
  nudge:send(nil, "x")
  nudge:send("", "x")
  vim.wait(60)
  h.eq({}, calls)
end

cases["close cancels pending nudges"] = function()
  local calls, run = recorder()
  local nudge = Nudge.new({ run = run, delay_ms = 30, herdr = "herdr" })
  nudge:send("w1Q:pR", "x")
  nudge:close()
  vim.wait(80)
  h.eq({}, calls)
end

cases["without a herdr binary the default adapter does nothing"] = function()
  local nudge = Nudge.new({ delay_ms = 10, herdr = "/nonexistent/herdr" })
  h.eq(false, nudge:available())
  nudge:send("w1Q:pR", "x")
  vim.wait(40)
end

return cases
