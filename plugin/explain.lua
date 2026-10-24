if vim.g.loaded_explain then
  return
end
vim.g.loaded_explain = true

vim.api.nvim_create_user_command("Explain", function(opts)
  local ok, err = pcall(require("explain").command, opts.fargs)
  if not ok then
    vim.notify(tostring(err), vim.log.levels.ERROR, { title = "explain" })
  end
end, {
  nargs = "?",
  desc = "explain: agent-guided code tours",
  complete = function(arglead)
    return vim.tbl_filter(function(name)
      return name:sub(1, #arglead) == arglead
    end, require("explain").subcommands)
  end,
})
