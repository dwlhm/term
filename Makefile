ODIN ?= odin
OUT_DIR ?= bin
MAIN_SRC ?= src/app
TARGET ?= $(OUT_DIR)/term
COMMON_FLAGS ?= -strict-style -extra-linker-flags:"-L/opt/homebrew/lib -L/usr/local/lib -framework Metal -framework MetalKit -framework QuartzCore -framework Cocoa"
CHECK_FLAGS ?= -strict-style
TEST_FLAGS ?= -define:ODIN_TEST_THREADS=1
DEBUG_FLAGS ?= -debug
RELEASE_FLAGS ?= -o:speed -no-bounds-check

.PHONY: all build release build-mcp release-mcp test-mcp bench-mcp bundle install dmg run check test test-terminal test-parser test-pty test-input test-ui test-interaction test-render test-app test-bench bench bench-vte clean help

all: build

build:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build $(MAIN_SRC) -out:$(TARGET) $(DEBUG_FLAGS) $(COMMON_FLAGS)

release:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build $(MAIN_SRC) -out:$(TARGET) $(RELEASE_FLAGS) $(COMMON_FLAGS)

build-mcp:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build src/cmd/term_mcp -out:$(OUT_DIR)/term-mcp $(DEBUG_FLAGS) -strict-style

release-mcp:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build src/cmd/term_mcp -out:$(OUT_DIR)/term-mcp $(RELEASE_FLAGS) -strict-style

bundle: release
	@mkdir -p $(OUT_DIR)/Term.app/Contents/MacOS
	@mkdir -p $(OUT_DIR)/Term.app/Contents/Resources
	cp $(TARGET) $(OUT_DIR)/Term.app/Contents/MacOS/
	cp assets/Info.plist $(OUT_DIR)/Term.app/Contents/Info.plist
	cp assets/term.icns $(OUT_DIR)/Term.app/Contents/Resources/
	rm -rf $(OUT_DIR)/Term.app/Contents/Resources/fonts
	cp -R assets/fonts $(OUT_DIR)/Term.app/Contents/Resources/
	cp THIRD_PARTY_NOTICES.md $(OUT_DIR)/Term.app/Contents/Resources/
	@chmod +x scripts/bundle_frameworks.sh
	scripts/bundle_frameworks.sh $(OUT_DIR)/Term.app

install: bundle
	cp -R $(OUT_DIR)/Term.app /Applications/Term.app

dmg: bundle
	@rm -rf $(OUT_DIR)/dmg_staging
	@rm -f $(OUT_DIR)/Term.dmg
	@hdiutil detach "/Volumes/Term"* -force 2>/dev/null || true
	@mkdir -p $(OUT_DIR)/dmg_staging
	cp -R $(OUT_DIR)/Term.app $(OUT_DIR)/dmg_staging/
	ln -s /Applications $(OUT_DIR)/dmg_staging/Applications
	for i in 1 2 3 4 5; do \
		hdiutil create -volname "Term" -srcfolder $(OUT_DIR)/dmg_staging -ov -format UDZO -fs HFS+ $(OUT_DIR)/Term.dmg && break || { \
			echo "hdiutil create failed (attempt $$i), retrying in 2s..."; \
			hdiutil detach "/Volumes/Term"* -force 2>/dev/null || true; \
			sleep 2; \
		}; \
	done
	rm -rf $(OUT_DIR)/dmg_staging

run: build
	./$(TARGET)

check:
	$(ODIN) check src/app $(CHECK_FLAGS)
	$(ODIN) check src/session_core $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/cmd/term_mcp $(CHECK_FLAGS)
	$(ODIN) check src/terminal $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/parser $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/render $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/platform $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/config $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/ui $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/interaction $(CHECK_FLAGS) -no-entry-point

test: test-config test-terminal test-parser test-pty test-input test-ui test-interaction test-render test-app test-bench test-mcp

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

test-mcp:
	$(ODIN) test src/cmd/term_mcp/tests -strict-style $(TEST_FLAGS)

bench-mcp: release-mcp
	python3 scripts/bench_mcp_comprehensive.py

bench:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build src/bench/cmd_parser -out:$(OUT_DIR)/bench_parser -o:speed
	$(ODIN) build src/bench/cmd_terminal -out:$(OUT_DIR)/bench_terminal -o:speed
	$(ODIN) build src/bench/cmd_pty -out:$(OUT_DIR)/bench_pty -o:speed
	$(ODIN) build src/bench/cmd_input_photon -out:$(OUT_DIR)/bench_input_photon -o:speed

bench-vte:
	@chmod +x scripts/bench_comparative.sh 2>/dev/null || true
	@./scripts/bench_comparative.sh 2>/dev/null || bash scripts/bench_comparative.sh


clean:
	rm -rf $(OUT_DIR) $(OUT_DIR)/Term.app $(OUT_DIR)/Term.dmg $(OUT_DIR)/dmg_staging build term-app app.bin *.dSYM

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  all             Alias for build"
	@echo "  build           Build debug executable to $(TARGET)"
	@echo "  release         Build release executable to $(TARGET)"
	@echo "  build-mcp       Build standalone headless MCP server to $(OUT_DIR)/term-mcp"
	@echo "  release-mcp     Build release standalone headless MCP server to $(OUT_DIR)/term-mcp"
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
	@echo "  test-mcp        Run MCP server unit tests"
	@echo "  bench           Build benchmark executables to $(OUT_DIR)/bench_*"
	@echo "  bench-vte       Run comparative VTE benchmark generator and instructions"
	@echo "  clean           Remove build artifacts and temporary binaries"
	@echo "  help            Show this help message"
