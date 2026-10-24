local h = dofile("tests/helpers.lua")
local Session = require("explain.session")
local Panel = require("explain.panel")

local function fixture()
  vim.cmd("silent! only")
  local path, dir = h.file(h.numbered(40), "init.lua")
  local session = Session.new({ cwd = dir })
  local function call(name, args)
    local out
    session:call(name, args, {}, function(result)
      out = result
    end)
    return assert(out.data, out.text)
  end
  local tour_id = call("create_tour", { title = "How a review opens", agent = "claude" }).tour_id
  local first = call("add_step", {
    tour_id = tour_id, path = path, start_line = 29, end_line = 33, title = "The single funnel",
    note = "M.open is the one door every review walks through. See lua/rill/view.lua:88 next.",
  }).step_id
  local second = call("add_step", {
    tour_id = tour_id, path = path, start_line = 35, end_line = 36, title = "The per-mode wrappers", note = "n",
  }).step_id
  session:reply(first, "So where does cwd come from?")
  call("reply", { step_id = first, text = "Line 31 falls back to getcwd()." })
  return session, first, second, tour_id
end

local function lines(panel)
  return table.concat(vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false), "\n")
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local cases = {}

cases["renders the tour, its steps and the current thread"] = function()
  local session, first, _, tour_id = fixture()
  session:resolve(first)
  local panel = Panel.new({ display_path = function(p)
    return session:display_path(p)
  end })
  panel:open()
  panel:render(session:snapshot(), { tour_id = tour_id, step_id = first })
  local text = lines(panel)
  h.contains(text, "TOUR 1 OF 1")
  h.contains(text, "How a review opens")
  h.contains(text, "by claude · 2 steps")
  h.contains(text, "✓ 1  The single funnel")
  h.contains(text, "init.lua:29")
  h.contains(text, "  2  The per-mode wrappers")
  h.contains(text, "◆ claude")
  h.contains(text, "M.open is the one door every review walks through.")
  h.contains(text, "● you")
  h.contains(text, "So where does cwd come from?")
  h.contains(text, "Line 31 falls back to getcwd().")
  h.eq(true, panel:is_open())
  panel:close()
  h.eq(false, panel:is_open())
end

cases["long messages wrap to the panel width"] = function()
  local session, first, _, tour_id = fixture()
  local panel = Panel.new({ display_path = function(p)
    return session:display_path(p)
  end })
  panel:open()
  panel:render(session:snapshot(), { tour_id = tour_id, step_id = first })
  local width = vim.api.nvim_win_get_width(panel.win)
  for _, line in ipairs(vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false)) do
    h.ok(vim.fn.strdisplaywidth(line) <= width, "line fits: " .. line)
  end
  panel:close()
end

cases["shows how to connect before any tour exists"] = function()
  local panel = Panel.new({})
  panel:open()
  panel:render({ tours = {}, seq = 0 }, { url = "http://127.0.0.1:47123/k7f2/" })
  h.contains(lines(panel), "curl -s http://127.0.0.1:47123/k7f2/")
  panel:close()
end

cases["panel keys jump, reply, resolve and open references"] = function()
  local session, first, second, tour_id = fixture()
  local calls = {}
  local panel = Panel.new({
    display_path = function(p)
      return session:display_path(p)
    end,
    on_jump = function(id)
      calls[#calls + 1] = { "jump", id }
    end,
    on_reply = function()
      calls[#calls + 1] = { "reply" }
    end,
    on_resolve = function()
      calls[#calls + 1] = { "resolve" }
    end,
    on_next = function()
      calls[#calls + 1] = { "next" }
    end,
    on_open_ref = function(path, line)
      calls[#calls + 1] = { "ref", path, line }
    end,
  })
  panel:open()
  panel:render(session:snapshot(), { tour_id = tour_id, step_id = first })
  vim.api.nvim_set_current_win(panel.win)
  local buffer_lines = vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false)
  for index, line in ipairs(buffer_lines) do
    if line:find("The per-mode wrappers", 1, true) then
      vim.api.nvim_win_set_cursor(panel.win, { index, 0 })
    end
  end
  press("<CR>")
  for index, line in ipairs(buffer_lines) do
    local col = line:find("lua/rill/view.lua:88", 1, true)
    if col then
      vim.api.nvim_win_set_cursor(panel.win, { index, col + 2 })
    end
  end
  press("gf")
  press("r")
  press("x")
  press("<Tab>")
  h.eq({ { "jump", second }, { "ref", "lua/rill/view.lua", 88 }, { "reply" }, { "resolve" }, { "next" } }, calls)
  panel:close()
end

cases["the composer sends trimmed text and cancels cleanly"] = function()
  local panel = Panel.new({})
  panel:open()
  panel:render({ tours = {}, seq = 0 }, {})
  local origin = vim.api.nvim_get_current_win()
  local sent = {}
  panel:compose({ title = "reply to step 2" }, function(text)
    sent[#sent + 1] = text
  end)
  local composer = vim.api.nvim_get_current_win()
  h.ok(composer ~= origin and composer ~= panel.win, "composer has its own window")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "", "Does it reuse the session?", "Second line", "" })
  vim.cmd("stopinsert")
  press("<CR>")
  h.eq({ "Does it reuse the session?\nSecond line" }, sent)
  h.eq(false, vim.api.nvim_win_is_valid(composer))
  h.eq(origin, vim.api.nvim_get_current_win(), "focus returns where it was")

  panel:compose({ title = "reply" }, function(text)
    sent[#sent + 1] = text
  end)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "never mind" })
  vim.cmd("stopinsert")
  press("q")
  h.eq(1, #sent, "q cancels")
  panel:close()
end

return cases
