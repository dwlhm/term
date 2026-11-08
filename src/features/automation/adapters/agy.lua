-- Antigravity CLI, agy (reports OSC 7501 as app antigravity; it shows
-- "blocked" with kind auth for a few seconds while it signs in).
return require("term.adapter.agent").make { name = "agy", app = "antigravity", process = "agy" }
