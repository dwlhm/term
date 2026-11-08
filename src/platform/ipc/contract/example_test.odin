package platform_ipc_contract

// P37: the echo example (src/platform/ipc/example) runs and exits 0. Its
// imports (base:, core: and the package only) are checked by P38 in
// src/platform/ipc/tests. `make test-ipc-contract` builds it first and passes
// its path as IPC_EXAMPLE.

import "core:c"
import "core:sys/posix"
import "core:testing"
import "core:time"

IPC_EXAMPLE :: #config(IPC_EXAMPLE, "")

@(test)
test_P37_echo_example_runs :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 20 * time.Second)
	if !testing.expect(t, IPC_EXAMPLE != "", "built without -define:IPC_EXAMPLE=<path> (use make test-ipc-contract)") do return
	argv := [?]cstring{IPC_EXAMPLE, nil}
	pid: posix.pid_t
	if !testing.expect(t, posix.posix_spawn(&pid, IPC_EXAMPLE, nil, nil, raw_data(argv[:]), posix.environ) == .NONE, "cannot run the example") do return
	status: c.int
	for _ in 0 ..< 1000 {
		if posix.waitpid(pid, &status, {.NOHANG}) == pid {
			testing.expectf(t, posix.WIFEXITED(status) && posix.WEXITSTATUS(status) == 0, "the example failed (status %x)", status)
			return
		}
		time.sleep(10 * time.Millisecond)
	}
	child_reap(pid)
	testing.expect(t, false, "the example did not exit within 10 s")
}
