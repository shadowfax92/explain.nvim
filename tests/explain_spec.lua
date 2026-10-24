local h = dofile("tests/helpers.lua")
local explain = require("explain")
vim.cmd.runtime("plugin/explain.lua")

local function curl(args)
  local out = h.await(function(done)
    local argv = { "curl", "-s", "--max-time", "8" }
    vim.list_extend(argv, args)
    vim.system(argv, { text = true }, done)
  end, 10000)
  return out.stdout, out.code
end

local function post(url, name, args, pane)
  local body = curl({
    "-X", "POST", url .. "tools/" .. name,
    "-H", "Content-Type: application/json",
    "-H", "X-Herdr-Pane: " .. (pane or "w1Q:pR"),
    "--data-binary", vim.json.encode(args),
  })
  return vim.json.decode(body)
end

local function panel_win()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "explain" then
      return win
    end
  end
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function fresh()
  pcall(explain.stop)
  vim.cmd("silent! only | silent! %bwipeout!")
end

local cases = {}

cases["an agent can build a tour over HTTP and the human can read it"] = function()
  fresh()
  local nudges = {}
  explain.setup({ nudge = { delay_ms = 10, run = function(argv)
    nudges[#nudges + 1] = argv
  end } })
  local path, dir = h.file(h.numbered(40), "init.lua")
  vim.cmd.cd(dir)
  vim.fn.setreg('"', "my last yank")
  local url = explain.start()
  h.ok(url:match("^http://127%.0%.0%.1:%d+/%x+/$"), url)
  h.eq("my last yank", vim.fn.getreg('"'), "start leaves the unnamed register alone")
  h.contains(_G.notifications[#_G.notifications], "curl -s " .. url)
  h.contains(explain.statusline(), "explain")

  local guide = curl({ url })
  h.contains(guide, "## add_step")

  local tour = post(url, "create_tour", { title = "How it opens", agent = "claude" })
  local tour_id = tour.structuredContent.tour_id
  local step = post(url, "add_step", {
    tour_id = tour_id, path = "init.lua", start_line = 29, end_line = 33, title = "The funnel", note = "One door.",
  })
  h.eq(false, step.isError, step.content[1].text)
  local step_id = step.structuredContent.step_id
  h.wait_for(function()
    return panel_win() ~= nil
  end, 2000, "the first tour opens the panel")

  explain.next()
  h.eq(path, vim.api.nvim_buf_get_name(0))
  h.eq(29, vim.api.nvim_win_get_cursor(0)[1])
  vim.cmd("redraw!")
  h.eq("▌", vim.fn.nr2char(vim.fn.screenchar(vim.fn.winline() , vim.fn.win_screenpos(0)[2])))

  -- The human replies through the composer; nobody is waiting, so the agent's pane is nudged.
  explain.reply()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Where does cwd come from?" })
  vim.cmd("stopinsert")
  press("<CR>")
  local read = post(url, "read_messages", { after = 0 })
  h.eq("Where does cwd come from?", read.structuredContent.messages[1].text)
  h.wait_for(function()
    return #nudges == 1
  end, 2000, "the agent's pane is nudged")
  h.eq({ "pane", "run", "w1Q:pR" }, { nudges[1][2], nudges[1][3], nudges[1][4] })
  h.contains(nudges[1][5], "[explain]")
  h.contains(nudges[1][5], url)
  h.eq(nil, nudges[1][5]:find("after="), "a debounced nudge must not point past earlier replies")

  -- A waiting agent hears the next reply through its open request instead.
  local waited
  vim.system({
    "curl", "-s", "--max-time", "8", "-X", "POST", url .. "tools/wait_for_human",
    "--data-binary", vim.json.encode({ after = read.structuredContent.cursor, timeout_s = 5 }),
  }, { text = true }, function(out)
    waited = out.stdout
  end)
  vim.wait(300)
  explain.reply()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "And the base branch?" })
  vim.cmd("stopinsert")
  press("<C-s>")
  h.wait_for(function()
    return waited ~= nil
  end, 3000)
  h.eq("And the base branch?", vim.json.decode(waited).structuredContent.messages[1].text)
  vim.wait(60)
  h.eq(1, #nudges, "no nudge while a wait was open")

  post(url, "reply", { step_id = step_id, text = "Line 31." })
  explain.stop()
  h.eq(nil, panel_win())
  h.eq("", explain.statusline())
  local _, code = curl({ url })
  h.ok(code ~= 0, "the port is closed after stop")
end

cases["a question on a selection becomes a step the agent can read"] = function()
  fresh()
  explain.setup({ nudge = { delay_ms = 10, run = function() end } })
  local path, dir = h.file(h.numbered(40), "init.lua")
  vim.cmd.cd(dir)
  local url = explain.start()
  vim.cmd.edit(path)
  explain.ask({ start_line = 5, end_line = 7 })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "What does this block do?" })
  vim.cmd("stopinsert")
  press("<CR>")
  local message = post(url, "read_messages", {}).structuredContent.messages[1]
  h.eq({ "question", "init.lua", 5, 7, "What does this block do?" }, {
    message.kind, message.path, message.start_line, message.end_line, message.text,
  })
  h.ok(panel_win(), "asking opens the panel")
  explain.stop()
end

cases["the command starts, reports and stops"] = function()
  fresh()
  explain.setup({})
  vim.cmd("Explain start")
  h.contains(explain.statusline(), "explain")
  vim.cmd("Explain stop")
  h.eq("", explain.statusline())
end


cases["agents read ranges where the human's edits moved them"] = function()
  fresh()
  explain.setup({ nudge = false })
  local path, dir = h.file(h.numbered(40), "init.lua")
  vim.cmd.cd(dir)
  local url = explain.start()
  local tour_id = post(url, "create_tour", { title = "T" }).structuredContent.tour_id
  post(url, "add_step", { tour_id = tour_id, path = "init.lua", start_line = 10, end_line = 12, title = "s", note = "n" })
  explain.next()
  h.eq(path, vim.api.nvim_buf_get_name(0))
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new 1", "new 2" })
  local step = post(url, "get_tour", { tour_id = tour_id }).structuredContent.steps[1]
  h.eq({ 12, 14 }, { step.start_line, step.end_line })
  explain.stop()
end

cases["stop from inside the panel cleans up everything"] = function()
  fresh()
  explain.setup({ nudge = false })
  local path, dir = h.file(h.numbered(40), "init.lua")
  vim.cmd.cd(dir)
  local url = explain.start()
  post(url, "create_tour", { title = "T" })
  h.wait_for(function()
    return panel_win() ~= nil
  end, 2000)
  vim.cmd.edit(path)
  explain.ask({ start_line = 1, end_line = 2 })
  local composer = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsent draft" })
  vim.cmd("stopinsert")
  vim.api.nvim_set_current_win(panel_win())
  explain.stop()
  h.eq(nil, panel_win())
  h.eq(false, vim.api.nvim_win_is_valid(composer), "stop closes the composer")
  h.eq("", vim.fn.maparg("]x", "n"), "keymaps are removed")
  local next_url = explain.start()
  h.eq({}, post(next_url, "read_messages", {}).structuredContent.messages, "no draft leaks into a new session")
  explain.stop()
end

cases["stop answers an open wait with 503"] = function()
  fresh()
  explain.setup({ nudge = false })
  local _, dir = h.file(h.numbered(5), "init.lua")
  vim.cmd.cd(dir)
  local url = explain.start()
  local result
  vim.system({
    "curl", "-s", "-w", "\n%{http_code}", "--max-time", "8", "-X", "POST", url .. "tools/wait_for_human",
    "--data-binary", vim.json.encode({ after = 0, timeout_s = 5 }),
  }, { text = true }, function(out)
    result = out.stdout
  end)
  vim.wait(300)
  explain.stop()
  h.wait_for(function()
    return result ~= nil
  end, 3000)
  h.contains(result, "explain session ended")
  h.contains(result, "\n503")
end

cases["a timed-out long-poll does not swallow the next nudge"] = function()
  fresh()
  local nudges = {}
  explain.setup({ nudge = { delay_ms = 10, run = function(argv)
    nudges[#nudges + 1] = argv
  end } })
  local _, dir = h.file(h.numbered(40), "init.lua")
  vim.cmd.cd(dir)
  local url = explain.start()
  local tour_id = post(url, "create_tour", { title = "T" }).structuredContent.tour_id
  post(url, "add_step", { tour_id = tour_id, path = "init.lua", start_line = 1, end_line = 2, title = "s", note = "n" })
  curl({
    "--max-time", "1", "-X", "POST", url .. "tools/wait_for_human", "-H", "X-Herdr-Pane: w1Q:pR",
    "--data-binary", vim.json.encode({ after = 0, timeout_s = 30 }),
  })
  vim.wait(200)
  explain.next()
  explain.reply()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "still there?" })
  vim.cmd("stopinsert")
  press("<CR>")
  h.wait_for(function()
    return #nudges == 1
  end, 2000, "the agent is nudged although its curl gave up")
  explain.stop()
end

return cases
