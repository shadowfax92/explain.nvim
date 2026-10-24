---explain.nvim lets an agent walk you through code. `:Explain start` serves a
---localhost URL; an agent reads the guide there and builds tours of highlighted
---steps in your real files; you read them beside a thread panel and reply.
---
---This module is the composition root and the only stateful glue:
---
---  agent ──HTTP──> transport ──> api ──> session ──events──> render()
---                                           ^                 ├─> marks (code buffers)
---  you ──keys──> controller ──human actions─┘                 ├─> panel (steps, thread)
---                                                             └─> nudge (agent's pane)
---
---It owns the view state (which tour and step you are on), turns session
---events into one coalesced render per main-loop tick, and decides when to
---notify you or nudge the agent.
local Session = require("explain.session")
local api = require("explain.api")
local transport = require("explain.transport")
local Marks = require("explain.marks")
local Panel = require("explain.panel")
local Nudge = require("explain.nudge")
local highlight = require("explain.highlight")

local M = {}

local defaults = {
  -- Global keymaps exist only while explain runs. Set any to false to skip it.
  keymaps = {
    next = "]x",
    prev = "[x",
    reply = "<leader>kr",
    ask = "<leader>ka",
    resolve = "<leader>kx",
    panel = "<leader>kp",
    tours = "<leader>kt",
  },
  -- Wake an idle agent through its herdr pane when you write. `false` disables;
  -- a table is passed to the nudge (delay_ms, run) and exists for tests.
  nudge = true,
}

local config = vim.deepcopy(defaults)
local state -- nil while stopped

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "explain" })
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

local function agent_line(url)
  return ("Annotate code for me in my editor with explain. Start by running: curl -s %s"):format(url)
end

local function copy(text)
  vim.fn.setreg('"', text)
  pcall(vim.fn.setreg, "+", text)
end

local function find_step(id)
  for _, tour in ipairs(state.session:snapshot().tours) do
    for position, step in ipairs(tour.steps) do
      if step.id == id then
        return step, tour, position
      end
    end
  end
end

local function current_tour(snapshot)
  for _, tour in ipairs(snapshot.tours) do
    if tour.id == state.view.tour_id then
      return tour
    end
  end
end

local function render()
  if not state then
    return
  end
  local snapshot = state.session:snapshot()
  state.marks:render(snapshot, state.view.step_id)
  state.panel:render(snapshot, { tour_id = state.view.tour_id, step_id = state.view.step_id, url = state.server.url })
  -- You are looking at the current step's thread, so its replies are read.
  if state.view.step_id and state.panel:is_open() then
    state.session:mark_seen(state.view.step_id)
  end
  vim.cmd("redrawstatus")
end

local function schedule_render()
  if not state or state.render_pending then
    return
  end
  state.render_pending = true
  vim.schedule(function()
    if state then
      state.render_pending = false
      render()
    end
  end)
end

local function on_event(event)
  if event.type == "tour_created" then
    local tour = state.session.tour_by_id[event.tour_id]
    if not state.view.tour_id then
      state.view.tour_id = event.tour_id
      state.panel:open()
    elseif tour.origin ~= "human" then
      local key = config.keymaps.tours or ":Explain tours"
      notify(("%s started %q (%s to switch)"):format(tour.agent or "agent", tour.title, key))
    end
  elseif event.type == "message" then
    local step = state.session.step_by_id[event.step_id]
    if event.author == "agent" and (event.step_id ~= state.view.step_id or not state.panel:is_open()) then
      notify(("%s replied on %q"):format(state.session.tour_by_id[step.tour_id].agent or "agent", step.title))
    elseif event.author == "human" and event.needs_nudge and state.nudge then
      state.nudge:send(
        event.pane,
        ('[explain] New %s from the human on "%s". Call read_messages at %s (after=%d).'):format(
          event.kind == "question" and "question" or "reply",
          step.title,
          state.server.url,
          event.seq - 1
        )
      )
    end
  end
  schedule_render()
end

local function is_code_window(win)
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_config(win).relative ~= "" then
    return false
  end
  if state and state.panel.win == win then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.bo[buf].buftype == "" and vim.bo[buf].filetype ~= "explain_compose"
end

-- The window steps open in: the last code window you used, else any code
-- window in this tab, else a new split left of the panel.
local function code_window()
  if state.last_code_win and is_code_window(state.last_code_win) then
    return state.last_code_win
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_code_window(win) then
      return win
    end
  end
  return vim.api.nvim_open_win(vim.api.nvim_create_buf(true, false), false, { split = "left", win = state.panel.win })
end

local function show(path, line, focus)
  local win = code_window()
  vim.api.nvim_win_call(win, function()
    if vim.api.nvim_buf_get_name(0) ~= path then
      vim.cmd.edit(vim.fn.fnameescape(path))
    end
  end)
  render() -- places anchors in a buffer that just loaded
  local count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
  vim.api.nvim_win_set_cursor(win, { math.min(line, count), 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zz")
  end)
  if focus then
    vim.api.nvim_set_current_win(win)
  end
end

---Moves to a step: opens its file in the code window at the step's current
---first line. `focus` moves the cursor into the code window.
function M.goto_step(step_id, focus)
  if not state then
    return
  end
  local step = find_step(step_id)
  if not step then
    return
  end
  state.view.tour_id, state.view.step_id = step.tour_id, step.id
  local first = state.marks:live_range(step.id) or step.start_line
  show(step.path, first, focus ~= false)
  render()
end

local function move(delta, focus)
  if not state then
    return notify("explain is not running", vim.log.levels.WARN)
  end
  local snapshot = state.session:snapshot()
  local tour = current_tour(snapshot) or snapshot.tours[1]
  if not tour or #tour.steps == 0 then
    return notify("no steps yet")
  end
  local index = 0
  for position, step in ipairs(tour.steps) do
    if step.id == state.view.step_id then
      index = position
    end
  end
  local target = index == 0 and (delta > 0 and 1 or #tour.steps) or index + delta
  if target < 1 or target > #tour.steps then
    return notify(delta > 0 and "last step of the tour" or "first step of the tour")
  end
  M.goto_step(tour.steps[target].id, focus)
end

function M.next(focus)
  move(1, focus)
end

function M.prev(focus)
  move(-1, focus)
end

---Writes a reply on the current step.
function M.reply()
  if not state or not state.view.step_id then
    return notify("no current step; ]x moves to the first one", vim.log.levels.WARN)
  end
  local step_id = state.view.step_id
  local _, _, position = find_step(step_id)
  state.panel:compose({ title = ("reply on step %d"):format(position) }, function(text)
    if state and state.session.step_by_id[step_id] then
      state.session:reply(step_id, text)
    end
  end)
end

---Asks a question about lines of the current buffer (the visual selection
---when called from the keymap). The question becomes a step after the one
---you are on.
---@param range? { start_line: integer, end_line: integer }
function M.ask(range)
  if not state then
    return notify("explain is not running", vim.log.levels.WARN)
  end
  if not range then
    local first, last = vim.fn.line("v"), vim.fn.line(".")
    range = { start_line = math.min(first, last), end_line = math.max(first, last) }
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  end
  local path = vim.api.nvim_buf_get_name(0)
  if vim.bo.buftype ~= "" or path == "" then
    return notify("select lines in a file to ask about them", vim.log.levels.WARN)
  end
  local title = ("ask about %s:%d-%d"):format(vim.fn.fnamemodify(path, ":t"), range.start_line, range.end_line)
  state.panel:compose({ title = title }, function(text)
    if not state then
      return
    end
    local asked = state.session:ask({
      path = path,
      start_line = range.start_line,
      end_line = range.end_line,
      text = text,
      tour_id = state.view.tour_id,
      after_step_id = state.view.step_id,
    })
    state.view.tour_id, state.view.step_id = asked.tour_id, asked.step_id
    schedule_render()
  end)
end

---Flips the current step between resolved and open.
function M.resolve()
  if state and state.view.step_id then
    state.session:resolve(state.view.step_id)
  end
end

function M.toggle_panel()
  if not state then
    return notify("explain is not running", vim.log.levels.WARN)
  end
  state.panel:toggle()
  schedule_render()
end

function M.pick_tour()
  if not state then
    return notify("explain is not running", vim.log.levels.WARN)
  end
  local tours = state.session:snapshot().tours
  if #tours == 0 then
    return notify("no tours yet")
  end
  vim.ui.select(tours, {
    prompt = "explain tours",
    format_item = function(tour)
      return ("%s · %d steps"):format(tour.title, #tour.steps)
    end,
  }, function(tour)
    if tour and state then
      state.view.tour_id, state.view.step_id = tour.id, nil
      state.panel:open()
      schedule_render()
    end
  end)
end

local function open_reference(path, line)
  local absolute = path:sub(1, 1) == "/" and path or vim.fs.joinpath(state.session.cwd, path)
  if vim.fn.filereadable(absolute) == 0 then
    return notify("no such file: " .. path, vim.log.levels.WARN)
  end
  show(vim.fs.normalize(absolute), line, true)
end

local function set_keymaps()
  local keys = config.keymaps
  local function map(mode, lhs, fn, desc)
    if lhs then
      vim.keymap.set(mode, lhs, fn, { desc = "explain: " .. desc })
      state.keymaps[#state.keymaps + 1] = { mode, lhs }
    end
  end
  map("n", keys.next, function()
    M.next()
  end, "next step")
  map("n", keys.prev, function()
    M.prev()
  end, "previous step")
  map("n", keys.reply, M.reply, "reply on step")
  map("x", keys.ask, function()
    M.ask()
  end, "ask about selection")
  map("n", keys.resolve, M.resolve, "resolve step")
  map("n", keys.panel, M.toggle_panel, "toggle panel")
  map("n", keys.tours, M.pick_tour, "pick tour")
end

---Starts serving (or re-copies the line when already running) and returns the URL.
function M.start()
  if state then
    copy(agent_line(state.server.url))
    notify("copied: " .. agent_line(state.server.url))
    return state.server.url
  end
  highlight.setup()
  local session = Session.new({ cwd = vim.fn.getcwd() })
  local token = (vim.uv.random(4):gsub(".", function(char)
    return ("%02x"):format(char:byte())
  end))
  local server, err = transport.start({ token = token, handler = api.handler(session) })
  if not server then
    return notify("could not start: " .. tostring(err), vim.log.levels.ERROR)
  end
  local nudge_opts = config.nudge
  state = {
    session = session,
    server = server,
    view = {},
    keymaps = {},
    nudge = nudge_opts and Nudge.new(type(nudge_opts) == "table" and nudge_opts or nil) or nil,
    group = vim.api.nvim_create_augroup("explain", { clear = true }),
  }
  state.marks = Marks.new({
    on_unload = function(step_id, first, last)
      session:set_range(step_id, first, last)
    end,
  })
  state.panel = Panel.new({
    display_path = function(path)
      return session:display_path(path)
    end,
    on_jump = function(step_id)
      M.goto_step(step_id, true)
    end,
    on_reply = M.reply,
    on_resolve = M.resolve,
    on_next = function()
      M.next(false)
    end,
    on_prev = function()
      M.prev(false)
    end,
    on_open_ref = open_reference,
  })
  state.unsubscribe = session:subscribe(on_event)
  vim.api.nvim_create_autocmd("WinEnter", {
    group = state.group,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if is_code_window(win) then
        state.last_code_win = win
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = state.group, callback = M.stop })
  set_keymaps()
  local line = agent_line(server.url)
  copy(line)
  notify("listening; copied for your agent:\n" .. line)
  vim.cmd("redrawstatus")
  return server.url
end

---Stops serving and clears every tour, band and panel.
function M.stop()
  if not state then
    return
  end
  local current = state
  state = nil
  current.unsubscribe()
  current.session:close()
  current.server:stop()
  if current.nudge then
    current.nudge:close()
  end
  current.marks:clear()
  current.panel:close()
  if current.panel.buf and vim.api.nvim_buf_is_valid(current.panel.buf) then
    vim.api.nvim_buf_delete(current.panel.buf, { force = true })
  end
  for _, keymap in ipairs(current.keymaps) do
    pcall(vim.keymap.del, keymap[1], keymap[2])
  end
  pcall(vim.api.nvim_del_augroup_by_id, current.group)
  vim.cmd("redrawstatus")
end

---The agent line for the running instance, or nil.
function M.url()
  return state and state.server.url or nil
end

---A statusline component: empty while stopped.
function M.statusline()
  if not state then
    return ""
  end
  local text = ("◆ explain :%d"):format(state.server.port)
  local unread = state.session:unread_total()
  if unread > 0 then
    text = text .. (" · %d new"):format(unread)
  end
  return text
end

---Entry point for `:Explain {start|stop|url|panel|tours|next|prev}`.
function M.command(args)
  local sub = args[1] or (state and "panel" or "start")
  local actions = {
    start = M.start,
    stop = M.stop,
    url = function()
      if not state then
        return notify("explain is not running; :Explain start", vim.log.levels.WARN)
      end
      M.start()
    end,
    panel = M.toggle_panel,
    tours = M.pick_tour,
    next = M.next,
    prev = M.prev,
  }
  local action = actions[sub]
  if not action then
    return notify("unknown subcommand: " .. sub, vim.log.levels.ERROR)
  end
  action()
end

M.subcommands = { "start", "stop", "url", "panel", "tours", "next", "prev" }

return M
