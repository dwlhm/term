-- The pure part of the `term` module: step builders and target matching.
-- Steps are plain tables ({op = ...}); the runner carries them out. Nothing
-- here touches a session.
local t = ...

local function step(op, fields)
  fields = fields or {}
  fields.op = op
  return fields
end

local function target_ok(target, what)
  local kind = type(target)
  if kind ~= "string" and kind ~= "table" and kind ~= "function" then
    error(what .. " takes a locator table, a text, a ref or a predicate function", 3)
  end
end

function t.press(...)
  local keys = { ... }
  if #keys == 0 then error("press needs a key: t.press(\"Enter\")", 2) end
  for _, k in ipairs(keys) do
    if type(k) ~= "string" then error("keys are names like \"Enter\", \"Ctrl+C\" or \"a\"", 2) end
  end
  return step("press", { keys = keys })
end

function t.type(text)
  if type(text) ~= "string" then error("type takes text", 2) end
  return step("type", { text = text })
end

function t.paste(text)
  if type(text) ~= "string" then error("paste takes text", 2) end
  return step("paste", { text = text })
end

function t.click(target, opts)
  target_ok(target, "click")
  return step("click", { target = target, button = opts and opts.button or "left" })
end

function t.scroll(target, notches)
  target_ok(target, "scroll")
  return step("scroll", { target = target, n = notches or 1 })
end

function t.expect(target, opts)
  target_ok(target, "expect")
  return step("expect", { target = target, timeout = opts and opts.timeout })
end

function t.gone(target, opts)
  target_ok(target, "gone")
  return step("gone", { target = target, timeout = opts and opts.timeout })
end

function t.read(target, k)
  target_ok(target, "read")
  if type(k) ~= "function" then error("read takes a target and a function value -> steps", 2) end
  return step("read", { target = target, k = k })
end

-- choose{ {when, steps}, …, default = steps }: the first case whose target
-- is on screen runs (waiting for one to appear); default when none does.
function t.choose(cases)
  if type(cases) ~= "table" or #cases == 0 then error("choose takes { {target, steps}, … }", 2) end
  for _, c in ipairs(cases) do target_ok(c[1], "choose") end
  return step("choose", { cases = cases, default = cases.default })
end

function t.retry(steps, opts)
  opts = opts or {}
  return step("retry", { steps = steps, times = opts.times or 3, ["until"] = opts["until"] })
end

function t.call(name, ...)
  if type(name) ~= "string" then error("call takes a function name of the contract", 2) end
  return step("call", { name = name, args = table.pack(...) })
end

function t.ask(spec, k)
  if type(spec) == "string" then spec = { prompt = spec } end
  if type(spec) ~= "table" or type(spec.prompt) ~= "string" then error("ask takes { prompt = …, type = …, choices = … }", 2) end
  if type(k) ~= "function" then error("ask takes a function answer -> steps", 2) end
  return step("ask", { spec = spec, k = k })
end

function t.handoff(opts)
  if type(opts) ~= "table" or type(opts.reason) ~= "string" then error("handoff takes { reason = …, until = target }", 2) end
  return step("handoff", { reason = opts.reason, ["until"] = opts["until"] })
end

function t.done(value) return step("done", { value = value }) end

function t.fail(msg) return step("fail", { msg = tostring(msg) }) end

-- Matching -----------------------------------------------------------------

local function len(s) return utf8.len(s) or #s end

-- text on screen: an element-like table for the first line containing it
local function find_text(screen, text)
  for row, line in ipairs(screen:lines()) do
    local at = string.find(line, text, 1, true)
    if at then
      local col = len(string.sub(line, 1, at - 1)) + 1
      return { role = "text", name = text, text = text, row = row, col = col, width = len(text), height = 1 }
    end
  end
end

local FIELDS = { role = true, name = true, text = true, match = true, selected = true, focused = true,
  checked = true, source = true, inside = true, nth = true }

local function fits(e, loc, by_ref, screen)
  for k, v in pairs(loc) do
    if not FIELDS[k] then error("locator field '" .. tostring(k) .. "' is unknown", 0) end
    if k == "match" then
      if not (string.find(e.name, v) or string.find(e.text, v)) then return false end
    elseif k == "inside" then
      local p, found = e.parent, false
      local outer = t.match(screen, v)
      while p and not found do
        found = type(outer) == "table" and outer.ref == p
        p = by_ref[p] and by_ref[p].parent
      end
      if not found then return false end
    elseif k ~= "nth" and e[k] ~= v then
      return false
    end
  end
  return true
end

-- t.match(screen, target): the element (a table), true (a predicate that
-- held) or nil.
function t.match(screen, target)
  local kind = type(target)
  if kind == "function" then
    local r = target(screen)
    if r == nil or r == false then return nil end
    return r
  end
  local es = screen:elements()
  if kind == "string" then
    local n = string.match(target, "^@e(%d+)$")
    if n then return es[tonumber(n)] end
    return find_text(screen, target)
  end
  local by_ref = {}
  for _, e in ipairs(es) do by_ref[e.ref] = e end
  local want, seen = target.nth or 1, 0
  for _, e in ipairs(es) do
    if fits(e, target, by_ref, screen) then
      seen = seen + 1
      if seen == want then return e end
    end
  end
end

-- The fields each step must have, by type: the runner reads them as such.
local SHAPES = {
  press = { keys = "table" }, type = { text = "string" }, paste = { text = "string" },
  click = { button = "string" }, scroll = { n = "number" }, expect = {}, gone = {},
  read = { k = "function" }, choose = { cases = "table" }, retry = { steps = "table", times = "number" },
  call = { name = "string", args = "table" }, ask = { spec = "table", k = "function" },
  handoff = { reason = "string" }, done = {}, fail = { msg = "string" },
}
local TARGETS = { click = true, scroll = true, expect = true, gone = true, read = true }

local function check_step(s)
  local shape = SHAPES[s.op]
  if not shape then error("unknown step '" .. tostring(s.op) .. "' (steps are made with t.press, t.expect, …)", 0) end
  for field, kind in pairs(shape) do
    if type(s[field]) ~= kind then error(s.op .. " step: " .. field .. " must be a " .. kind, 0) end
  end
  if TARGETS[s.op] then
    local kind = type(s.target)
    if kind ~= "string" and kind ~= "table" and kind ~= "function" then error(s.op .. " step: bad target", 0) end
  end
  if s.op == "press" then
    for _, k in ipairs(s.keys) do if type(k) ~= "string" then error("press step: keys must be names", 0) end end
  elseif s.op == "choose" then
    for _, c in ipairs(s.cases) do if type(c) ~= "table" or c[1] == nil then error("choose step: cases are {target, steps}", 0) end end
  elseif s.op == "ask" and type(s.spec.prompt) ~= "string" then
    error("ask step: spec.prompt must be text", 0)
  end
end

-- t.flatten(steps): a step, or nested lists of steps, as one list of checked
-- steps.
function t.flatten(steps, out)
  out = out or {}
  if type(steps) ~= "table" then
    error("a function must return steps (t.press, t.expect, …), not " .. type(steps), 0)
  end
  if steps.op then
    check_step(steps)
    out[#out + 1] = steps
  else
    for _, s in ipairs(steps) do t.flatten(s, out) end
  end
  return out
end

return t
