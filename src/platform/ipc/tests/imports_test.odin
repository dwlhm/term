package platform_ipc_tests

// P38: the IPC package depends on base: and core: only, and so does its echo
// example (plus the package itself, "../"). Linking a system library with
// `foreign import "system:…"` is the OS, not a package, and is allowed.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
_bad_imports :: proc(dir: string, allowed_extra: string) -> (bad: [dynamic]string) {
	bad.allocator = context.temp_allocator
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		append(&bad, fmt.tprintf("%s: cannot read (%v)", dir, err))
		return
	}
	for e in entries {
		if !strings.has_suffix(e.name, ".odin") do continue
		data, read_err := os.read_entire_file_from_path(e.fullpath, context.temp_allocator)
		if read_err != nil do continue
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			l := strings.trim_space(line)
			open, close := strings.index_byte(l, '"'), strings.last_index_byte(l, '"')
			if !strings.has_prefix(l, "import ") || open < 0 || close <= open do continue
			path := l[open + 1:close]
			if strings.has_prefix(path, "base:") || strings.has_prefix(path, "core:") || path == allowed_extra do continue
			append(&bad, fmt.tprintf("%s: %s", e.name, l))
		}
	}
	return
}

@(test)
test_P38_package_and_example_import_only_base_and_core :: proc(t: ^testing.T) {
	for bad in _bad_imports(#directory + "/..", "") do testing.expectf(t, false, "platform/ipc imports %s", bad)
	for bad in _bad_imports(#directory + "/../example", "../") do testing.expectf(t, false, "the example imports %s", bad)
}
