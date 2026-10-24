---The panel is the reading surface beside the code: the current tour's header,
---its steps (a navigable list), the current step's thread, and a composer for
---replies. It renders from a session snapshot plus the controller's view state
---and reports keypresses back through callbacks; it never changes the session
---itself. Text is wrapped by hand to the window width so every visual line is
---a buffer line, which keeps the author bars (inline virtual text, so yanks stay
---clean) on every line of a message.
local highlight = require("explain.highlight")

local Panel = {}
Panel.__index = Panel

local NS = vim.api.nvim_create_namespace("explain.panel")
local MIN_WIDTH, MAX_WIDTH, RATIO = 40, 80, 0.35

---@class explain.PanelOpts
---@field display_path? fun(path: string): string
---@field on_jump? fun(step_id: integer)
---@field on_reply? fun()
---@field on_resolve? fun()
---@field on_next? fun()
---@field on_prev? fun()
---@field on_open_ref? fun(path: string, line: integer)

---@param opts explain.PanelOpts
function Panel.new(opts)
  highlight.setup()
  local noop = function() end
  opts = opts or {}
  return setmetatable({
    display_path = opts.display_path or function(path)
      return vim.fn.fnamemodify(path, ":~:.")
    end,
    on_jump = opts.on_jump or noop,
    on_reply = opts.on_reply or noop,
    on_resolve = opts.on_resolve or noop,
    on_next = opts.on_next or noop,
    on_prev = opts.on_prev or noop,
    on_open_ref = opts.on_open_ref or noop,
    rows = {},
  }, Panel)
end

function Panel:is_open()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

function Panel:_ensure_buffer()
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].bufhidden = "hide"
  vim.bo[self.buf].modifiable = false
  vim.bo[self.buf].filetype = "explain"
  local map = function(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = self.buf, nowait = true, silent = true, desc = "explain: " .. desc })
  end
  map("<CR>", function()
    local row = self.rows[vim.api.nvim_win_get_cursor(0)[1]]
    if row then
      self.on_jump(row.step_id)
    end
  end, "jump to step")
  map("gf", function()
    local path, line = self:_reference_under_cursor()
    if path then
      self.on_open_ref(path, line)
    end
  end, "open reference")
  map("r", function()
    self.on_reply()
  end, "reply")
  map("x", function()
    self.on_resolve()
  end, "resolve step")
  map("<Tab>", function()
    self.on_next()
  end, "next step")
  map("<S-Tab>", function()
    self.on_prev()
  end, "previous step")
  map("q", function()
    self:close()
  end, "close panel")
end

---Opens the panel as a right-hand split without taking focus.
function Panel:open()
  if self:is_open() then
    return
  end
  self:_ensure_buffer()
  local width = math.max(MIN_WIDTH, math.min(MAX_WIDTH, math.floor(vim.o.columns * RATIO)))
  self.win = vim.api.nvim_open_win(self.buf, false, { split = "right", win = -1, width = width })
  for name, value in pairs({
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
    statuscolumn = "",
    wrap = false,
    list = false,
    spell = false,
    cursorline = true,
    winfixwidth = true,
  }) do
    vim.api.nvim_set_option_value(name, value, { win = self.win, scope = "local" })
  end
  self.resize_group = vim.api.nvim_create_augroup("explain.panel.resize", { clear = true })
  vim.api.nvim_create_autocmd("WinResized", {
    group = self.resize_group,
    callback = function()
      if self:is_open() and self.last and vim.tbl_contains(vim.v.event.windows or {}, self.win) then
        self:render(self.last.snapshot, self.last.view)
      end
    end,
  })
  if self.last then
    self:render(self.last.snapshot, self.last.view)
  end
end

function Panel:close()
  if self.composer then
    self.composer.cancel()
  end
  if self:is_open() then
    local others = vim.tbl_filter(function(win)
      return win ~= self.win and vim.api.nvim_win_get_config(win).relative == ""
    end, vim.api.nvim_list_wins())
    if #others == 0 then
      -- Neovim refuses to close its last window (E444); leave an empty buffer.
      vim.api.nvim_win_set_buf(self.win, vim.api.nvim_create_buf(true, false))
    else
      vim.api.nvim_win_close(self.win, true)
    end
  end
  self.win = nil
  if self.resize_group then
    pcall(vim.api.nvim_del_augroup_by_id, self.resize_group)
    self.resize_group = nil
  end
end

function Panel:toggle()
  if self:is_open() then
    self:close()
  else
    self:open()
  end
end

-- Splits off the longest head of `word` that fits `width` display cells,
-- always at least one character so wrapping makes progress.
local function take_cells(word, width)
  local chars = vim.fn.split(word, "\\zs")
  local head, cells = "", 0
  for index, char in ipairs(chars) do
    local char_width = vim.fn.strdisplaywidth(char)
    if index > 1 and cells + char_width > width then
      return head, table.concat(chars, "", index)
    end
    head, cells = head .. char, cells + char_width
  end
  return head, ""
end

-- Greedy word wrap by display width; overlong words are split by cells, so
-- wide (CJK) text wraps too. Widths below one cell still wrap, one char a line.
local function wrap(text, width)
  width = math.max(width, 1)
  local out = {}
  for _, paragraph in ipairs(vim.split(text, "\n", { plain = true })) do
    local line = ""
    for word in paragraph:gmatch("%S+") do
      while vim.fn.strdisplaywidth(word) > width do
        if line ~= "" then
          out[#out + 1], line = line, ""
        end
        local head
        head, word = take_cells(word, width)
        out[#out + 1] = head
      end
      local candidate = line == "" and word or (line .. " " .. word)
      if vim.fn.strdisplaywidth(candidate) > width then
        out[#out + 1], line = line, word
      else
        line = candidate
      end
    end
    out[#out + 1] = line
  end
  return out
end

local function truncate(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  if width <= 1 then
    return "…"
  end
  return (take_cells(text, width - 1)) .. "…"
end

local function ago(timestamp)
  local seconds = os.time() - (timestamp or os.time())
  if seconds < 60 then
    return "now"
  elseif seconds < 3600 then
    return ("%dm"):format(seconds / 60)
  end
  return ("%dh"):format(seconds / 3600)
end

-- Accumulates lines plus the highlights and bars to apply after writing them.
local Builder = {}
Builder.__index = Builder

local function builder(width)
  return setmetatable({ lines = {}, hls = {}, bars = {}, row_hls = {}, width = width }, Builder)
end

---Adds a line from {text, hl} segments, optionally with a right-aligned tail.
function Builder:add(segments, tail)
  local text, col = "", 0
  local row = #self.lines
  local function push(segment)
    local piece = segment[1]
    if segment[2] then
      self.hls[#self.hls + 1] = { row, col, col + #piece, segment[2] }
    end
    text, col = text .. piece, col + #piece
  end
  for _, segment in ipairs(segments) do
    push(segment)
  end
  if tail then
    local gap = self.width - vim.fn.strdisplaywidth(text) - vim.fn.strdisplaywidth(tail[1])
    push({ string.rep(" ", math.max(gap, 1)) })
    push(tail)
  end
  self.lines[#self.lines + 1] = text
  return row + 1
end

function Builder:blank()
  self.lines[#self.lines + 1] = ""
end

function Builder:rule()
  self:add({ { " " .. string.rep("─", self.width - 2), "ExplainMuted" } })
end

local function step_glyph(step, current)
  if step.resolved then
    return "✓", "ExplainResolved"
  elseif current then
    return "◆", "ExplainAgent"
  elseif step.origin == "human" then
    return "●", "ExplainHuman"
  end
  return " ", nil
end

function Panel:_message(b, who, hl, bar_hl, body, meta)
  b:add({ { " " }, { who, hl } }, meta and { meta, "ExplainMuted" } or nil)
  for _, line in ipairs(wrap(body, b.width - 3)) do
    b.bars[#b.bars + 1] = { #b.lines, bar_hl }
    b:add({ { line } })
  end
  b:blank()
end

function Panel:_build(snapshot, view, width)
  local b = builder(width)
  local rows = {}
  local tour, tour_index
  for index, candidate in ipairs(snapshot.tours) do
    if candidate.id == view.tour_id then
      tour, tour_index = candidate, index
    end
  end
  if not tour then
    b:blank()
    b:add({ { " explain is listening", "ExplainTitle" } })
    b:blank()
    b:add({ { " Paste this line into an agent:", "ExplainMuted" } })
    if view.url then
      b:add({ { " curl -s " .. view.url } })
    end
    return b, rows
  end

  b:add({ { (" TOUR %d OF %d"):format(tour_index, #snapshot.tours), "ExplainMuted" } })
  for _, line in ipairs(wrap(tour.title, width - 2)) do
    b:add({ { " " .. line, "ExplainTitle" } })
  end
  local byline = tour.origin == "human" and "asked by you" or ("by " .. (tour.agent or "agent"))
  b:add({ { (" %s · %d step%s"):format(byline, #tour.steps, #tour.steps == 1 and "" or "s"), "ExplainMuted" } })
  b:rule()

  local current
  for position, step in ipairs(tour.steps) do
    local is_current = step.id == view.step_id
    current = is_current and step or current
    local glyph, glyph_hl = step_glyph(step, is_current)
    local location = ("%s:%d"):format(vim.fn.fnamemodify(self.display_path(step.path), ":t"), step.start_line)
    local badge = step.unread > 0 and (" %d new "):format(step.unread) or nil
    local prefix = (" %s %d  "):format(glyph, position)
    local room = width - vim.fn.strdisplaywidth(prefix) - vim.fn.strdisplaywidth(location) - 2
      - (badge and vim.fn.strdisplaywidth(badge) + 1 or 0)
    local segments = {
      { " " },
      { glyph, glyph_hl },
      { (" %d  "):format(position), is_current and "ExplainCurrentNumber" or "ExplainMuted" },
      { truncate(step.title, room), is_current and "ExplainTitle" or nil },
    }
    if badge then
      segments[#segments + 1] = { " " }
      segments[#segments + 1] = { badge, "ExplainBadge" }
    end
    local row = b:add(segments, { location, "ExplainMuted" })
    rows[row] = { step_id = step.id }
    if is_current then
      b.row_hls[#b.row_hls + 1] = row - 1
    end
  end
  if #tour.steps == 0 then
    b:add({ { " waiting for the first step…", "ExplainMuted" } })
  end
  b:rule()
  b:blank()

  if current then
    if current.origin ~= "human" and current.note then
      self:_message(
        b,
        "◆ " .. (tour.agent or "agent"),
        "ExplainAgent",
        "ExplainAgentBar",
        current.note,
        current.note_edited_at and "edited" or nil
      )
    end
    for _, message in ipairs(current.messages) do
      if message.author == "human" then
        self:_message(b, "● you", "ExplainHuman", "ExplainHumanBar", message.text, ago(message.at))
      else
        local name = "◆ " .. (message.agent or tour.agent or "agent")
        self:_message(b, name, "ExplainAgent", "ExplainAgentBar", message.text, ago(message.at))
      end
    end
    b:add({ { " r reply · x resolve · ⇥ next · gf open", "ExplainMuted" } })
  else
    b:add({ { " ]x or <CR> on a step to start reading", "ExplainMuted" } })
  end
  return b, rows
end

---Redraws from a snapshot. `view` holds tour_id, step_id, and url (shown
---before any tour exists). Safe to call while closed; open() re-renders.
function Panel:render(snapshot, view)
  self.last = { snapshot = snapshot, view = view }
  if not self:is_open() then
    return
  end
  local width = math.max(vim.api.nvim_win_get_width(self.win) - 1, 1)
  local b, rows = self:_build(snapshot, view or {}, width)
  self.rows = rows
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, b.lines)
  vim.bo[self.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(self.buf, NS, 0, -1)
  for _, row in ipairs(b.row_hls) do
    vim.api.nvim_buf_set_extmark(self.buf, NS, row, 0, { line_hl_group = "ExplainCurrent", priority = 10 })
  end
  for _, hl in ipairs(b.hls) do
    vim.api.nvim_buf_set_extmark(self.buf, NS, hl[1], hl[2], { end_col = hl[3], hl_group = hl[4], priority = 20 })
  end
  for _, bar in ipairs(b.bars) do
    vim.api.nvim_buf_set_extmark(self.buf, NS, bar[1], 0, { virt_text = { { " ▌ ", bar[2] } }, virt_text_pos = "inline" })
  end
end

-- Finds a `path:line` reference at or nearest to the cursor on the current line.
function Panel:_reference_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local best, best_distance
  local start = 1
  while true do
    local s, e, path, number = line:find("([%w%._/~%-]+%.[%w]+):(%d+)", start)
    if not s then
      break
    end
    local distance = (col >= s and col <= e) and 0 or math.min(math.abs(col - s), math.abs(col - e))
    if not best_distance or distance < best_distance then
      best, best_distance = { path, tonumber(number) }, distance
    end
    start = e + 1
  end
  if best then
    return best[1], best[2]
  end
end

---Opens a small composer below the panel. `<C-s>` (insert or normal) or `<CR>`
---(normal) sends; `q` or `<Esc>` in normal mode cancels. Focus returns to the
---window that was current before composing.
---@param opts { title: string }
---@param on_send fun(text: string)
function Panel:compose(opts, on_send)
  if not self:is_open() then
    self:open()
  end
  local origin = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "explain_compose"
  local win = vim.api.nvim_open_win(buf, true, { split = "below", win = self.win, height = 7 })
  vim.wo[win].winbar = ("%%#ExplainHuman# ● %s %%#ExplainMuted# <C-s> send · q cancel"):format(opts.title)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  local finished = false
  local function finish(send)
    if finished then
      return
    end
    finished = true
    self.composer = nil
    local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    vim.cmd("stopinsert")
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_win_is_valid(origin) then
      vim.api.nvim_set_current_win(origin)
    end
    if send and text ~= "" then
      on_send(text)
    end
  end
  local map = function(mode, lhs, send)
    vim.keymap.set(mode, lhs, function()
      finish(send)
    end, { buffer = buf, nowait = true, silent = true })
  end
  map({ "i", "n" }, "<C-s>", true)
  map("n", "<CR>", true)
  map("n", "q", false)
  map("n", "<Esc>", false)
  -- close() cancels a draft in progress, e.g. on :Explain stop.
  self.composer = {
    cancel = function()
      finish(false)
    end,
  }
  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = buf,
    once = true,
    callback = function()
      finished = true
      self.composer = nil
    end,
  })
  vim.cmd("startinsert")
end

return Panel
