package platform_ipc_contract

// P7: every endpoint dir is validated (owned by us, not a symlink, no
// group/other bits, dir/name fits sun_path); nothing is bound, dialled,
// spawned or logged in an unsafe one. Another uid's dir cannot be made
// without root, so that case is not covered here.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import ipc "../"

// _unsafe_dirs makes one directory per way of being unsafe under base.
@(private = "file")
_unsafe_dirs :: proc(base: string) -> [4]string {
	world := fmt.tprintf("%s/w", base)
	group := fmt.tprintf("%s/g", base)
	safe := fmt.tprintf("%s/safe", base)
	link := fmt.tprintf("%s/l", base)
	for d in ([]string{world, group, safe}) do posix.mkdir(cstr(d), posix.S_IRWXU)
	posix.chmod(cstr(world), posix.S_IRWXU + posix.S_IRWXG + posix.S_IRWXO)
	posix.chmod(cstr(group), posix.S_IRWXU + {.IRGRP, .IXGRP})
	posix.symlink(cstr(safe), cstr(link))
	long := fmt.tprintf("%s/%s", base, strings.repeat("d", 100, context.temp_allocator))
	posix.mkdir(cstr(long), posix.S_IRWXU) // fine itself; dir/name is past sun_path
	return {world, group, link, long}
}

@(private = "file")
_empty :: proc(dir: string) -> bool {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	return err == nil && len(entries) == 0
}

@(test)
test_P7_unsafe_dirs_are_refused :: proc(t: ^testing.T) {
	base := test_dir()
	defer test_dir_remove(base)
	set: ipc.Poll_Set
	if !expect_ok(t, ipc.poll_set_init(&set, 8), "poll_set_init") do return
	defer ipc.poll_set_destroy(&set)
	dirs := _unsafe_dirs(base)
	for dir in dirs {
		at := ipc.Endpoint{dir, "s.sock"}
		s: ipc.Server
		expect_kind(t, ipc.server_open(&s, at, test_protocol(), &set), .Unsafe_Path, fmt.tprintf("server_open in %s", dir))
		ipc.server_close(&s)
		l: ipc.Link
		expect_kind(t, ipc.link_listen(&l, at, link_protocol(), &set), .Unsafe_Path, fmt.tprintf("link_listen in %s", dir))
		ipc.link_close(&l)
		expect_kind(t, ipc.link_dial(&l, at, link_protocol(), TEST_ROLE_CLIENT, &set), .Unsafe_Path, fmt.tprintf("link_dial in %s", dir))
		ipc.link_close(&l)
		c: ipc.Client
		opts := ipc.Client_Opts{role = TEST_ROLE_CLIENT, start = {"/usr/bin/touch", fmt.tprintf("%s/spawned", dir)}, log = fmt.tprintf("%s/x.log", dir)}
		expect_kind(t, ipc.client_open(&c, at, test_protocol(), opts), .Unsafe_Path, fmt.tprintf("client_open in %s", dir))
		ipc.client_close(&c)
		out: [64]u8
		_, err := ipc.line_call(at, "hi", out[:])
		expect_kind(t, err, .Unsafe_Path, fmt.tprintf("line_call in %s", dir))
	}
	posix.sleep(1) // a start that ran anyway would have touched "spawned" by now
	for d in dirs[:2] do testing.expectf(t, _empty(d), "something was created in %s", d)
	testing.expect(t, _empty(fmt.tprintf("%s/safe", base)), "something was created through the symlink")
	testing.expect(t, _empty(dirs[3]), "something was created in the long dir")
}

@(test)
test_P7_private_dir_is_made_0700_and_validated :: proc(t: ^testing.T) {
	base := test_dir()
	defer test_dir_remove(base)
	saved := os.get_env("TMPDIR", context.temp_allocator)
	defer os.set_env("TMPDIR", saved)
	os.set_env("TMPDIR", base)
	buf: [256]u8
	dir, err := ipc.private_dir(buf[:], "ipcc")
	if !expect_ok(t, err, "private_dir") do return
	testing.expect_value(t, dir, fmt.tprintf("%s/ipcc-%d", base, posix.getuid()))
	st: posix.stat_t
	testing.expect(t, posix.lstat(cstr(dir), &st) == .OK && posix.S_ISDIR(st.st_mode), "private_dir made no directory")
	testing.expect_value(t, st.st_mode & (posix.S_IRWXU + posix.S_IRWXG + posix.S_IRWXO), posix.S_IRWXU)
	posix.chmod(cstr(dir), posix.S_IRWXU + posix.S_IRWXG + posix.S_IRWXO)
	_, err = ipc.private_dir(buf[:], "ipcc")
	expect_kind(t, err, .Unsafe_Path, "private_dir on a 0777 dir")
}
