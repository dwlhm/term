ODIN ?= odin
OUT_DIR ?= bin
MAIN_SRC ?= src/app
TARGET ?= $(OUT_DIR)/term
COMMON_FLAGS ?= -strict-style
DEBUG_FLAGS ?= -debug
RELEASE_FLAGS ?= -o:speed -no-bounds-check

.PHONY: all build release run check test test-terminal test-parser test-pty test-input test-render test-app test-bench bench clean help

all: build

build:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build $(MAIN_SRC) -out:$(TARGET) $(DEBUG_FLAGS) $(COMMON_FLAGS)

release:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build $(MAIN_SRC) -out:$(TARGET) $(RELEASE_FLAGS) $(COMMON_FLAGS)

run: build
	./$(TARGET)

check:
	$(ODIN) check src/app $(COMMON_FLAGS)
	$(ODIN) check src/terminal $(COMMON_FLAGS) -no-entry-point
	$(ODIN) check src/parser $(COMMON_FLAGS) -no-entry-point
	$(ODIN) check src/render $(COMMON_FLAGS) -no-entry-point
	$(ODIN) check src/platform $(COMMON_FLAGS) -no-entry-point

test: test-terminal test-parser test-pty test-input test-render test-app test-bench

test-terminal:
	$(ODIN) test src/terminal/tests $(COMMON_FLAGS)

test-parser:
	$(ODIN) test src/parser/tests $(COMMON_FLAGS)

test-pty:
	$(ODIN) test src/platform/pty/tests $(COMMON_FLAGS)

test-input:
	$(ODIN) test src/platform/input/tests $(COMMON_FLAGS)

test-render:
	$(ODIN) test src/render/tests $(COMMON_FLAGS)

test-app:
	$(ODIN) test src/app/tests $(COMMON_FLAGS)

test-bench:
	$(ODIN) test src/bench/tests $(COMMON_FLAGS)

bench:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build src/bench/cmd_parser -out:$(OUT_DIR)/bench_parser -o:speed
	$(ODIN) build src/bench/cmd_terminal -out:$(OUT_DIR)/bench_terminal -o:speed
	$(ODIN) build src/bench/cmd_pty -out:$(OUT_DIR)/bench_pty -o:speed
	$(ODIN) build src/bench/cmd_input_photon -out:$(OUT_DIR)/bench_input_photon -o:speed

clean:
	rm -rf $(OUT_DIR) build term-app app.bin

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  all             Alias for build"
	@echo "  build           Build debug executable to $(TARGET)"
	@echo "  release         Build release executable to $(TARGET)"
	@echo "  run             Build and run executable"
	@echo "  check           Type check all source modules"
	@echo "  test            Run all test suites sequentially"
	@echo "  test-terminal   Run terminal unit tests"
	@echo "  test-parser     Run parser unit tests"
	@echo "  test-pty        Run PTY unit tests"
	@echo "  test-input      Run input unit tests"
	@echo "  test-render     Run render unit tests"
	@echo "  test-app        Run app unit tests"
	@echo "  test-bench      Run bench unit tests"
	@echo "  bench           Build benchmark executables to $(OUT_DIR)/bench_*"
	@echo "  clean           Remove build artifacts and temporary binaries"
	@echo "  help            Show this help message"
