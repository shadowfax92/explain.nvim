---Nudge wakes an agent whose turn has ended by typing one line into its herdr
---pane (`herdr pane run <pane> <text>` sends the text and Enter). Agents send
---their pane ID with every API call; the session remembers it. Bursts of human
---messages collapse into one nudge per pane, carrying the latest text, because
---the agent reads every message with read_messages anyway.
---
---The command runner is the seam: production spawns herdr, tests record argv.
local Nudge = {}
Nudge.__index = Nudge

---@param opts? { run?: fun(argv: string[]), delay_ms?: integer, herdr?: string }
function Nudge.new(opts)
  opts = opts or {}
  local self = setmetatable({
    herdr = opts.herdr or vim.env.HERDR_BIN_PATH or "herdr",
    delay_ms = opts.delay_ms or 1500,
    pending = {},
  }, Nudge)
  self.run = opts.run or function(argv)
    if not self:available() then
      return
    end
    vim.system(argv, { text = true }, function(out)
      if out.code ~= 0 then
        vim.schedule(function()
          vim.notify("[explain] herdr nudge failed: " .. vim.trim(out.stderr or ""), vim.log.levels.DEBUG)
        end)
      end
    end)
  end
  return self
end

function Nudge:available()
  return vim.fn.executable(self.herdr) == 1
end

---Queues a nudge for a pane; later calls within the quiet period replace the text.
function Nudge:send(pane, text)
  if not pane or pane == "" then
    return
  end
  local entry = self.pending[pane]
  if entry then
    entry.text = text
    return
  end
  entry = { text = text, timer = vim.uv.new_timer() }
  self.pending[pane] = entry
  entry.timer:start(
    self.delay_ms,
    0,
    vim.schedule_wrap(function()
      if self.pending[pane] ~= entry then
        return
      end
      self.pending[pane] = nil
      entry.timer:close()
      self.run({ self.herdr, "pane", "run", pane, entry.text })
    end)
  )
end

---Drops every queued nudge.
function Nudge:close()
  for pane, entry in pairs(self.pending) do
    entry.timer:stop()
    entry.timer:close()
    self.pending[pane] = nil
  end
end

return Nudge
