local M = {}

function M.eq(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    error(
      (message or "values differ")
        .. "\nexpected: "
        .. vim.inspect(expected)
        .. "\nactual: "
        .. vim.inspect(actual),
      2
    )
  end
end

function M.ok(value, message)
  if not value then
    error(message or "expected truthy value", 2)
  end
  return value
end

function M.contains(haystack, needle, message)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    error((message or "missing text") .. "\nwanted: " .. vim.inspect(needle) .. "\nin: " .. vim.inspect(haystack), 2)
  end
end

-- Runs a callback-style operation to completion on the main loop.
function M.await(start, timeout)
  local done, result = false, nil
  start(function(value)
    result, done = value, true
  end)
  assert(
    vim.wait(timeout or 5000, function()
      return done
    end, 5),
    "async operation timed out"
  )
  return result
end

function M.wait_for(predicate, timeout, message)
  assert(vim.wait(timeout or 5000, predicate, 5), message or "condition never became true")
end

-- Writes a throwaway file and returns its absolute path.
function M.file(lines, name)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = vim.fs.joinpath(dir, name or "sample.lua")
  vim.fn.writefile(lines, path)
  return vim.uv.fs_realpath(path), dir
end

-- Twenty numbered lines: "line 1" .. "line 20".
function M.numbered(count)
  local lines = {}
  for index = 1, count or 20 do
    lines[index] = "line " .. index
  end
  return lines
end

return M
