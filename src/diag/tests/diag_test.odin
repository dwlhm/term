package diag_test

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import diag "../"

@(test)
test_diag_lifecycle_and_levels :: proc(t: ^testing.T) {
	cfg := diag.Diag_Config{
		app_version   = "0.3.0-test",
		log_to_stderr = false,
		log_to_file   = false,
		min_level     = .Warn,
	}

	ok := diag.diag_init(cfg)
	testing.expect(t, ok, "diag_init should succeed")

	diag.diag_debug("Debug message %d", 1)
	diag.diag_info("Info message %s", "test")
	diag.diag_warn("Warn message %f", 3.14)
	diag.diag_error("Error message %v", true)
	diag.diag_flush()

	diag.diag_destroy()
}

@(test)
test_diag_file_sink :: proc(t: ^testing.T) {
	test_dir := "/tmp/term_diag_unit_test"
	_ = os.remove_all(test_dir)
	defer {
		_ = os.remove_all(test_dir)
	}

	cfg := diag.Diag_Config{
		app_version   = "0.3.0-test",
		log_to_stderr = false,
		log_to_file   = true,
		log_dir       = test_dir,
		min_level     = .Debug,
	}

	ok := diag.diag_init(cfg)
	testing.expect(t, ok, "diag_init with file sink should succeed")

	diag.diag_debug("Debug probe: value=%d", 42)
	diag.diag_info("Info probe: system=%s", "ready")
	diag.diag_flush()
	diag.diag_destroy()

	fd, err := os.open(test_dir)
	testing.expect(t, err == nil, "open test dir should succeed")
	if err == nil {
		file_infos, read_err := os.read_dir(fd, -1, context.allocator)
		_ = os.close(fd)
		testing.expect(t, read_err == nil, "read_dir should succeed")
		defer {
			for fi in file_infos {
				os.file_info_delete(fi, context.allocator)
			}
			delete(file_infos)
		}

		found_log := false
		for fi in file_infos {
			if strings.has_prefix(fi.name, "term-") && strings.has_suffix(fi.name, ".log") {
				found_log = true
				full_file_path, _ := filepath.join({test_dir, fi.name}, context.temp_allocator)
				data, read_file_err := os.read_entire_file(full_file_path, context.allocator)
				testing.expect(t, read_file_err == nil, "reading log file should succeed")
				if read_file_err == nil {
					defer delete(data)
					content := string(data)
					testing.expect(t, strings.contains(content, "Debug probe: value=42"), "log file contains debug probe")
					testing.expect(t, strings.contains(content, "Info probe: system=ready"), "log file contains info probe")
					testing.expect(t, strings.contains(content, "# Term Log - Version: 0.3.0-test"), "log file contains header")
				}
				_ = os.remove(full_file_path)
			}
		}
		testing.expect(t, found_log, "expected at least one term-*.log file in test dir")
	}
}

@(test)
test_diag_snapshot :: proc(t: ^testing.T) {
	snap := diag.Diag_Snapshot{
		strategy  = "ComputeTile",
		tab_count = 3,
		grid_rows = 48,
		grid_cols = 120,
	}

	diag.diag_set_snapshot(snap)
	retrieved := diag.diag_get_snapshot()

	testing.expect_value(t, retrieved.strategy, "ComputeTile")
	testing.expect_value(t, retrieved.tab_count, 3)
	testing.expect_value(t, retrieved.grid_rows, 48)
	testing.expect_value(t, retrieved.grid_cols, 120)
}
