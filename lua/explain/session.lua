---Session is the in-memory model of one `:Explain start` run: tours, their
---ordered steps, step threads, and the long-polls agents leave open. Agents
---reach it through `call()` (the tool table below is the agent-facing contract,
---rendered verbatim by the HTTP guide); the editor reaches it through the human
---actions. It never touches windows or sockets and must only run on the main
---loop, because validation reads loaded buffers.
local Session = {}
Session.__index = Session

local WAIT_DEFAULT_S, WAIT_MAX_S = 45, 50

local function integer(description, minimum)
  return { type = "integer", minimum = minimum or 1, description = description }
end

local function text(description)
  return { type = "string", minLength = 1, description = description }
end

-- Tool definitions follow MCP's Tool shape (spec 2026-07-28) so the same table
-- can back a real /mcp endpoint later. `handler` names the method that runs it.
local TOOLS = {
  {
    name = "create_tour",
    title = "Create tour",
    handler = "_create_tour",
    description = "Start a new tour: an ordered walk through code for the human. Returns tour_id. "
      .. "The first tour of a session opens in the human's panel.",
    inputSchema = {
      type = "object",
      properties = {
        title = text("Short title shown to the human, e.g. 'How a request is routed'."),
        agent = text("Your display name, e.g. 'claude' or 'codex'. Defaults to 'agent'."),
        summary = text("Optional one-paragraph overview of the tour."),
      },
      required = { "title" },
      additionalProperties = false,
    },
  },
  {
    name = "add_step",
    title = "Add step",
    handler = "_add_step",
    description = "Highlight a line range in a file and attach a note. Steps are shown in the order you add them "
      .. "unless after_step_id is given. Lines are 1-based and inclusive, counted in the file as the human sees it. "
      .. "The result echoes the first and last highlighted lines so you can check the range.",
    inputSchema = {
      type = "object",
      properties = {
        tour_id = integer("Tour returned by create_tour."),
        path = text("File path, absolute or relative to the editor's working directory."),
        start_line = integer("First highlighted line (1-based)."),
        end_line = integer("Last highlighted line (1-based, inclusive)."),
        title = text("Short step title, e.g. 'The single funnel'."),
        note = text("Your explanation, 2-4 sentences. Write path:line to link other code."),
        after_step_id = integer("Insert after this step instead of appending."),
      },
      required = { "tour_id", "path", "start_line", "end_line", "title", "note" },
      additionalProperties = false,
    },
  },
  {
    name = "update_step",
    title = "Revise a step",
    handler = "_update_step",
    description = "Change a step's title, note or line range. A changed note is shown to the human as edited; "
      .. "prefer reply for answers so the thread keeps its history.",
    inputSchema = {
      type = "object",
      properties = {
        step_id = integer("Step to revise."),
        title = text("New title."),
        note = text("New note."),
        start_line = integer("New first line."),
        end_line = integer("New last line."),
      },
      required = { "step_id" },
      additionalProperties = false,
    },
  },
  {
    name = "reply",
    title = "Reply in a step's thread",
    handler = "_agent_reply",
    description = "Post a message in a step's thread, usually to answer the human. Write path:line to link code.",
    inputSchema = {
      type = "object",
      properties = {
        step_id = integer("Step whose thread you are answering."),
        text = text("Your message."),
      },
      required = { "step_id", "text" },
      additionalProperties = false,
    },
  },
  {
    name = "read_messages",
    title = "Read the human's messages",
    handler = "_read_messages",
    description = "Return the human's replies and new questions posted after `after`. Pass the returned cursor as "
      .. "`after` next time. New questions carry the file range the human selected.",
    inputSchema = {
      type = "object",
      properties = {
        after = integer("Cursor from the previous read; 0 or omitted reads everything.", 0),
      },
      additionalProperties = false,
    },
  },
  {
    name = "wait_for_human",
    title = "Wait for the human",
    handler = "_wait_for_human",
    description = "Like read_messages, but if nothing is new it holds the request open until the human writes or "
      .. "timeout_s passes (then it returns no messages). Call it in a loop to stay in the conversation.",
    inputSchema = {
      type = "object",
      properties = {
        after = integer("Cursor from the previous read.", 0),
        timeout_s = vim.tbl_extend("force", integer("Seconds to wait, default 45."), { maximum = WAIT_MAX_S }),
      },
      required = { "after" },
      additionalProperties = false,
    },
  },
  {
    name = "get_tour",
    title = "Read tours",
    handler = "_get_tour",
    description = "Without tour_id: list tours. With tour_id: every step with its current line range (it follows "
      .. "the human's edits), resolved state, note and full thread.",
    inputSchema = {
      type = "object",
      properties = {
        tour_id = integer("Tour to read in full."),
      },
      additionalProperties = false,
    },
  },
}

local TOOL_BY_NAME = {}
for _, tool in ipairs(TOOLS) do
  TOOL_BY_NAME[tool.name] = tool
end

-- Validates arguments against the subset of JSON Schema the tool table uses.
-- Messages are written for the agent: they name the argument and the fix.
local function check(tool, args)
  local schema = tool.inputSchema
  if type(args) ~= "table" or vim.islist(args) and next(args) ~= nil then
    return nil, tool.name .. ": arguments must be a JSON object"
  end
  local clean = {}
  for key, value in pairs(args) do
    local spec = schema.properties[key]
    if not spec then
      local known = vim.tbl_keys(schema.properties)
      table.sort(known)
      return nil, ("%s: unknown argument `%s`; expected %s"):format(tool.name, key, table.concat(known, ", "))
    end
    if value ~= vim.NIL then
      if spec.type == "integer" then
        if type(value) ~= "number" or value % 1 ~= 0 then
          return nil, ("%s: `%s` must be an integer"):format(tool.name, key)
        end
        if spec.minimum and value < spec.minimum then
          return nil, ("%s: `%s` must be at least %d"):format(tool.name, key, spec.minimum)
        end
        if spec.maximum and value > spec.maximum then
          return nil, ("%s: `%s` must be at most %d"):format(tool.name, key, spec.maximum)
        end
      elseif spec.type == "string" then
        if type(value) ~= "string" or (spec.minLength and #vim.trim(value) < spec.minLength) then
          return nil, ("%s: `%s` must be a non-empty string"):format(tool.name, key)
        end
      end
      clean[key] = value
    end
  end
  for _, key in ipairs(schema.required or {}) do
    if clean[key] == nil then
      return nil, ("%s: missing required argument `%s` (%s)"):format(tool.name, key, schema.properties[key].type)
    end
  end
  return clean
end

local function ok(text_summary, data)
  return { status = "ok", text = text_summary, data = data }
end

local function failure(message)
  return { status = "error", text = message }
end

---`live_range(step_id, revision)` is how the editor reports where a step's
---code sits now (it follows the human's edits); it returns nil when it has no
---position for that revision, and agents then read the stored range.
---@param opts { cwd?: string, live_range?: fun(step_id: integer, revision: integer): integer?, integer? }
function Session.new(opts)
  opts = opts or {}
  local cwd = vim.uv.fs_realpath(opts.cwd or vim.fn.getcwd()) or opts.cwd
  return setmetatable({
    cwd = cwd,
    live_range = opts.live_range,
    tours = {},
    tour_by_id = {},
    step_by_id = {},
    last_id = 0,
    seq = 0,
    listeners = {},
    waiters = {},
  }, Session)
end

---The agent-facing tool definitions (MCP Tool shape, without handlers).
function Session:tools()
  local out = {}
  for _, tool in ipairs(TOOLS) do
    out[#out + 1] = {
      name = tool.name,
      title = tool.title,
      description = tool.description,
      inputSchema = vim.deepcopy(tool.inputSchema),
    }
  end
  return out
end

---Runs one agent tool. `done` receives `{status, text, data}` where status is
---"ok", "error" (the agent can fix its call) or "unknown_tool". Most tools
---finish synchronously; long-polls call `done` later.
---@param ctx { pane?: string }
function Session:call(name, args, ctx, done)
  local tool = TOOL_BY_NAME[name]
  if not tool then
    local names = vim.tbl_map(function(t)
      return t.name
    end, TOOLS)
    return done({ status = "unknown_tool", text = ("unknown tool `%s`; available: %s"):format(name, table.concat(names, ", ")) })
  end
  if self.closed then
    return done(failure("explain session ended (the human ran :Explain stop)"))
  end
  ctx = ctx or {}
  if ctx.pane and ctx.pane ~= "" then
    self.last_pane = ctx.pane
  end
  local clean, err = check(tool, args or {})
  if not clean then
    return done(failure(err))
  end
  return self[tool.handler](self, clean, ctx, done)
end

function Session:_next_id()
  self.last_id = self.last_id + 1
  return self.last_id
end

-- Resolves a path against the editor cwd and returns the real absolute path.
function Session:_resolve(path)
  local absolute = vim.fs.normalize(path:sub(1, 1) == "/" and path or vim.fs.joinpath(self.cwd, path))
  local real = vim.uv.fs_realpath(absolute)
  local stat = real and vim.uv.fs_stat(real)
  if not stat or stat.type ~= "file" then
    return nil, ("file not found: %s (relative paths resolve against %s)"):format(path, self.cwd)
  end
  return real
end

-- Lines as the human sees them: a loaded buffer wins over the file on disk.
local function read_lines(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == path then
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end
  end
  return vim.fn.readfile(path)
end

local function check_range(tool, shown_path, line_count, first, last)
  if last < first then
    return ("%s: end_line %d is before start_line %d"):format(tool, last, first)
  end
  if last > line_count then
    return ("%s: %s has %d lines; end_line %d is past the end"):format(tool, shown_path, line_count, last)
  end
end

function Session:_create_tour(args, ctx, done)
  local tour = {
    id = self:_next_id(),
    title = vim.trim(args.title),
    agent = args.agent and vim.trim(args.agent) or "agent",
    summary = args.summary,
    pane = ctx.pane,
    origin = "agent",
    steps = {},
  }
  self.tours[#self.tours + 1] = tour
  self.tour_by_id[tour.id] = tour
  self:_emit({ type = "tour_created", tour_id = tour.id })
  return done(ok(("created tour %d %q"):format(tour.id, tour.title), { tour_id = tour.id }))
end

function Session:_add_step(args, _, done)
  local tour = self.tour_by_id[args.tour_id]
  if not tour then
    return done(failure(self:_unknown_tour(args.tour_id)))
  end
  local path, err = self:_resolve(args.path)
  if not path then
    return done(failure("add_step: " .. err))
  end
  local lines = read_lines(path)
  local range_err = check_range("add_step", args.path, #lines, args.start_line, args.end_line)
  if range_err then
    return done(failure(range_err))
  end
  local index = #tour.steps + 1
  if args.after_step_id then
    local after = self.step_by_id[args.after_step_id]
    if not after or after.tour_id ~= tour.id then
      return done(failure(("add_step: after_step_id %d is not a step of tour %d"):format(args.after_step_id, tour.id)))
    end
    index = vim.fn.index(tour.steps, after.id) + 2
  end
  local step = {
    id = self:_next_id(),
    tour_id = tour.id,
    path = path,
    start_line = args.start_line,
    end_line = args.end_line,
    title = vim.trim(args.title),
    note = args.note,
    origin = "agent",
    resolved = false,
    unread = 0,
    messages = {},
    -- Bumped whenever the agent moves the range, so positions the editor
    -- tracked for an older revision stop counting.
    revision = 1,
  }
  table.insert(tour.steps, index, step.id)
  self.step_by_id[step.id] = step
  self:_emit({ type = "step_added", tour_id = tour.id, step_id = step.id })
  return done(ok(("added step %d at position %d of tour %d"):format(step.id, index, tour.id), {
    step_id = step.id,
    position = index,
    path = self:display_path(path),
    start_line = step.start_line,
    end_line = step.end_line,
    first_line = lines[step.start_line],
    last_line = lines[step.end_line],
  }))
end

function Session:_update_step(args, _, done)
  local step = self.step_by_id[args.step_id]
  if not step then
    return done(failure("update_step: " .. self:_unknown_step(args.step_id)))
  end
  local first, last = args.start_line or step.start_line, args.end_line or step.end_line
  local lines = read_lines(step.path)
  local range_err = check_range("update_step", self:display_path(step.path), #lines, first, last)
  if range_err then
    return done(failure(range_err))
  end
  if args.start_line or args.end_line then
    step.revision = step.revision + 1
  end
  step.start_line, step.end_line = first, last
  step.title = args.title and vim.trim(args.title) or step.title
  if args.note and args.note ~= step.note then
    step.note, step.note_edited_at = args.note, os.time()
    step.unread = step.unread + 1
  end
  self:_emit({ type = "step_updated", tour_id = step.tour_id, step_id = step.id })
  return done(ok(("updated step %d"):format(step.id), {
    step_id = step.id,
    start_line = first,
    end_line = last,
    first_line = lines[first],
    last_line = lines[last],
  }))
end

function Session:_get_tour(args, _, done)
  if not args.tour_id then
    local tours = vim.tbl_map(function(tour)
      return { tour_id = tour.id, title = tour.title, steps = #tour.steps }
    end, self.tours)
    return done(ok(("%d tour%s"):format(#tours, #tours == 1 and "" or "s"), { tours = tours }))
  end
  local tour = self.tour_by_id[args.tour_id]
  if not tour then
    return done(failure("get_tour: " .. self:_unknown_tour(args.tour_id)))
  end
  local steps = {}
  for position, id in ipairs(tour.steps) do
    local step = self.step_by_id[id]
    local first, last = self:_range(step)
    steps[#steps + 1] = {
      step_id = step.id,
      position = position,
      title = step.title,
      path = self:display_path(step.path),
      start_line = first,
      end_line = last,
      note = step.note,
      origin = step.origin,
      resolved = step.resolved,
      messages = vim.tbl_map(function(message)
        return { seq = message.seq, author = message.author, kind = message.kind, text = message.text }
      end, step.messages),
    }
  end
  return done(ok(("tour %d %q with %d steps"):format(tour.id, tour.title, #steps), {
    tour_id = tour.id,
    title = tour.title,
    agent = tour.agent,
    summary = tour.summary,
    steps = steps,
  }))
end

function Session:_unknown_step(id)
  local known = {}
  for _, tour in ipairs(self.tours) do
    for _, step_id in ipairs(tour.steps) do
      known[#known + 1] = ("%d %q"):format(step_id, self.step_by_id[step_id].title)
    end
  end
  return ("step %s not found; existing steps: %s"):format(
    tostring(id),
    #known > 0 and table.concat(known, ", ") or "none (call add_step first)"
  )
end

-- Appends a message to a step's thread. Every message, from either side,
-- takes the next global sequence number, so any returned cursor stays valid.
function Session:_post(step, author, kind, body)
  self.seq = self.seq + 1
  local tour = self.tour_by_id[step.tour_id]
  local message = {
    id = self.seq,
    seq = self.seq,
    author = author,
    agent = author == "agent" and tour.agent or nil,
    kind = kind,
    text = body,
    at = os.time(),
  }
  step.messages[#step.messages + 1] = message
  if author == "agent" then
    step.unread = step.unread + 1
  end
  -- An agent blocked in wait_for_human hears this message through its open
  -- request, so it needs no terminal nudge. Decide before releasing waits.
  local needs_nudge = author == "human" and next(self.waiters) == nil
  if author == "human" then
    self:_release_waiters()
  end
  self:_emit({
    type = "message",
    author = author,
    kind = kind,
    tour_id = step.tour_id,
    step_id = step.id,
    seq = self.seq,
    needs_nudge = needs_nudge,
    pane = tour.pane or self.last_pane,
  })
  return message
end

function Session:_wait_for_human(args, ctx, done)
  local pending = self:_human_messages_after(args.after)
  if #pending > 0 then
    return done(self:_messages_result(args.after))
  end
  local waiter = { after = args.after, timer = vim.uv.new_timer() }
  waiter.finish = function(result)
    if not self.waiters[waiter] then
      return
    end
    self.waiters[waiter] = nil
    waiter.timer:stop()
    waiter.timer:close()
    done(result)
  end
  self.waiters[waiter] = true
  -- An agent whose request dropped (curl timeout, Ctrl-C) is no longer
  -- listening: forget the wait so the next human message nudges it instead.
  if ctx.on_cancel then
    ctx.on_cancel(function()
      if self.waiters[waiter] then
        self.waiters[waiter] = nil
        waiter.timer:stop()
        waiter.timer:close()
      end
    end)
  end
  -- Timer callbacks run in libuv's fast context; hop to the main loop first.
  waiter.timer:start(
    (args.timeout_s or WAIT_DEFAULT_S) * 1000,
    0,
    vim.schedule_wrap(function()
      waiter.finish(self:_messages_result(waiter.after))
    end)
  )
end

function Session:_release_waiters()
  for waiter in pairs(self.waiters) do
    waiter.finish(self:_messages_result(waiter.after))
  end
end

---Ends the session: open waits return an error and further calls fail.
function Session:close()
  self.closed = true
  for waiter in pairs(self.waiters) do
    waiter.finish(failure("explain session ended (the human ran :Explain stop)"))
  end
  self.listeners = {}
end

function Session:_agent_reply(args, _, done)
  local step = self.step_by_id[args.step_id]
  if not step then
    return done(failure("reply: " .. self:_unknown_step(args.step_id)))
  end
  local message = self:_post(step, "agent", "reply", args.text)
  return done(ok(("posted message %d on step %d"):format(message.id, step.id), { message_id = message.id }))
end

-- Where a step's code is now: the editor's live position for the current
-- revision when it has one, else the last stored range.
function Session:_range(step)
  if self.live_range then
    local first, last = self.live_range(step.id, step.revision)
    if first then
      return first, last
    end
  end
  return step.start_line, step.end_line
end

-- Human messages with seq > after, oldest first, in the shape agents read.
function Session:_human_messages_after(after)
  local out = {}
  for _, step in pairs(self.step_by_id) do
    for _, message in ipairs(step.messages) do
      if message.author == "human" and message.seq > after then
        out[#out + 1] = {
          seq = message.seq,
          kind = message.kind,
          text = message.text,
          tour_id = step.tour_id,
          step_id = step.id,
          step_title = step.title,
          path = self:display_path(step.path),
        }
        out[#out].start_line, out[#out].end_line = self:_range(step)
      end
    end
  end
  table.sort(out, function(a, b)
    return a.seq < b.seq
  end)
  return out
end

function Session:_messages_result(after)
  local messages = self:_human_messages_after(after)
  local summary = #messages == 0 and "no new messages"
    or ("%d new message%s from the human"):format(#messages, #messages == 1 and "" or "s")
  return ok(("%s; cursor %d"):format(summary, self.seq), { cursor = self.seq, messages = messages })
end

function Session:_read_messages(args, _, done)
  return done(self:_messages_result(args.after or 0))
end

-- Human actions. The editor calls these directly; they never fail on input
-- an agent could fix, so they raise on programming errors instead.

---Posts the human's reply on a step and returns the message.
function Session:reply(step_id, body)
  local step = assert(self.step_by_id[step_id], "unknown step")
  return self:_post(step, "human", "reply", body)
end

---Turns a human question on a code range into a step with its first message.
---The step goes after `after_step_id` when given, else at the end of
---`tour_id`, else into a "Your questions" tour created on demand.
---@param opts { path: string, start_line: integer, end_line: integer, text: string, after_step_id?: integer, tour_id?: integer }
---@return { tour_id: integer, step_id: integer }
function Session:ask(opts)
  local tour, index
  local after = opts.after_step_id and self.step_by_id[opts.after_step_id]
  if after then
    tour = self.tour_by_id[after.tour_id]
    index = vim.fn.index(tour.steps, after.id) + 2
  else
    tour = opts.tour_id and self.tour_by_id[opts.tour_id]
    if not tour then
      for _, candidate in ipairs(self.tours) do
        if candidate.origin == "human" then
          tour = candidate
        end
      end
    end
    if not tour then
      tour = { id = self:_next_id(), title = "Your questions", origin = "human", steps = {} }
      self.tours[#self.tours + 1] = tour
      self.tour_by_id[tour.id] = tour
      self:_emit({ type = "tour_created", tour_id = tour.id })
    end
    index = #tour.steps + 1
  end
  local headline = vim.split(vim.trim(opts.text), "\n", { plain = true })[1]
  local step = {
    id = self:_next_id(),
    tour_id = tour.id,
    path = opts.path,
    start_line = opts.start_line,
    end_line = opts.end_line,
    title = #headline > 60 and (headline:sub(1, 59) .. "…") or headline,
    origin = "human",
    resolved = false,
    unread = 0,
    messages = {},
    revision = 1,
  }
  table.insert(tour.steps, index, step.id)
  self.step_by_id[step.id] = step
  self:_emit({ type = "step_added", tour_id = tour.id, step_id = step.id })
  self:_post(step, "human", "question", opts.text)
  return { tour_id = tour.id, step_id = step.id }
end

---Flips a step between resolved and open.
function Session:resolve(step_id)
  local step = assert(self.step_by_id[step_id], "unknown step")
  step.resolved = not step.resolved
  self:_emit({ type = "step_updated", tour_id = step.tour_id, step_id = step.id })
end

---Records a step's current lines after the human's edits moved the code.
---Positions tracked for an older revision are ignored.
function Session:set_range(step_id, first, last, revision)
  local step = self.step_by_id[step_id]
  if step and (revision == nil or revision == step.revision) then
    step.start_line, step.end_line = first, last
  end
end

---Clears the unread count of agent messages on a step.
function Session:mark_seen(step_id)
  local step = self.step_by_id[step_id]
  if step and step.unread > 0 then
    step.unread = 0
    self:_emit({ type = "seen", tour_id = step.tour_id, step_id = step.id })
  end
end

function Session:unread_total()
  local total = 0
  for _, step in pairs(self.step_by_id) do
    total = total + step.unread
  end
  return total
end

function Session:_unknown_tour(id)
  local known = vim.tbl_map(function(tour)
    return ("%d %q"):format(tour.id, tour.title)
  end, self.tours)
  return ("tour %s not found; existing tours: %s"):format(
    tostring(id),
    #known > 0 and table.concat(known, ", ") or "none (call create_tour first)"
  )
end

---Path relative to the session cwd when inside it, else absolute.
function Session:display_path(path)
  local prefix = self.cwd .. "/"
  if path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end
  return path
end

---A deep copy of every tour with its steps resolved in order. Callers render
---from it; mutating it has no effect on the session.
function Session:snapshot()
  local tours = {}
  for _, tour in ipairs(self.tours) do
    local copy = vim.deepcopy(tour)
    copy.steps = vim.tbl_map(function(id)
      return vim.deepcopy(self.step_by_id[id])
    end, tour.steps)
    tours[#tours + 1] = copy
  end
  return { tours = tours, seq = self.seq }
end

---Registers a change listener and returns a function that removes it.
function Session:subscribe(listener)
  self.listeners[listener] = true
  return function()
    self.listeners[listener] = nil
  end
end

function Session:_emit(event)
  for listener in pairs(self.listeners) do
    listener(event)
  end
end

return Session
