package feature_session_client

// Every binary that shows sessions is also its own holder and core: the tiers
// start each other as `<own executable> --holder|--core`, so a harness or the
// app dispatches them first thing in main.

import "core:fmt"
import "core:os"
import "core:sys/posix"
import holder_feat "../holder"
import core_feat "../session_core"
import ipc "../../platform/ipc"

// client_tier_main runs `--holder <socket>` or `--core` (no window, no SDL).
// handled = false for every other invocation.
client_tier_main :: proc(args: []string) -> (handled: bool, code: int) {
	if len(args) < 2 do return false, 0
	switch args[1] {
	case "--holder":
		if len(args) != 3 {
			fmt.eprintln("usage: --holder <socket>")
			return true, 2
		}
		return true, holder_feat.holder_run(args[2])
	case "--core":
		if len(args) != 2 {
			fmt.eprintln("usage: --core")
			return true, 2
		}
		return true, core_feat.core_run()
	}
	return false, 0
}

// client_use_private_session points this process (and the core and holder it
// starts) at a session dir of its own: a scripted run never touches the user's
// sessions, and its tiers end with it.
client_use_private_session :: proc() -> bool {
	buf, name_buf, path_buf: [256]u8
	dir, err := ipc.ipc_session_dir(buf[:])
	if err != .None do return false
	path, ok := ipc.ipc_session_path(path_buf[:], dir, fmt.bprintf(name_buf[:], "s%d", int(posix.getpid())))
	return ok && os.set_env(ipc.SESSION_DIR_ENV, path) == nil
}
