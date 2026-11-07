-- lazygit: numbered panels ("[2] Files - Worktrees - Submodules"); the
-- focused panel has a green border, the active tab of a panel a green title.
local t = require "term"

local GREEN = 2

local function panel(name) return { role = "panel", match = name } end

-- tabs: a panel title's " - " parts; the green one is the active tab
local function tabs(s, p, out)
  local line = s:line(p.row)
  local title = p.name:gsub("^%[%d+%]%s*", "")
  for part in string.gmatch(title, "[^-]+") do
    local name = part:match("^%s*(.-)%s*$")
    local at = string.find(line, name, 1, true) -- bytes: box characters are 3 each
    if at then
      local col = utf8.len(string.sub(line, 1, at - 1)) + 1
      local cell = s:cell(p.row, col)
      out[#out + 1] = { role = "tab", name = name, row = p.row, col = col, width = utf8.len(name), height = 1,
        parent = p.ref, selected = cell ~= nil and cell.fg == GREEN }
    end
  end
end

return t.adapter {
  name = "lazygit",
  detect = function(s)
    if s.process == "lazygit" then return true end
    return s.alt and string.find(s:line(1), "[1]", 1, true) ~= nil and string.find(s:line(1), "Status", 1, true) ~= nil
  end,
  elements = function(s, base)
    local out = {}
    for _, e in ipairs(base) do
      if e.role == "panel" or e.role == "dialog" then
        local corner = s:cell(e.row, e.col)
        e.focused = corner ~= nil and corner.fg == GREEN
        e.name = e.name:gsub("^%[%d+%]%s*", "")
        out[#out + 1] = e
        if e.role == "panel" and string.find(e.name, " - ", 1, true) then tabs(s, e, out) end
      else
        out[#out + 1] = e
      end
    end
    return out
  end,
  state = {
    files = panel("Files"),
    branches = panel("Local branches"),
    commits = panel("Commits"),
    commit_dialog = { role = "dialog", match = "Commit summary" },
  },
  interrupts = {
    { "Thanks for using lazygit!", t.press("Enter") }, -- the first-run welcome popup
  },
  steps = {
    stage_all = function() return { t.expect(panel("Files")), t.press("a") } end,
    commit = function(msg)
      return { t.press("c"), t.expect({ role = "dialog", match = "Commit summary" }), t.type(msg), t.press("Enter"), t.expect(msg) }
    end,
    quit = function() return t.press("q") end,
  },
}
