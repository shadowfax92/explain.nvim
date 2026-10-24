local h = dofile("tests/helpers.lua")
local Session = require("explain.session")

local function call(session, name, args, ctx)
  return h.await(function(done)
    session:call(name, args or {}, ctx or {}, done)
  end)
end

local function tour_with_step(session, path)
  local tour = call(session, "create_tour", { title = "How a review opens", agent = "claude" })
  local step = call(session, "add_step", {
    tour_id = tour.data.tour_id,
    path = path,
    start_line = 3,
    end_line = 5,
    title = "The single funnel",
    note = "Every review walks through here.",
  })
  return tour.data.tour_id, step.data.step_id
end

local cases = {}

cases["add_step echoes the first and last annotated lines"] = function()
  local path, dir = h.file(h.numbered(20))
  local session = Session.new({ cwd = dir })
  local tour = call(session, "create_tour", { title = "How a review opens", agent = "claude" })
  h.eq("ok", tour.status)
  local step = call(session, "add_step", {
    tour_id = tour.data.tour_id,
    path = "sample.lua",
    start_line = 3,
    end_line = 5,
    title = "The single funnel",
    note = "Every review walks through here.",
  })
  h.eq("ok", step.status, step.text)
  h.eq("line 3", step.data.first_line)
  h.eq("line 5", step.data.last_line)
  h.eq(1, step.data.position)
  h.eq(path, session:snapshot().tours[1].steps[1].path)
end

cases["bad calls explain how to fix them"] = function()
  local _, dir = h.file(h.numbered(20))
  local session = Session.new({ cwd = dir })
  local missing = call(session, "add_step", { tour_id = 1, path = "sample.lua", start_line = 1, title = "t", note = "n" })
  h.eq("error", missing.status)
  h.contains(missing.text, "missing required argument `end_line`")

  local unknown = call(session, "add_step", {
    tour_id = 9, path = "sample.lua", start_line = 1, end_line = 2, title = "t", note = "n",
  })
  h.contains(unknown.text, "tour 9 not found; existing tours: none (call create_tour first)")

  local tour_id = call(session, "create_tour", { title = "T" }).data.tour_id
  local past = call(session, "add_step", {
    tour_id = tour_id, path = "sample.lua", start_line = 18, end_line = 25, title = "t", note = "n",
  })
  h.contains(past.text, "sample.lua has 20 lines; end_line 25 is past the end")

  local extra = call(session, "create_tour", { title = "T", colour = "red" })
  h.contains(extra.text, "unknown argument `colour`")

  local nofile = call(session, "add_step", {
    tour_id = tour_id, path = "nope.lua", start_line = 1, end_line = 1, title = "t", note = "n",
  })
  h.contains(nofile.text, "file not found: nope.lua")

  h.eq("unknown_tool", call(session, "explode", {}).status)
end

cases["after_step_id inserts instead of appending"] = function()
  local path, dir = h.file(h.numbered(20))
  local session = Session.new({ cwd = dir })
  local tour_id, first = tour_with_step(session, path)
  local add = function(title, after)
    return call(session, "add_step", {
      tour_id = tour_id, path = path, start_line = 1, end_line = 1, title = title, note = "n", after_step_id = after,
    })
  end
  add("last")
  local middle = add("middle", first)
  h.eq(2, middle.data.position)
  local titles = vim.tbl_map(function(step)
    return step.title
  end, session:snapshot().tours[1].steps)
  h.eq({ "The single funnel", "middle", "last" }, titles)
end

cases["read_messages returns only human messages after the cursor"] = function()
  local path, dir = h.file(h.numbered(20))
  local session = Session.new({ cwd = dir })
  local tour_id, step_id = tour_with_step(session, path)
  session:reply(step_id, "Where does cwd come from?")
  local first = call(session, "read_messages", {})
  h.eq(1, #first.data.messages)
  local message = first.data.messages[1]
  h.eq("reply", message.kind)
  h.eq("Where does cwd come from?", message.text)
  h.eq({ tour_id, step_id, "The single funnel", "sample.lua", 3, 5 }, {
    message.tour_id, message.step_id, message.step_title, message.path, message.start_line, message.end_line,
  })

  h.eq("ok", call(session, "reply", { step_id = step_id, text = "Line 31 falls back to getcwd()." }).status)
  local again = call(session, "read_messages", { after = first.data.cursor })
  h.eq({}, again.data.messages, "the agent's own reply is not echoed back")

  session:reply(step_id, "Thanks")
  local later = call(session, "read_messages", { after = again.data.cursor })
  h.eq({ "Thanks" }, vim.tbl_map(function(m)
    return m.text
  end, later.data.messages))
  local thread = session:snapshot().tours[1].steps[1].messages
  h.eq({ "human", "agent", "human" }, vim.tbl_map(function(m)
    return m.author
  end, thread))
end

cases["agent replies count as unread until the human sees the step"] = function()
  local path, dir = h.file(h.numbered(20))
  local session = Session.new({ cwd = dir })
  local _, step_id = tour_with_step(session, path)
  call(session, "reply", { step_id = step_id, text = "one" })
  call(session, "reply", { step_id = step_id, text = "two" })
  h.eq(2, session:snapshot().tours[1].steps[1].unread)
  h.eq(2, session:unread_total())
  session:mark_seen(step_id)
  h.eq(0, session:unread_total())
end

cases["wait_for_human returns at once when messages are pending"] = function()
  local path, dir = h.file(h.numbered(20))
  local session = Session.new({ cwd = dir })
  local _, step_id = tour_with_step(session, path)
  session:reply(step_id, "already here")
  local result = call(session, "wait_for_human", { after = 0, timeout_s = 1 })
  h.eq({ "already here" }, vim.tbl_map(function(m)
    return m.text
  end, result.data.messages))
end

cases["an open wait receives the reply and suppresses the nudge"] = function()
  local path, dir = h.file(h.numbered(20))
  local session = Session.new({ cwd = dir })
  local _, step_id = tour_with_step(session, path)
  local events = {}
  session:subscribe(function(event)
    if event.type == "message" then
      events[#events + 1] = event
    end
  end)
  local result
  session:call("wait_for_human", { after = session:snapshot().seq, timeout_s = 5 }, {}, function(value)
    result = value
  end)
  h.eq(nil, result, "the wait stays open until the human writes")
  session:reply(step_id, "now")
  h.wait_for(function()
    return result ~= nil
  end, 1000)
  h.eq({ "now" }, vim.tbl_map(function(m)
    return m.text
  end, result.data.messages))
  h.eq(false, events[1].needs_nudge)

  session:reply(step_id, "nobody listening")
  h.eq(true, events[2].needs_nudge)
end

cases["wait_for_human times out empty and caps the timeout"] = function()
  local path, dir = h.file(h.numbered(20))
  local session = Session.new({ cwd = dir })
  tour_with_step(session, path)
  local started = vim.uv.hrtime()
  local result = call(session, "wait_for_human", { after = 0, timeout_s = 1 }, nil)
  h.eq({}, result.data.messages)
  h.ok((vim.uv.hrtime() - started) / 1e6 >= 900, "waited about a second")
  h.contains(call(session, "wait_for_human", { after = 0, timeout_s = 600 }).text, "`timeout_s` must be at most 50")
end

cases["close ends open waits"] = function()
  local session = Session.new({ cwd = vim.fn.getcwd() })
  local result
  session:call("wait_for_human", { after = 0, timeout_s = 5 }, {}, function(value)
    result = value
  end)
  session:close()
  h.eq("error", result.status)
  h.contains(result.text, "explain session ended")
end

cases["a human question becomes a step after the current one"] = function()
  local path, dir = h.file(h.numbered(20))
  local session = Session.new({ cwd = dir })
  local tour_id, step_id = tour_with_step(session, path)
  call(session, "add_step", { tour_id = tour_id, path = path, start_line = 9, end_line = 9, title = "later", note = "n" })
  local asked = session:ask({
    path = path, start_line = 12, end_line = 14, text = "Why is this async?\nIt blocks?", after_step_id = step_id,
  })
  local tour = session:snapshot().tours[1]
  h.eq({ "The single funnel", "Why is this async?", "later" }, vim.tbl_map(function(s)
    return s.title
  end, tour.steps))
  h.eq("human", tour.steps[2].origin)
  h.eq(asked.step_id, tour.steps[2].id)
  local message = call(session, "read_messages", {}).data.messages[1]
  h.eq({ "question", 12, 14, "Why is this async?\nIt blocks?" }, {
    message.kind, message.start_line, message.end_line, message.text,
  })
end

cases["a question with no tour opens a 'Your questions' tour"] = function()
  local path, dir = h.file(h.numbered(20))
  local session = Session.new({ cwd = dir })
  local asked = session:ask({ path = path, start_line = 1, end_line = 2, text = "What is this file?" })
  local tour = session:snapshot().tours[1]
  h.eq({ "Your questions", "human", asked.tour_id }, { tour.title, tour.origin, tour.id })
end

cases["update_step revises the note and range"] = function()
  local path, dir = h.file(h.numbered(20))
  local session = Session.new({ cwd = dir })
  local _, step_id = tour_with_step(session, path)
  local result = call(session, "update_step", { step_id = step_id, note = "Sharper note.", end_line = 7 })
  h.eq("ok", result.status, result.text)
  h.eq("line 7", result.data.last_line)
  local step = session:snapshot().tours[1].steps[1]
  h.eq({ "Sharper note.", 3, 7 }, { step.note, step.start_line, step.end_line })
  h.ok(step.note_edited_at, "an edited note is marked")
  h.contains(call(session, "update_step", { step_id = step_id, start_line = 9 }).text, "end_line 7 is before start_line 9")
end

cases["resolve toggles and get_tour reports state"] = function()
  local path, dir = h.file(h.numbered(20))
  local session = Session.new({ cwd = dir })
  local tour_id, step_id = tour_with_step(session, path)
  session:resolve(step_id)
  local listing = call(session, "get_tour", {})
  h.eq({ { tour_id = tour_id, title = "How a review opens", steps = 1 } }, listing.data.tours)
  local detail = call(session, "get_tour", { tour_id = tour_id }).data
  h.eq({ true, "sample.lua", "Every review walks through here." }, {
    detail.steps[1].resolved, detail.steps[1].path, detail.steps[1].note,
  })
  session:resolve(step_id)
  h.eq(false, session:snapshot().tours[1].steps[1].resolved)
end

cases["set_range records where the code moved"] = function()
  local path, dir = h.file(h.numbered(20))
  local session = Session.new({ cwd = dir })
  local _, step_id = tour_with_step(session, path)
  session:set_range(step_id, 6, 8)
  local step = session:snapshot().tours[1].steps[1]
  h.eq({ 6, 8 }, { step.start_line, step.end_line })
end

return cases
