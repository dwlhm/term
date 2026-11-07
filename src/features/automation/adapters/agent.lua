-- Agent TUIs that report their state with OSC 7501 (claude-code, opencode,
-- antigravity): the shared shape their adapters are made with.
--   agent.make{name, app, process}: an adapter whose serve steps paste the
--   request, ask the agent to answer with `term session answer`, and wait
--   for its turn to end; a permission prompt mid-turn is handed to a person.
local t = require "term"
local agent = {}

local function state(s) return s.status.state end

agent.state = {
  idle = function(s) local st = state(s) return st == "idle" or st == "done" end,
  working = function(s) return state(s) == "working" end,
  blocked = function(s) return state(s) == "blocked" end,
}

-- the turn has ended: idle again, or stopped on an error
local function turn_over(s) local st = state(s) return st == "idle" or st == "done" or st == "error" end

function agent.make(spec)
  local st = agent.state
  local steps = {}
  -- ask(text): one turn with text as the prompt
  steps.ask = function(text, opts)
    opts = opts or {}
    return {
      t.expect(st.idle),
      t.paste(text), t.press("Enter"),
      t.expect(function(s) return st.working(s) or st.blocked(s) end, { timeout = 30 }),
      t.retry({
        t.expect(function(s) return turn_over(s) or st.blocked(s) end, { timeout = opts.timeout or 1800 }),
        t.choose { { st.blocked, t.handoff { reason = spec.name .. " asks for a permission", ["until"] = function(s) return not st.blocked(s) end } },
                   default = {} },
      }, { times = 8, ["until"] = turn_over }),
    }
  end
  -- serve(text, req): the request's text plus how to answer it
  steps.serve = function(text, req)
    return steps.ask(text .. "\n\nWhen you are done, run this command with your shell tool (do not just write it) to send your answer back: term session answer "
      .. req.id .. " '<your answer>'")
  end
  return t.adapter {
    name = spec.name,
    detect = function(s) return s.status.app == spec.app or s.process == spec.process end,
    state = st,
    steps = steps,
    cancel = function() return { t.press("Escape"), t.expect(turn_over, { timeout = 10 }) } end,
  }
end

return agent
