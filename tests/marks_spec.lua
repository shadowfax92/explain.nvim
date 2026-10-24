local h = dofile("tests/helpers.lua")
local Session = require("explain.session")
local Marks = require("explain.marks")

-- Reads one screen row back as text, so tests assert what the human sees.
local function screen_line(row)
  local chars = {}
  for col = 1, vim.o.columns do
    local char = vim.fn.screenchar(row, col)
    if char > 0 then
      chars[#chars + 1] = vim.fn.nr2char(char)
    end
  end
  return (table.concat(chars):gsub("%s+$", ""))
end

-- Resize once: resizing the headless grid between redraws crashes Neovim 0.12
-- (grid_clear_line in update_screen).
vim.o.columns, vim.o.lines = 100, 30

local function setup_screen()
  vim.cmd("silent! %bwipeout!")
  vim.o.signcolumn = "yes"
  vim.o.number = false
end

local function session_with_steps(path, dir)
  local session = Session.new({ cwd = dir })
  local function call(name, args)
    local out
    session:call(name, args, {}, function(result)
      out = result
    end)
    return out
  end
  local tour_id = call("create_tour", { title = "T", agent = "claude" }).data.tour_id
  local first = call("add_step", {
    tour_id = tour_id, path = path, start_line = 3, end_line = 5, title = "The funnel",
    note = "Every review walks through here. Then more.",
  }).data.step_id
  local second = call("add_step", {
    tour_id = tour_id, path = path, start_line = 10, end_line = 11, title = "Wrappers", note = "n",
  }).data.step_id
  return session, first, second, call
end

local cases = {}

cases["the current step gets a band and a sign on every line, others a dim one"] = function()
  setup_screen()
  local path, dir = h.file(h.numbered(20))
  vim.cmd.edit(path)
  local session, first = session_with_steps(path, dir)
  local marks = Marks.new()
  marks:render(session:snapshot(), first)
  vim.cmd("redraw!")
  for row = 3, 5 do
    h.eq("▌", vim.fn.nr2char(vim.fn.screenchar(row, 1)), "sign on line " .. row)
  end
  h.eq(" ", vim.fn.nr2char(vim.fn.screenchar(2, 1)))
  h.eq(" ", vim.fn.nr2char(vim.fn.screenchar(6, 1)))
  local band = vim.fn.screenattr(4, 60)
  h.ok(band ~= vim.fn.screenattr(2, 60), "band reaches past the text")
  h.eq(band, vim.fn.screenattr(3, 60))
  h.ok(vim.fn.screenattr(10, 60) ~= band, "other steps are dimmer")
  h.ok(vim.fn.screenattr(10, 60) ~= vim.fn.screenattr(9, 60), "but still banded")
  h.contains(screen_line(3), "◆ claude: Every review walks through here.")
  h.contains(screen_line(10), "◆ 2  Wrappers")
  marks:clear()
end

cases["the current step's label shows unread agent replies"] = function()
  setup_screen()
  local path, dir = h.file(h.numbered(20))
  vim.cmd.edit(path)
  local session, first, _, call = session_with_steps(path, dir)
  call("reply", { step_id = first, text = "answer" })
  local marks = Marks.new()
  marks:render(session:snapshot(), first)
  vim.cmd("redraw!")
  h.contains(screen_line(3), "1 new")
  marks:clear()
end

cases["live ranges follow edits"] = function()
  setup_screen()
  local path, dir = h.file(h.numbered(20))
  vim.cmd.edit(path)
  local session, first = session_with_steps(path, dir)
  local marks = Marks.new()
  marks:render(session:snapshot(), first)
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new 1", "new 2" })
  h.eq({ 5, 7 }, { marks:live_range(first) })
  vim.api.nvim_buf_set_lines(0, 6, 6, false, { "inside" })
  h.eq({ 5, 8 }, { marks:live_range(first) })
  marks:clear()
end

cases["a file opened later gets its marks"] = function()
  setup_screen()
  local path, dir = h.file(h.numbered(20))
  local session, first = session_with_steps(path, dir)
  local marks = Marks.new()
  marks:render(session:snapshot(), first)
  h.eq(nil, marks:live_range(first), "not loaded yet")
  vim.cmd.edit(path)
  h.wait_for(function()
    return marks:live_range(first) ~= nil
  end, 1000)
  h.eq({ 3, 5 }, { marks:live_range(first) })
  marks:clear()
end

cases["unloading a buffer reports where each range ended up"] = function()
  setup_screen()
  local path, dir = h.file(h.numbered(20))
  vim.cmd.edit(path)
  local session, first = session_with_steps(path, dir)
  local moved = {}
  local marks = Marks.new({
    on_unload = function(step_id, first_line, last_line)
      moved[step_id] = { first_line, last_line }
    end,
  })
  marks:render(session:snapshot(), first)
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new" })
  vim.cmd("bwipeout!")
  h.eq({ 4, 6 }, moved[first])
  marks:clear()
end

cases["clear removes every decoration"] = function()
  setup_screen()
  local path, dir = h.file(h.numbered(20))
  vim.cmd.edit(path)
  local session, first = session_with_steps(path, dir)
  local marks = Marks.new()
  marks:render(session:snapshot(), first)
  marks:clear()
  vim.cmd("redraw!")
  h.eq(" ", vim.fn.nr2char(vim.fn.screenchar(3, 1)))
  h.eq("line 3", screen_line(3):gsub("^%s+", ""))
end

return cases
