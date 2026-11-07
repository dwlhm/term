-- fzf: items sit above the info line ("12/200 ───"), one per row behind a
-- "▌" gutter; the current item's gutter is coloured and bold. The query is
-- typed at the prompt below.
local t = require "term"

local function info_row(s)
  for row, line in ipairs(s:lines()) do
    if string.match(line, "^%s*%d+/%d+") then return row end
  end
end

return t.adapter {
  name = "fzf",
  detect = function(s) return s.process == "fzf" or info_row(s) ~= nil end,
  elements = function(s, base)
    local out = {}
    for _, e in ipairs(base) do
      if e.role ~= "listitem" then out[#out + 1] = e end
    end
    local info = info_row(s)
    if not info then return out end
    for row = 1, info - 1 do
      local line = s:line(row)
      local rest = line:match("^▌ (.*)$") or line:match("^> (.*)$") or line:match("^  (.*)$")
      local name = rest and rest:gsub("%s*│%s*$", ""):match("^(.-)%s*$")
      if name and name ~= "" then
        local gutter = s:cell(row, 1)
        out[#out + 1] = { role = "listitem", name = name, row = row, col = 3, width = utf8.len(name), height = 1,
          selected = gutter ~= nil and gutter.bold }
      end
    end
    local count = string.match(s:line(info), "(%d+/%d+)")
    out[#out + 1] = { role = "statusbar", name = count, row = info, col = 1, width = s.cols, height = 1 }
    return out
  end,
  state = {
    ready = function(s) return info_row(s) ~= nil end,
    -- has(n): exactly n items match the query
    has = function(n) return function(s)
      local row = info_row(s)
      return row and string.match(s:line(row), "^%s*(%d+)/") == tostring(n)
    end end,
  },
  steps = {
    query = function(text) return t.type(text) end,
    pick = function(text) return { t.type(text), t.expect({ role = "listitem", selected = true }), t.press("Enter") } end,
  },
}
