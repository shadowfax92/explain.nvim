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

local function setup_screen()
  vim.cmd("silent! only | silent! %bwipeout!")
  vim.o.signcolumn = "yes"
  vim.o.number = false
end

-- Opens a file scrolled to the top. A reused window can keep an earlier
-- view, so rows are always looked up with row_of() rather than assumed.
local function open(path)
  vim.cmd.edit(path)
  vim.fn.winrestview({ topline = 1, lnum = 1, col = 0 })
end

-- Repaints every row. A plain redraw! skips rows Neovim believes are still
-- valid, and headless grids can hold stale blanks from earlier specs.
local function repaint()
  vim.api.nvim__redraw({ win = 0, valid = false, flush = true })
  vim.cmd("redraw!")
end

local function row_of(lnum)
  return vim.fn.screenpos(0, lnum, 1).row
end

local function sign_at(lnum)
  return vim.fn.nr2char(vim.fn.screenchar(row_of(lnum), 1))
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
  open(path)
  local session, first = session_with_steps(path, dir)
  local marks = Marks.new()
  marks:render(session:snapshot(), first)
  repaint()
  for lnum = 3, 5 do
    h.eq("▌", sign_at(lnum), "sign on line " .. lnum)
  end
  h.eq(" ", sign_at(2))
  h.eq(" ", sign_at(6))
  local attr = function(lnum)
    return vim.fn.screenattr(row_of(lnum), 60)
  end
  local band = attr(4)
  h.ok(band ~= attr(2), "band reaches past the text")
  h.eq(band, attr(3))
  h.ok(attr(10) ~= band, "other steps are dimmer")
  h.ok(attr(10) ~= attr(9), "but still banded")
  h.contains(screen_line(row_of(3)), "◆ claude: Every review walks through here.")
  h.contains(screen_line(row_of(10)), "◆ 2  Wrappers")
  marks:clear()
end

cases["bands can be hidden while signs, labels and anchors stay"] = function()
  setup_screen()
  local path, dir = h.file(h.numbered(20))
  open(path)
  local session, first = session_with_steps(path, dir)
  local marks = Marks.new()
  marks:render(session:snapshot(), first, { bands = false })
  repaint()
  local attr = function(lnum)
    return vim.fn.screenattr(row_of(lnum), 60)
  end
  h.eq(attr(2), attr(4), "no fill past the text")
  h.eq(attr(9), attr(10), "no fill on other steps either")
  h.eq("▌", sign_at(4))
  h.contains(screen_line(row_of(3)), "◆ claude: Every review walks through here.")
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new 1" })
  h.eq({ 4, 6 }, { marks:live_range(first) }, "the anchor still follows edits")
  vim.wait(50) -- the edit schedules a redraw, which must keep bands hidden
  repaint()
  h.eq(attr(3), attr(5))
  marks:render(session:snapshot(), first)
  repaint()
  h.ok(attr(5) ~= attr(3), "bands come back")
  marks:clear()
end

cases["the current step's label shows unread agent replies"] = function()
  setup_screen()
  local path, dir = h.file(h.numbered(20))
  open(path)
  local session, first, _, call = session_with_steps(path, dir)
  call("reply", { step_id = first, text = "answer" })
  local marks = Marks.new()
  marks:render(session:snapshot(), first)
  repaint()
  h.contains(screen_line(row_of(3)), "1 new")
  marks:clear()
end

cases["live ranges follow edits"] = function()
  setup_screen()
  local path, dir = h.file(h.numbered(20))
  open(path)
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
  open(path)
  h.wait_for(function()
    return marks:live_range(first) ~= nil
  end, 1000)
  h.eq({ 3, 5 }, { marks:live_range(first) })
  marks:clear()
end

cases["unloading a buffer reports where each range ended up"] = function()
  setup_screen()
  local path, dir = h.file(h.numbered(20))
  open(path)
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

-- Statuscolumn plugins (snacks, statuscol) ask for sign extmarks that start on
-- each line, so a single multi-line mark only shows on its first line there.
-- (Line highlights also count as "sign" marks, so keep only those with text.)
local function signs_on(lnum)
  local marks = vim.api.nvim_buf_get_extmarks(0, -1, { lnum - 1, 0 }, { lnum - 1, -1 }, { type = "sign", details = true })
  return vim.iter(marks)
    :map(function(mark)
      return mark[4].sign_text
    end)
    :totable()
end

cases["every annotated line carries its own sign for statuscolumn plugins"] = function()
  setup_screen()
  local path, dir = h.file(h.numbered(20))
  open(path)
  local session, first = session_with_steps(path, dir)
  local marks = Marks.new()
  marks:render(session:snapshot(), first)
  for lnum = 3, 5 do
    h.eq({ "▌ " }, signs_on(lnum), "one sign on line " .. lnum)
  end
  h.eq({}, signs_on(6))
  -- snacks shows the highest-priority sign-type mark per line; the band's line
  -- highlight is one too, so it must rank below the sign or the line looks bare.
  for lnum = 3, 5 do
    local marks = vim.api.nvim_buf_get_extmarks(0, -1, { lnum - 1, 0 }, { lnum - 1, -1 }, { type = "sign", details = true })
    table.sort(marks, function(a, b)
      return (a[4].priority or 0) > (b[4].priority or 0)
    end)
    h.eq("▌ ", marks[1][4].sign_text, "top sign on line " .. lnum)
  end
  vim.api.nvim_buf_set_lines(0, 4, 4, false, { "inserted inside" })
  h.wait_for(function()
    return #signs_on(5) == 1 and #signs_on(6) == 1
  end, 1000, "a line added inside the range gets a sign")
  h.eq({}, signs_on(7))
  marks:clear()
end

cases["clear removes every decoration"] = function()
  setup_screen()
  local path, dir = h.file(h.numbered(20))
  open(path)
  local session, first = session_with_steps(path, dir)
  local marks = Marks.new()
  marks:render(session:snapshot(), first)
  marks:clear()
  repaint()
  h.eq(" ", sign_at(3))
  h.eq("line 3", screen_line(row_of(3)):gsub("^%s+", ""))
end


cases["a revised range moves the highlight"] = function()
  setup_screen()
  local path, dir = h.file(h.numbered(20))
  open(path)
  local session, first, _, call = session_with_steps(path, dir)
  local marks = Marks.new()
  marks:render(session:snapshot(), first)
  h.eq("ok", call("update_step", { step_id = first, start_line = 8, end_line = 10 }).status)
  marks:render(session:snapshot(), first)
  h.eq({ 8, 10 }, { marks:live_range(first) })
  marks:clear()
end

cases["reopening a file restores the range where edits left it"] = function()
  setup_screen()
  local path, dir = h.file(h.numbered(20))
  open(path)
  local session, first = session_with_steps(path, dir)
  local marks = Marks.new({
    on_unload = function(step_id, first_line, last_line, revision)
      session:set_range(step_id, first_line, last_line, revision)
    end,
  })
  marks:render(session:snapshot(), first)
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new 1", "new 2" })
  vim.cmd("silent write")
  vim.cmd("bwipeout")
  open(path)
  h.wait_for(function()
    return marks:live_range(first) ~= nil
  end, 1000)
  h.eq({ 5, 7 }, { marks:live_range(first) })
  marks:clear()
end

return cases
