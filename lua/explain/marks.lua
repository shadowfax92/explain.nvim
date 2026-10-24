---Marks draws tour steps inside real code buffers: a highlighter band with a
---sign bar on every line of each step, and an end-of-line label on its first
---line. One range extmark per step carries the band; Neovim applies its line
---highlight to every line through end_row and moves it with edits, so it
---doubles as the step's live anchor. Signs are one extmark per line instead,
---because statuscolumn plugins (snacks, statuscol) only find signs on the line
---a mark starts on. Signs and labels are disposable: they are redrawn from the
---anchors on every render and whenever an annotated buffer changes.
---
---Steps whose files are not loaded wait until the buffer appears; when a
---buffer unloads, the anchor's final range is reported back so the session can
---re-place it later at the right lines.
local highlight = require("explain.highlight")

local Marks = {}
Marks.__index = Marks

local BAND_NS = vim.api.nvim_create_namespace("explain.band")
local LABEL_NS = vim.api.nvim_create_namespace("explain.label")
local SIGN_NS = vim.api.nvim_create_namespace("explain.sign")
local instances = 0

---@param opts? { on_unload?: fun(step_id: integer, first: integer, last: integer) }
function Marks.new(opts)
  highlight.setup()
  instances = instances + 1
  local self = setmetatable({
    on_unload = (opts or {}).on_unload,
    anchors = {}, -- step_id -> { buf, id }
    attached = {}, -- buf -> true while we redraw signs on its edits
    group = vim.api.nvim_create_augroup("explain.marks." .. instances, { clear = true }),
  }, Marks)
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
    group = self.group,
    callback = function(args)
      if self.last and self:_has_steps(vim.api.nvim_buf_get_name(args.buf)) then
        vim.schedule(function()
          if self.last then
            self:render(self.last.snapshot, self.last.current)
          end
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufUnload", {
    group = self.group,
    callback = function(args)
      self:_forget_buffer(args.buf)
    end,
  })
  return self
end

function Marks:_has_steps(path)
  for _, tour in ipairs(self.last.snapshot.tours) do
    for _, step in ipairs(tour.steps) do
      if step.path == path then
        return true
      end
    end
  end
  return false
end

local function loaded_buffers()
  local by_path = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then
        by_path[name] = buf
      end
    end
  end
  return by_path
end

local function first_sentence(text, limit)
  local sentence = vim.trim((text or ""):gsub("%s+", " "))
  sentence = sentence:match("^(.-[%.%?!])%s") or sentence
  if vim.fn.strchars(sentence) > limit then
    sentence = vim.fn.strcharpart(sentence, 0, limit - 1) .. "…"
  end
  return sentence
end

-- Chooses band, sign and label for a step given whether it is current.
local function decoration(step, position, tour, current)
  local human = step.origin == "human"
  local style = {
    band = human and "ExplainBandHumanDim" or "ExplainBandDim",
    sign = human and "ExplainSignHumanDim" or "ExplainSignDim",
  }
  local glyph = step.resolved and "✓" or (human and "●" or "◆")
  local label = { { ("  %s %d  %s"):format(glyph, position, step.title), human and "ExplainLabelHuman" or "ExplainLabelDim" } }
  if current then
    style.band = human and "ExplainBandHuman" or "ExplainBand"
    style.sign = human and "ExplainSignHuman" or "ExplainSign"
    local who = human and "you" or (tour.agent or "agent")
    local summary = human and step.title or first_sentence(step.note, 60)
    label = { { ("  %s %s: %s"):format(glyph, who, summary), human and "ExplainLabelHuman" or "ExplainLabel" } }
  end
  if step.unread > 0 then
    label[#label + 1] = { " " }
    label[#label + 1] = { (" %d new "):format(step.unread), "ExplainBadge" }
  end
  style.label = label
  return style
end

-- Returns the anchor's extmark position, or nil when it vanished.
function Marks:_anchor_position(step_id)
  local anchor = self.anchors[step_id]
  if not anchor or not vim.api.nvim_buf_is_valid(anchor.buf) then
    return nil
  end
  local mark = vim.api.nvim_buf_get_extmark_by_id(anchor.buf, BAND_NS, anchor.id, { details = true })
  if not mark[1] then
    return nil
  end
  return anchor.buf, mark[1], mark[3].end_row or mark[1]
end

---Draws every step of every tour into the buffers that are loaded. Idempotent;
---call it after any change. `current` is the step the human is on.
function Marks:render(snapshot, current)
  self.last = { snapshot = snapshot, current = current }
  local buffers = loaded_buffers()
  local live = {}
  for buf in pairs(vim.iter(buffers):fold({}, function(acc, _, b)
    acc[b] = true
    return acc
  end)) do
    vim.api.nvim_buf_clear_namespace(buf, LABEL_NS, 0, -1)
    vim.api.nvim_buf_clear_namespace(buf, SIGN_NS, 0, -1)
  end
  for _, tour in ipairs(snapshot.tours) do
    for position, step in ipairs(tour.steps) do
      local buf = buffers[step.path]
      if buf then
        live[step.id] = true
        self:_draw(buf, step, position, tour, step.id == current)
      end
    end
  end
  for step_id, anchor in pairs(self.anchors) do
    if not live[step_id] then
      pcall(vim.api.nvim_buf_del_extmark, anchor.buf, BAND_NS, anchor.id)
      self.anchors[step_id] = nil
    end
  end
end

function Marks:_draw(buf, step, position, tour, current)
  local style = decoration(step, position, tour, current)
  local anchor_buf, row, end_row = self:_anchor_position(step.id)
  if anchor_buf ~= buf then
    local count = vim.api.nvim_buf_line_count(buf)
    row = math.min(step.start_line, count) - 1
    end_row = math.min(step.end_line, count) - 1
    self.anchors[step.id] = nil
  end
  -- The end sits at the end of the last line's text and moves right with
  -- insertions there: a line inserted above the last line pushes the end
  -- down with it instead of squeezing the last line out of the range.
  local last_line = vim.api.nvim_buf_get_lines(buf, end_row, end_row + 1, false)[1] or ""
  local id = vim.api.nvim_buf_set_extmark(buf, BAND_NS, row, 0, {
    id = self.anchors[step.id] and self.anchors[step.id].id or nil,
    end_row = end_row,
    end_col = #last_line,
    end_right_gravity = true,
    line_hl_group = style.band,
    -- Below the signs: statuscolumn plugins treat line highlights as signs
    -- and show only the highest-priority one per line.
    priority = current and 11 or 10,
    invalidate = true,
    undo_restore = true,
  })
  self.anchors[step.id] = { buf = buf, id = id }
  local _, first, last = self:_anchor_position(step.id)
  for line = first, last do
    vim.api.nvim_buf_set_extmark(buf, SIGN_NS, line, 0, {
      sign_text = "▌",
      sign_hl_group = style.sign,
      priority = current and 60 or 50,
    })
  end
  self:_attach(buf)
  vim.api.nvim_buf_set_extmark(buf, LABEL_NS, row, 0, {
    virt_text = style.label,
    virt_text_pos = "eol",
    hl_mode = "combine",
    priority = current and 60 or 50,
  })
end

-- Redraws signs and labels after edits so lines added inside a range get a
-- sign. on_lines runs under textlock, so the redraw is deferred.
function Marks:_attach(buf)
  if self.attached[buf] then
    return
  end
  self.attached[buf] = true
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if not self.attached[buf] then
        return true -- detach after clear()
      end
      if not self.refresh_pending then
        self.refresh_pending = true
        vim.schedule(function()
          self.refresh_pending = false
          if self.last then
            self:render(self.last.snapshot, self.last.current)
          end
        end)
      end
    end,
    on_detach = function()
      self.attached[buf] = nil
    end,
  })
end

---The step's current lines (1-based, inclusive), following the human's edits.
---Nil when the step's file is not loaded.
function Marks:live_range(step_id)
  local _, row, end_row = self:_anchor_position(step_id)
  if not row then
    return nil
  end
  return row + 1, end_row + 1
end

function Marks:_forget_buffer(buf)
  for step_id, anchor in pairs(self.anchors) do
    if anchor.buf == buf then
      local first, last = self:live_range(step_id)
      if first and self.on_unload then
        self.on_unload(step_id, first, last)
      end
      self.anchors[step_id] = nil
    end
  end
end

---Removes every decoration and stops tracking buffers.
function Marks:clear()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, BAND_NS, 0, -1)
      vim.api.nvim_buf_clear_namespace(buf, LABEL_NS, 0, -1)
      vim.api.nvim_buf_clear_namespace(buf, SIGN_NS, 0, -1)
    end
  end
  self.anchors, self.last, self.attached = {}, nil, {}
  pcall(vim.api.nvim_del_augroup_by_id, self.group)
end

return Marks
