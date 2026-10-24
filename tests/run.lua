vim.opt.runtimepath:prepend(vim.fn.getcwd())
package.path = "./lua/?.lua;./lua/?/init.lua;./?.lua;" .. package.path
-- Write to stdout directly: print() goes through Neovim's message grid, and
-- mixing that with redraw! in specs that inspect the screen crashes 0.12.
local function say(text)
  io.stdout:write(text, "\n")
  io.stdout:flush()
end
local root = vim.fn.getcwd()
-- One screen size for every spec, set before anything draws. Resizing the
-- headless grid later leaves stale rows and can crash Neovim 0.12.
vim.o.columns, vim.o.lines = 160, 40
-- Notifications would land in Neovim's message grid, where multi-line ones
-- scroll over rows that screen-reading specs then find blank. Record instead.
_G.notifications = {}
vim.notify = function(message)
  table.insert(_G.notifications, message)
end
local passed, failed = 0, 0
local filter = arg and arg[1]
local files = vim.fn.glob("tests/*_spec.lua", false, true)
table.sort(files)
for _, path in ipairs(files) do
  local wanted = not filter
  for part in (filter or ""):gmatch("[^,]+") do
    wanted = wanted or path:find(part, 1, true) ~= nil
  end
  if wanted then
    local loaded, cases = pcall(dofile, path)
    if not loaded then
      failed = failed + 1
      say("FAIL " .. path .. "\n" .. tostring(cases))
    else
      for _, name in ipairs(vim.tbl_keys(cases)) do
        local ok, err = xpcall(cases[name], debug.traceback)
        -- Specs may :cd into fixtures; later specs load by relative path.
        vim.cmd.cd(root)
        if ok then
          passed = passed + 1
          say("PASS " .. path .. " · " .. name)
        else
          failed = failed + 1
          say("FAIL " .. path .. " · " .. name .. "\n" .. err)
        end
      end
    end
  end
end
say(("\n%d passed, %d failed"):format(passed, failed))
vim.cmd(failed == 0 and "qa!" or "cquit 1")
