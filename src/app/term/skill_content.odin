package term

TERM_SKILL_NAME: string : "term"

TERM_SKILL_CONTENT: string : (
	"---\n" +
	"name: term\n" +
	"description: >-\n" +
	"  Drive sessions of the term terminal emulator with its `term " +
	"session` CLI.\n" +
	"  Use when the shell runs inside term or the user mentions " +
	"\"term session\":\n" +
	"  inspect sessions, run commands, send input, read screens, and " +
	"drive TUIs.\n" +
	"  This is NOT Luvus: never use the luvus CLI/skill for term " +
	"sessions.\n" +
	"---\n" +
	"\n" +
	"# term sessions\n" +
	"\n" +
	"Every shell in a term window or started with `term session new` " +
	"has an id;\n" +
	"programs get `TERM_SESSION_ID=<id>` (`term session whoami`).\n" +
	"\n" +
	"## Rules\n" +
	"- Interacting with a session uses two core verbs:\n" +
	"  - `send <id> …`: send text, keys, mouse events, or raw bytes " +
	"into PTY.\n" +
	"  - `read [id] …`: read text, command output (`--last`), or " +
	"follow (`--tail`).\n" +
	"- Follow execution without polling:\n" +
	"  - `read <id> --tail --prompt`: stream updates until prompt " +
	"returns.\n" +
	"  - `read <id> --tail --until \"<text>\"`: stream updates until " +
	"text appears.\n" +
	"  - `read <id> --tail --exit`: wait until process exits.\n" +
	"- Interrupt cleanly with `cancel <id>` (SIGINT and wait for " +
	"prompt).\n" +
	"- Exit codes: 0 ok · 1 error · 2 no core · 3 timeout · 4 early " +
	"exit.\n" +
	"\n" +
	"## Commands\n" +
	"| Goal | Command |\n" +
	"|---|---|\n" +
	"| Who am I · list | `term session whoami` · `ls [--output json]` |\n" +
	"| Start session | `new [-d dir] [-s CxR] [-e K=V]… [--name name] [-- prog args…]` |\n" +
	"| Window layout | `term split <right|down> [id]` · `term tab [id]` · `term show` |\n" +
	"| View in window | `attach <id>` |\n" +
	"| Resize session | `resize <id> <COLSxROWS>` |\n" +
	"| Send input | `send <id> [text] [--key K] [--click P] [--raw S]…` |\n" +
	"| Read screen | `read [id] [-n lines] [--last] [--clean] [--elements]` |\n" +
	"| Follow updates | `read [id] --tail [--until S] [--prompt] [--exit]` |\n" +
	"| Interrupt | `cancel <id> [-t sec]` |\n" +
	"| Send signal | `signal <id> <name|number>` |\n" +
	"| Terminate | `kill <id>` |\n" +
	"| Run Lua script | `term run <script.lua> [args…]` |\n" +
	"\n" +
	"## Recipes\n" +
	"```bash\n" +
	"# Run command in background session and wait for prompt:\n" +
	"SH=$(term session new --name worker -d ~/project)\n" +
	"term session send \"$SH\" \"make test\" --key Enter\n" +
	"term session read \"$SH\" --tail --prompt\n" +
	"term session read \"$SH\" --last\n" +
	"\n" +
	"# Split pane and view in running window:\n" +
	"term split right \"$SH\"\n" +
	"\n" +
	"# Programmable Lua Script (Effect-style Fibers):\n" +
	"# Run with: term run flow.lua\n" +
	"# local term = require \"term\"\n" +
	"# return term.program(function()\n" +
	"#   local s = term.session.spawn { command = \"make watch\" }\n" +
	"#   s:wait { text = \"Ready\" }\n" +
	"#   term.window.split { direction = \"right\", session = s }\n" +
	"# end)\n" +
	"```\n" +
	"\n" +
	"## Driving TUIs: term auto\n" +
	"For full-screen programs (lazygit, vim, fzf), `term auto` drives contracts:\n" +
	"```bash\n" +
	"term auto snapshot <id>\n" +
	"term auto adapters\n" +
	"term auto check flow.lua && term auto run --session <id> flow.lua save\n" +
	"```\n" +
	""
)
