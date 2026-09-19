ODIN ?= odin
OUT_DIR ?= bin
MAIN_SRC ?= src/app
TARGET ?= $(OUT_DIR)/term
COMMON_FLAGS ?= -strict-style -extra-linker-flags:"-L/opt/homebrew/lib -L/usr/local/lib"
CHECK_FLAGS ?= -strict-style
TEST_FLAGS ?= -define:ODIN_TEST_THREADS=1
DEBUG_FLAGS ?= -debug
RELEASE_FLAGS ?= -o:speed -no-bounds-check

.PHONY: all build release bundle install dmg run check test test-terminal test-parser test-pty test-input test-ui test-interaction test-render test-app test-bench bench bench-vte setup-wgpu clean help

all: build

build:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build $(MAIN_SRC) -out:$(TARGET) $(DEBUG_FLAGS) $(COMMON_FLAGS)

release:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build $(MAIN_SRC) -out:$(TARGET) $(RELEASE_FLAGS) $(COMMON_FLAGS)

bundle: release
	@mkdir -p $(OUT_DIR)/Term.app/Contents/MacOS
	@mkdir -p $(OUT_DIR)/Term.app/Contents/Resources
	cp $(TARGET) $(OUT_DIR)/Term.app/Contents/MacOS/
	cp assets/Info.plist $(OUT_DIR)/Term.app/Contents/Info.plist
	cp assets/term.icns $(OUT_DIR)/Term.app/Contents/Resources/
	cp -R assets/fonts $(OUT_DIR)/Term.app/Contents/Resources/

install: bundle
	cp -R $(OUT_DIR)/Term.app /Applications/Term.app

dmg: bundle
	@mkdir -p $(OUT_DIR)/dmg_staging
	cp -R $(OUT_DIR)/Term.app $(OUT_DIR)/dmg_staging/
	ln -s /Applications $(OUT_DIR)/dmg_staging/Applications
	hdiutil create -volname "Term" -srcfolder $(OUT_DIR)/dmg_staging -ov -format UDZO $(OUT_DIR)/Term.dmg
	rm -rf $(OUT_DIR)/dmg_staging

run: build
	./$(TARGET)

check:
	$(ODIN) check src/app $(CHECK_FLAGS)
	$(ODIN) check src/terminal $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/parser $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/render $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/platform $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/config $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/ui $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/interaction $(CHECK_FLAGS) -no-entry-point

test: test-config test-terminal test-parser test-pty test-input test-ui test-interaction test-render test-app test-bench

test-config:
	$(ODIN) test src/config/tests $(COMMON_FLAGS) $(TEST_FLAGS)

test-terminal:
	$(ODIN) test src/terminal/tests $(COMMON_FLAGS) $(TEST_FLAGS)

test-parser:
	$(ODIN) test src/parser/tests $(COMMON_FLAGS) $(TEST_FLAGS)

test-pty:
	$(ODIN) test src/platform/pty/tests $(COMMON_FLAGS) $(TEST_FLAGS)

test-input:
	$(ODIN) test src/platform/input/tests $(COMMON_FLAGS) $(TEST_FLAGS)

test-ui:
	$(ODIN) test src/ui/tests $(COMMON_FLAGS) $(TEST_FLAGS)

test-interaction:
	$(ODIN) test src/interaction/tests $(COMMON_FLAGS) $(TEST_FLAGS)

test-render:
	$(ODIN) test src/render/tests $(COMMON_FLAGS) $(TEST_FLAGS)

test-app:
	$(ODIN) test src/app/tests $(COMMON_FLAGS) $(TEST_FLAGS)

test-bench:
	$(ODIN) test src/bench/tests $(COMMON_FLAGS) $(TEST_FLAGS)

bench:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build src/bench/cmd_parser -out:$(OUT_DIR)/bench_parser -o:speed
	$(ODIN) build src/bench/cmd_terminal -out:$(OUT_DIR)/bench_terminal -o:speed
	$(ODIN) build src/bench/cmd_pty -out:$(OUT_DIR)/bench_pty -o:speed
	$(ODIN) build src/bench/cmd_input_photon -out:$(OUT_DIR)/bench_input_photon -o:speed

bench-vte:
	@chmod +x scripts/bench_comparative.sh 2>/dev/null || true
	@./scripts/bench_comparative.sh 2>/dev/null || bash scripts/bench_comparative.sh

setup-wgpu:
	@ODIN_PATH=$$(odin root); \
	TARGET_DIR="$$ODIN_PATH/vendor/wgpu/lib/wgpu-macos-aarch64-release"; \
	if [ ! -f "$$TARGET_DIR/lib/libwgpu_native.a" ]; then \
		mkdir -p "$$TARGET_DIR"; \
		if [ ! -f "/tmp/wgpu.zip" ]; then \
			echo "Downloading wgpu-native v29.0.1.1..."; \
			curl -sSL "https://github.com/gfx-rs/wgpu-native/releases/download/v29.0.1.1/wgpu-macos-aarch64-release.zip" -o /tmp/wgpu.zip; \
		fi; \
		unzip -q -o /tmp/wgpu.zip -d "$$TARGET_DIR"; \
		echo "wgpu-native installed successfully."; \
	else \
		echo "wgpu-native already installed at $$TARGET_DIR."; \
	fi

clean:
	rm -rf $(OUT_DIR) $(OUT_DIR)/Term.app $(OUT_DIR)/Term.dmg $(OUT_DIR)/dmg_staging build term-app app.bin *.dSYM

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  all             Alias for build"
	@echo "  build           Build debug executable to $(TARGET)"
	@echo "  release         Build release executable to $(TARGET)"
	@echo "  bundle          Create macOS application bundle (Term.app)"
	@echo "  install         Install Term.app to /Applications"
	@echo "  dmg             Create macOS disk image (Term.dmg)"
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
	@echo "  bench-vte       Run comparative VTE benchmark generator and instructions"
	@echo "  setup-wgpu      Download and setup wgpu-native static library if missing"
	@echo "  clean           Remove build artifacts and temporary binaries"
	@echo "  help            Show this help message"
