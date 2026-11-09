package feature_session_proto_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import ipc "../../../platform/ipc"
import proto "../"

@(private = "file")
dir_counter: int

@(private = "file")
Env_Snapshot :: struct {
	value: string,
	found: bool,
}

@(private = "file")
env_save :: proc(key: string) -> Env_Snapshot {
	value, found := os.lookup_env(key, context.temp_allocator)
	return Env_Snapshot{value = value, found = found}
}

@(private = "file")
env_restore :: proc(key: string, snap: Env_Snapshot) {
	if snap.found {
		os.set_env(key, snap.value)
	} else {
		os.unset_env(key)
	}
}

@(private = "file")
perms_0700 :: proc() -> os.Permissions {
	return os.Permissions{.Read_User, .Write_User, .Execute_User}
}

// unique_dir creates a fresh private dir under the real $TMPDIR.
@(private = "file")
unique_dir :: proc(t: ^testing.T) -> string {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if len(tmp) == 0 {
		tmp = "/tmp"
	}
	cnt := sync.atomic_add(&dir_counter, 1)
	path := fmt.tprintf("%s/ipct-%d-%d", tmp, int(posix.getpid()), cnt)
	if err := os.make_directory(path, perms_0700()); err != os.ERROR_NONE {
		testing.fail_now(t, "cannot create test dir")
	}
	return path
}

@(private = "file")
group_other :: proc() -> posix.mode_t {
	return posix.mode_t{.IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH}
}

@(private = "file")
owner_rwx :: proc() -> posix.mode_t {
	return posix.mode_t{.IRUSR, .IWUSR, .IXUSR}
}

@(private = "file")
lstat_path :: proc(t: ^testing.T, path: string) -> posix.stat_t {
	st: posix.stat_t
	c := strings.clone_to_cstring(path, context.temp_allocator)
	testing.expect_value(t, posix.lstat(c, &st), posix.result.OK)
	return st
}

@(private = "file")
chmod_path :: proc(t: ^testing.T, path: string, mode: posix.mode_t) {
	c := strings.clone_to_cstring(path, context.temp_allocator)
	testing.expect_value(t, posix.chmod(c, mode), posix.result.OK)
}

@test
test_default_path_creates_private_dir :: proc(t: ^testing.T) {
	tmp_snap := env_save("TMPDIR")
	defer env_restore("TMPDIR", tmp_snap)
	sock_snap := env_save(proto.CTL_SOCK_ENV)
	defer env_restore(proto.CTL_SOCK_ENV, sock_snap)

	base := unique_dir(t)
	defer os.remove_all(base)
	os.unset_env(proto.CTL_SOCK_ENV)
	os.set_env("TMPDIR", base)

	buf: [512]u8
	path, err := proto.ctl_socket_path(buf[:])
	testing.expect_value(t, err.kind, ipc.Error_Kind.None)
	if err.kind != .None {
		return
	}
	suffix := fmt.tprintf("/term-%d/ctl.sock", int(posix.getuid()))
	testing.expect(t, strings.has_suffix(path, suffix), "path must end with the per-uid dir")

	dir := path[:len(path) - len("/ctl.sock")]
	st := lstat_path(t, dir)
	testing.expect(t, posix.S_ISDIR(st.st_mode), "socket dir must be a directory")
	testing.expect(t, card(st.st_mode & group_other()) == 0, "socket dir must be 0700")
	testing.expect(t, card(st.st_mode & owner_rwx()) == card(owner_rwx()), "owner must have rwx")
}

@test
test_default_path_rejects_open_dir :: proc(t: ^testing.T) {
	tmp_snap := env_save("TMPDIR")
	defer env_restore("TMPDIR", tmp_snap)
	sock_snap := env_save(proto.CTL_SOCK_ENV)
	defer env_restore(proto.CTL_SOCK_ENV, sock_snap)

	base := unique_dir(t)
	defer os.remove_all(base)
	os.unset_env(proto.CTL_SOCK_ENV)
	os.set_env("TMPDIR", base)

	dir := fmt.tprintf("%s/term-%d", base, int(posix.getuid()))
	testing.expect(t, os.make_directory(dir, perms_0700()) == os.ERROR_NONE, "precreate dir")
	chmod_path(t, dir, posix.mode_t{.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH})

	buf: [512]u8
	path, err := proto.ctl_socket_path(buf[:])
	testing.expect_value(t, err.kind, ipc.Error_Kind.Unsafe_Path)
	testing.expect_value(t, path, "")
}

@test
test_default_path_rejects_symlink :: proc(t: ^testing.T) {
	tmp_snap := env_save("TMPDIR")
	defer env_restore("TMPDIR", tmp_snap)
	sock_snap := env_save(proto.CTL_SOCK_ENV)
	defer env_restore(proto.CTL_SOCK_ENV, sock_snap)

	base := unique_dir(t)
	defer os.remove_all(base)
	os.unset_env(proto.CTL_SOCK_ENV)
	os.set_env("TMPDIR", base)

	target := fmt.tprintf("%s/target-%d", base, int(posix.getuid()))
	testing.expect(t, os.make_directory(target, perms_0700()) == os.ERROR_NONE, "target dir")
	link := fmt.tprintf("%s/term-%d", base, int(posix.getuid()))
	testing.expect(t, os.symlink(target, link) == os.ERROR_NONE, "symlink")

	buf: [512]u8
	_, err := proto.ctl_socket_path(buf[:])
	testing.expect_value(t, err.kind, ipc.Error_Kind.Unsafe_Path)
}

@test
test_env_override_and_too_long :: proc(t: ^testing.T) {
	sock_snap := env_save(proto.CTL_SOCK_ENV)
	defer env_restore(proto.CTL_SOCK_ENV, sock_snap)

	buf: [512]u8
	os.set_env(proto.CTL_SOCK_ENV, "/x/y.sock")
	path, err := proto.ctl_socket_path(buf[:])
	testing.expect_value(t, err.kind, ipc.Error_Kind.None)
	testing.expect_value(t, path, "/x/y.sock")

	long: [200]u8
	for i in 0 ..< len(long) {
		long[i] = 'a'
	}
	os.set_env(proto.CTL_SOCK_ENV, string(long[:]))
	path, err = proto.ctl_socket_path(buf[:])
	testing.expect_value(t, err.kind, ipc.Error_Kind.Unsafe_Path) // too long for sun_path
	testing.expect_value(t, path, "")
	os.unset_env(proto.CTL_SOCK_ENV)
}
