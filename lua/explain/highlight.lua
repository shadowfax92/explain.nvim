---Highlight groups shared by the code decorations and the panel. Colours come
---from the design mockups (gruvbox: amber highlighter for the agent, slate blue
---for the human). Every group is defined with `default = true`, so a
---colorscheme or the user's config can override any of them; they are redefined
---on ColorScheme because `:hi clear` wipes them.
local M = {}

local PALETTES = {
  dark = {
    band = "#3f3714",
    band_dim = "#2f2b1c",
    band_human = "#243234",
    band_human_dim = "#1f2a2b",
    agent = "#fabd2f",
    agent_dim = "#8a7224",
    human = "#83a598",
    human_dim = "#56706a",
    label = "#c9a43a",
    text = "#ebdbb2",
    muted = "#928374",
    on_badge = "#282828",
    resolved = "#8ec07c",
    link = "#8ec07c",
    surface = "#1d2021",
  },
  light = {
    band = "#fbefb4",
    band_dim = "#f8f3dc",
    band_human = "#dbe9ec",
    band_human_dim = "#ebf2f3",
    agent = "#b57614",
    agent_dim = "#c9a96a",
    human = "#076678",
    human_dim = "#6f9aa3",
    label = "#9a6512",
    text = "#3c3836",
    muted = "#7c6f64",
    on_badge = "#fbf1c7",
    resolved = "#427b58",
    link = "#427b58",
    surface = "#f2e5bc",
  },
}

function M.define()
  local c = PALETTES[vim.o.background == "light" and "light" or "dark"]
  local groups = {
    ExplainBand = { bg = c.band },
    ExplainBandDim = { bg = c.band_dim },
    ExplainBandHuman = { bg = c.band_human },
    ExplainBandHumanDim = { bg = c.band_human_dim },
    ExplainSign = { fg = c.agent, bg = c.band },
    ExplainSignDim = { fg = c.agent_dim },
    ExplainSignHuman = { fg = c.human, bg = c.band_human },
    ExplainSignHumanDim = { fg = c.human_dim },
    ExplainLabel = { fg = c.label, italic = true },
    ExplainLabelDim = { fg = c.agent_dim, italic = true },
    ExplainLabelHuman = { fg = c.human, italic = true },
    ExplainBadge = { fg = c.on_badge, bg = c.human, bold = true },
    ExplainTitle = { fg = c.text, bold = true },
    ExplainMuted = { fg = c.muted },
    ExplainAgent = { fg = c.agent, bold = true },
    ExplainHuman = { fg = c.human, bold = true },
    ExplainAgentBar = { fg = c.agent },
    ExplainHumanBar = { fg = c.human },
    ExplainCurrent = { bg = c.band },
    ExplainCurrentNumber = { fg = c.agent, bold = true },
    ExplainResolved = { fg = c.resolved },
    ExplainLink = { fg = c.link, underline = true },
    ExplainSurface = { bg = c.surface },
  }
  for name, spec in pairs(groups) do
    spec.default = true
    vim.api.nvim_set_hl(0, name, spec)
  end
end

local defined = false

---Defines the groups once and keeps them alive across colorscheme changes.
function M.setup()
  if defined then
    return
  end
  defined = true
  M.define()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("explain.highlight", { clear = true }),
    callback = M.define,
  })
end

return M
