ODIN ?= odin
OUT_DIR ?= bin
MAIN_SRC ?= src/app
TARGET ?= $(OUT_DIR)/term
PREFIX ?= /usr/local
UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S),Darwin)
HOMEBREW_PREFIX ?= $(shell brew --prefix 2>/dev/null || echo /opt/homebrew)
MIN_OS_VERSION ?= 14.0
LINK_FLAGS ?= -L/opt/homebrew/lib -L/usr/local/lib -framework Metal -framework MetalKit -framework QuartzCore -framework Cocoa
COMMON_FLAGS ?= -minimum-os-version:$(MIN_OS_VERSION) -strict-style -extra-linker-flags:"$(LINK_FLAGS)"
APP_FLAGS ?= -minimum-os-version:$(MIN_OS_VERSION) -strict-style -extra-linker-flags:"$(LINK_FLAGS) $(OUT_DIR)/macos_services.o"
PLATFORM_DEPS = $(OUT_DIR)/macos_services.o
else
LINK_FLAGS ?= -L/usr/local/lib -L/usr/lib -lSDL3 -lfreetype -lharfbuzz
COMMON_FLAGS ?= -strict-style -extra-linker-flags:"$(LINK_FLAGS)"
APP_FLAGS ?= -strict-style -extra-linker-flags:"$(LINK_FLAGS)"
PLATFORM_DEPS =
endif

CHECK_FLAGS ?= -strict-style
TEST_FLAGS ?= -define:ODIN_TEST_THREADS=1
DEBUG_FLAGS ?= -debug
RELEASE_FLAGS ?= -o:speed -no-bounds-check

.PHONY: all build release build-mcp release-mcp test-mcp test-version bench-mcp bundle install uninstall dist-linux dmg run check check-linux test test-terminal test-parser test-pty test-input test-tabs test-ui test-interaction test-render test-app test-bench test-mcp test-diag test-probe test-session-core bench bench-run bench-video bench-vte clean help version-info

all: build

version-info:
	python3 scripts/resolve_version.py --source src/build_info/version.odin --plist $(OUT_DIR)/Info.plist

ifeq ($(UNAME_S),Darwin)
$(OUT_DIR)/macos_services.o: src/app/macos_services.m
	@mkdir -p $(OUT_DIR)
	clang -fobjc-arc -mmacosx-version-min=$(MIN_OS_VERSION) -c $< -o $@ -x objective-c -isysroot $(shell xcrun --show-sdk-path) -isystem $(HOMEBREW_PREFIX)/include

build: version-info $(OUT_DIR)/macos_services.o
	@mkdir -p $(OUT_DIR)
	$(ODIN) build $(MAIN_SRC) -out:$(TARGET) $(DEBUG_FLAGS) $(APP_FLAGS)

release: version-info $(OUT_DIR)/macos_services.o
	@mkdir -p $(OUT_DIR)
	$(ODIN) build $(MAIN_SRC) -out:$(TARGET) $(RELEASE_FLAGS) $(APP_FLAGS)
else
build: version-info
	@mkdir -p $(OUT_DIR)
	$(ODIN) build $(MAIN_SRC) -out:$(TARGET) $(DEBUG_FLAGS) $(APP_FLAGS)

release: version-info
	@mkdir -p $(OUT_DIR)
	$(ODIN) build $(MAIN_SRC) -out:$(TARGET) $(RELEASE_FLAGS) $(APP_FLAGS)
endif

build-mcp:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build src/cmd/term_mcp -out:$(OUT_DIR)/term-mcp $(DEBUG_FLAGS) -strict-style

release-mcp:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build src/cmd/term_mcp -out:$(OUT_DIR)/term-mcp $(RELEASE_FLAGS) -strict-style

ifeq ($(UNAME_S),Darwin)
bundle: release
	@mkdir -p $(OUT_DIR)/Term.app/Contents/MacOS
	@mkdir -p $(OUT_DIR)/Term.app/Contents/Resources
	cp $(TARGET) $(OUT_DIR)/Term.app/Contents/MacOS/
	cp $(OUT_DIR)/Info.plist $(OUT_DIR)/Term.app/Contents/Info.plist
	cp assets/term.icns $(OUT_DIR)/Term.app/Contents/Resources/
	rm -rf $(OUT_DIR)/Term.app/Contents/Resources/fonts
	cp -R assets/fonts $(OUT_DIR)/Term.app/Contents/Resources/
	cp THIRD_PARTY_NOTICES.md $(OUT_DIR)/Term.app/Contents/Resources/
	@chmod +x scripts/bundle_frameworks.sh
	scripts/bundle_frameworks.sh $(OUT_DIR)/Term.app

install: bundle
	ditto $(OUT_DIR)/Term.app /Applications/Term.app

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
else
install: release
	@echo "Installing Term to $(PREFIX)..."
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 $(TARGET) $(DESTDIR)$(PREFIX)/bin/term
	install -d $(DESTDIR)$(PREFIX)/share/applications
	install -m 644 assets/term.desktop $(DESTDIR)$(PREFIX)/share/applications/term.desktop
	install -d $(DESTDIR)$(PREFIX)/share/icons/hicolor/512x512/apps
	install -m 644 assets/term.png $(DESTDIR)$(PREFIX)/share/icons/hicolor/512x512/apps/term.png
	install -d $(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps
	install -m 644 logo.svg $(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps/term.svg
	install -d $(DESTDIR)$(PREFIX)/share/term/assets/fonts
	cp -R assets/fonts/* $(DESTDIR)$(PREFIX)/share/term/assets/fonts/
	@chmod 644 $(DESTDIR)$(PREFIX)/share/term/assets/fonts/*
	@if [ -z "$(DESTDIR)" ]; then \
		command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database $(DESTDIR)$(PREFIX)/share/applications 2>/dev/null || true; \
		command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t -f $(DESTDIR)$(PREFIX)/share/icons/hicolor 2>/dev/null || true; \
	fi
	@echo "Term installed successfully to $(PREFIX)/bin/term"

uninstall:
	@echo "Uninstalling Term from $(PREFIX)..."
	rm -f $(DESTDIR)$(PREFIX)/bin/term
	rm -f $(DESTDIR)$(PREFIX)/share/applications/term.desktop
	rm -f $(DESTDIR)$(PREFIX)/share/icons/hicolor/512x512/apps/term.png
	rm -f $(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps/term.svg
	rm -rf $(DESTDIR)$(PREFIX)/share/term
	@if [ -z "$(DESTDIR)" ]; then \
		command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database $(DESTDIR)$(PREFIX)/share/applications 2>/dev/null || true; \
		command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t -f $(DESTDIR)$(PREFIX)/share/icons/hicolor 2>/dev/null || true; \
	fi
	@echo "Term uninstalled."
endif

dist-linux: release
	@chmod +x scripts/package_linux.sh
	scripts/package_linux.sh --target $(TARGET)

run: build
	./$(TARGET)

check: version-info
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
	$(ODIN) check src/diag $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/bench/probe $(CHECK_FLAGS) -no-entry-point

check-linux: version-info
	$(ODIN) check src/session_core $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/cmd/term_mcp $(CHECK_FLAGS) -target:linux_arm64
	$(ODIN) check src/terminal $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/parser $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/platform $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/config $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/ui $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/interaction $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/diag $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/bench/probe $(CHECK_FLAGS) -no-entry-point -target:linux_arm64

test: version-info test-version test-config test-terminal test-parser test-pty test-input test-tabs test-ui test-interaction test-render test-app test-bench test-mcp test-diag test-probe test-session-core

test-version:
	python3 -m unittest discover -s scripts/tests -v

test-config:
	$(ODIN) test src/config/tests $(COMMON_FLAGS) $(TEST_FLAGS)

test-terminal:
	$(ODIN) test src/terminal/tests $(COMMON_FLAGS) $(TEST_FLAGS)

test-parser: version-info
	$(ODIN) test src/parser/tests $(COMMON_FLAGS) $(TEST_FLAGS)

test-pty: version-info
	$(ODIN) test src/platform/pty/tests $(COMMON_FLAGS) $(TEST_FLAGS)

test-input:
	$(ODIN) test src/platform/input/tests $(COMMON_FLAGS) $(TEST_FLAGS)

test-tabs:
	$(ODIN) test src/platform/tabs/tests $(COMMON_FLAGS) $(TEST_FLAGS)

test-ui:
	$(ODIN) test src/ui/tests $(COMMON_FLAGS) $(TEST_FLAGS)

test-interaction:
	$(ODIN) test src/interaction/tests $(COMMON_FLAGS) $(TEST_FLAGS)

test-render:
	$(ODIN) test src/render/tests $(COMMON_FLAGS) $(TEST_FLAGS)

ifeq ($(UNAME_S),Darwin)
test-app: version-info $(OUT_DIR)/macos_services.o
	$(ODIN) test src/app/tests $(APP_FLAGS) $(TEST_FLAGS)
else
test-app: version-info
	$(ODIN) test src/app/tests $(APP_FLAGS) $(TEST_FLAGS)
endif

test-bench:
	$(ODIN) test src/bench/tests $(COMMON_FLAGS) $(TEST_FLAGS)

test-mcp:
	$(ODIN) test src/cmd/term_mcp/tests -strict-style $(TEST_FLAGS)

test-diag:
	$(ODIN) test src/diag/tests $(COMMON_FLAGS) $(TEST_FLAGS)

test-probe:
	$(ODIN) test src/bench/probe/tests $(COMMON_FLAGS) $(TEST_FLAGS)

test-session-core:
	$(ODIN) test src/session_core/tests $(COMMON_FLAGS) $(TEST_FLAGS)

bench-mcp: release-mcp
	python3 scripts/bench_mcp_comprehensive.py

bench:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build src/bench/cmd_parser -out:$(OUT_DIR)/bench_parser -o:speed
	$(ODIN) build src/bench/cmd_terminal -out:$(OUT_DIR)/bench_terminal -o:speed
	$(ODIN) build src/bench/cmd_pty -out:$(OUT_DIR)/bench_pty -o:speed
	$(ODIN) build src/bench/cmd_input_photon -out:$(OUT_DIR)/bench_input_photon -o:speed

bench-run: bench
	@echo "=== Running Parser Benchmarks ==="
	@./$(OUT_DIR)/bench_parser
	@echo "\n=== Running Terminal Grid Benchmarks ==="
	@./$(OUT_DIR)/bench_terminal
	@echo "\n=== Running PTY Benchmarks ==="
	@./$(OUT_DIR)/bench_pty
	@echo "\n=== Running Input Photon Latency Benchmarks ==="
	@./$(OUT_DIR)/bench_input_photon

$(OUT_DIR)/term_video_player: scripts/term_video_player.swift
	@mkdir -p $(OUT_DIR)
	swiftc -O -o $@ $<

bench-video: $(OUT_DIR)/term_video_player
	./$(OUT_DIR)/term_video_player --fire --duration 5 --fps 60

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
	@echo "  install         Install Term.app to /Applications (macOS) or prefix (Linux)"
	@echo "  uninstall       Uninstall Term from prefix (Linux)"
	@echo "  dist-linux      Build release and package Linux tarball"
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
	@echo "  bench-run       Run microbenchmark suite (parser, terminal, pty, input)"
	@echo "  bench-video     Run continuous 100% full-screen TrueColor stress benchmark"
	@echo "  bench-vte       Run comparative VTE benchmark generator and instructions"
	@echo "  clean           Remove build artifacts and temporary binaries"
	@echo "  help            Show this help message"
