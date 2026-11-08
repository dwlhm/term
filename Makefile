ODIN ?= odin
OUT_DIR ?= bin
PREFIX ?= /usr/local
UNAME_S := $(shell uname -s)

GIT_COMMIT ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_DIRTY ?= $(shell git diff --quiet 2>/dev/null || echo "-dirty")

ifeq ($(UNAME_S),Darwin)
HOMEBREW_PREFIX ?= $(shell brew --prefix 2>/dev/null || echo /opt/homebrew)
MIN_OS_VERSION ?= 14.0
LINK_FLAGS ?= -L/opt/homebrew/lib -L/usr/local/lib -framework Metal -framework MetalKit -framework QuartzCore -framework Cocoa -framework IOKit
COMMON_FLAGS ?= -define:GIT_COMMIT=\"$(GIT_COMMIT)$(GIT_DIRTY)\" -minimum-os-version:$(MIN_OS_VERSION) -strict-style -extra-linker-flags:"$(LINK_FLAGS)"
else
LINK_FLAGS ?= -L/usr/local/lib -L/usr/lib -lSDL3 -lfreetype -lharfbuzz
COMMON_FLAGS ?= -define:GIT_COMMIT=\"$(GIT_COMMIT)$(GIT_DIRTY)\" -strict-style -extra-linker-flags:"$(LINK_FLAGS)"
endif

CHECK_FLAGS ?= -strict-style
TEST_FLAGS ?= -define:ODIN_TEST_THREADS=1
DEBUG_FLAGS ?= -debug
RELEASE_FLAGS ?= -o:speed -no-bounds-check

# Lua 5.4 for `term auto` contracts (third_party/lua-5.4.9), built here and
# linked statically by src/platform/lua.
LUA_DIR    := third_party/lua-5.4.9/src
LUA_LIB    := build/lua/liblua.a
LUA_OBJ    := $(patsubst $(LUA_DIR)/%.c,build/lua/%.o,$(wildcard $(LUA_DIR)/*.c))
LUA_CFLAGS ?= -O2 -std=gnu99 -Wall -DLUA_USE_POSIX
ifeq ($(UNAME_S),Darwin)
LUA_CFLAGS += -mmacosx-version-min=$(MIN_OS_VERSION)
endif

.PHONY: all lua test-automation test-ipc-contract ipc-example term release run term-debug harness-features run-harness-features harness-render-chrome run-harness-render-chrome harness-render-terminal run-harness-render-terminal harness-render-composer run-harness-composer test test-app test-holder test-session-core test-font test-composer test-composer-frame test-composer-scheduler test-composer-transition test-chrome test-render-contract test-gpu check esctest clean help bench bench-quick bundle dmg portable dist install uninstall test-unicode-width gen-unicode bench-parser bench-session bench-throughput test-poller

all: term harness-features harness-render-chrome harness-render-terminal harness-composer

term: $(LUA_LIB)
	@mkdir -p $(OUT_DIR)
	$(ODIN) build src/app/term -out:$(OUT_DIR)/term $(RELEASE_FLAGS) $(COMMON_FLAGS)

release: term

term-debug: $(LUA_LIB)
	@mkdir -p $(OUT_DIR)
	$(ODIN) build src/app/term -out:$(OUT_DIR)/term $(DEBUG_FLAGS) $(COMMON_FLAGS)

lua: $(LUA_LIB)

$(LUA_LIB): $(LUA_OBJ)
	ar rcs $@ $^

build/lua/%.o: $(LUA_DIR)/%.c
	@mkdir -p build/lua
	$(CC) $(LUA_CFLAGS) -c $< -o $@

run: term
	./$(OUT_DIR)/term

ifeq ($(UNAME_S),Darwin)
bundle: term
	@mkdir -p $(OUT_DIR)/Term.app/Contents/MacOS
	@mkdir -p $(OUT_DIR)/Term.app/Contents/Resources
	cp $(OUT_DIR)/term $(OUT_DIR)/Term.app/Contents/MacOS/
	cp assets/Info.plist $(OUT_DIR)/Term.app/Contents/Info.plist
	cp assets/term.icns $(OUT_DIR)/Term.app/Contents/Resources/
	rm -rf $(OUT_DIR)/Term.app/Contents/Resources/fonts
	cp -R assets/fonts $(OUT_DIR)/Term.app/Contents/Resources/
	cp THIRD_PARTY_NOTICES.md $(OUT_DIR)/Term.app/Contents/Resources/
	@chmod +x scripts/bundle_frameworks.sh
	scripts/bundle_frameworks.sh $(OUT_DIR)/Term.app

install: bundle
	@echo "Installing Term.app to /Applications..."
	@rm -rf /Applications/Term.app
	ditto $(OUT_DIR)/Term.app /Applications/Term.app
	@echo "Installed Term.app to /Applications successfully."
	@mkdir -p $(HOME)/.local/bin
	@ln -sf /Applications/Term.app/Contents/MacOS/term $(HOME)/.local/bin/term
	@echo "Configuring Term agent skills..."
	@/Applications/Term.app/Contents/MacOS/term skill setup || true

link: term
	@mkdir -p $(HOME)/.local/bin
	@ln -sf $(CURDIR)/$(OUT_DIR)/term $(HOME)/.local/bin/term
	@echo "Linked $(CURDIR)/$(OUT_DIR)/term -> $(HOME)/.local/bin/term"
	@$(CURDIR)/$(OUT_DIR)/term skill setup || true

uninstall:
	@echo "Uninstalling Term.app from /Applications..."
	@rm -rf /Applications/Term.app
	@echo "Term.app uninstalled."

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
	@rm -rf $(OUT_DIR)/dmg_staging
	@echo "Created $(OUT_DIR)/Term.dmg successfully."

portable: bundle
	@rm -f $(OUT_DIR)/Term-portable.zip
	cd $(OUT_DIR) && zip -r -y -q Term-portable.zip Term.app
	@echo "Created $(OUT_DIR)/Term-portable.zip successfully."

dist: dmg portable
endif

harness-render-chrome:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build src/cmd/harness_render_chrome -out:$(OUT_DIR)/harness_render_chrome $(DEBUG_FLAGS) $(COMMON_FLAGS)

run-harness-render-chrome: harness-render-chrome
	./$(OUT_DIR)/harness_render_chrome

harness-render-terminal:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build src/cmd/harness_render_terminal -out:$(OUT_DIR)/harness_render_terminal $(DEBUG_FLAGS) $(COMMON_FLAGS)

run-harness-render-terminal: harness-render-terminal
	./$(OUT_DIR)/harness_render_terminal

harness-render-composer: harness-render-chrome

run-harness-render-composer: run-harness-render-chrome

harness-composer:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build src/cmd/harness_composer -out:$(OUT_DIR)/harness_composer $(DEBUG_FLAGS) $(COMMON_FLAGS)

run-harness-composer: harness-composer
	./$(OUT_DIR)/harness_composer

bench: harness-composer
	./$(OUT_DIR)/harness_composer --bench

bench-quick: harness-composer
	./$(OUT_DIR)/harness_composer --bench --quick

# Parser + grid throughput per workload (no PTY/IPC/GPU); ARGS="--rows 50 --cols 200".
bench-parser:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build src/cmd/bench_parser -out:$(OUT_DIR)/bench_parser $(RELEASE_FLAGS) $(COMMON_FLAGS)
	./$(OUT_DIR)/bench_parser $(ARGS)

bench-session:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build src/cmd/bench_session -out:$(OUT_DIR)/bench_session $(RELEASE_FLAGS) $(COMMON_FLAGS)
	./$(OUT_DIR)/bench_session

# Output MB/s + CPU per tier: PTY → holder → core (no viewer / Python viewer / GUI); ARGS="-m noview -r 1 file".
bench-throughput: term
	python3 -I scripts/stress/throughput.py -t $(OUT_DIR)/term $(ARGS)

test: test-app test-automation test-unicode-width test-terminal test-pty test-holder test-session-core test-font test-window test-session test-control test-ipc test-poller test-tabs test-multiplexer test-interaction test-composer test-composer-frame test-composer-scheduler test-composer-transition test-chrome test-render-contract test-gpu test-features test-e2e

# VT conformance suite (esctest2) driven inside a real Term pane; requires a GUI
# session. Extra esctest flags: make esctest ESCTEST_ARGS="--include=CUP"
esctest: term
	@chmod +x scripts/run_esctest.sh
	scripts/run_esctest.sh $(ESCTEST_ARGS)

test-app: $(LUA_LIB)
	$(ODIN) test src/app/term $(TEST_FLAGS)

test-automation: $(LUA_LIB)
	$(ODIN) test src/features/automation/tests $(TEST_FLAGS)

test-terminal:
	$(ODIN) test src/core/terminal/tests $(TEST_FLAGS)

test-pty:
	$(ODIN) test src/platform/pty/tests $(TEST_FLAGS)

test-holder:
	$(ODIN) test src/features/holder/tests $(CHECK_FLAGS) $(TEST_FLAGS)

test-session-core: $(LUA_LIB)
	$(ODIN) test src/features/session_core/tests $(CHECK_FLAGS) $(TEST_FLAGS)

test-font:
	$(ODIN) test src/platform/font/tests $(TEST_FLAGS)

test-unicode-width:
	$(ODIN) test src/core/unicode_width/tests $(TEST_FLAGS)

# Regenerates the unicode_width lookup tables from unicode_width/reference.
gen-unicode:
	$(ODIN) run src/core/unicode_width/gen -- src/core/unicode_width/tables.odin

test-window:
	$(ODIN) test src/platform/window $(TEST_FLAGS)

test-session:
	$(ODIN) test src/features/session/tests $(TEST_FLAGS)

test-control:
	$(ODIN) test src/features/control/tests $(TEST_FLAGS)

# The echo example proves the IPC package stands alone (spec 7.1); test-ipc
# builds it, test-ipc-contract runs it (P37).
IPC_EXAMPLE := build/ipc-echo

ipc-example:
	@mkdir -p build
	$(ODIN) build src/platform/ipc/example $(CHECK_FLAGS) -out:$(IPC_EXAMPLE)

test-ipc: ipc-example
	$(ODIN) test src/platform/ipc/tests $(CHECK_FLAGS) $(TEST_FLAGS)

# Contract tests of the IPC package that are still red (IPC spec, section 10).
# Not part of `test`: a test moves to src/platform/ipc/tests (or out of the
# IPC_CONTRACT block in session_core/tests) once it passes. The tier tests
# P33/P34 need the session_core test build (about 4.5 min).
# Prints each failure summary and the red IDs (a list that must never grow).
IPC_TIER_TESTS := test_P33_core_hello_to_a_holder_is_0_0_2_byte_for_byte,test_P33_a_link_dial_is_taken_by_the_holder,test_P34_next_timing_out_during_answer_is_a_late_answer

test-ipc-contract: ipc-example $(LUA_LIB)
	@$(ODIN) test src/platform/ipc/contract $(CHECK_FLAGS) $(TEST_FLAGS) -define:ODIN_TEST_FANCY=false -out:build/ipc-contract \
		-define:IPC_EXAMPLE=$(CURDIR)/$(IPC_EXAMPLE) > build/ipc-contract.log 2>&1; lib=$$?; \
	$(ODIN) test src/features/session_core/tests $(CHECK_FLAGS) $(TEST_FLAGS) -define:ODIN_TEST_FANCY=false -out:build/ipc-contract-tiers \
		-define:IPC_CONTRACT=true -define:ODIN_TEST_NAMES=$(IPC_TIER_TESTS) >> build/ipc-contract.log 2>&1; tiers=$$?; \
	if grep -q '^Finished' build/ipc-contract.log; then sed -n '/^Finished/,/^$$/p' build/ipc-contract.log; \
	else tail -n 40 build/ipc-contract.log; fi; \
	echo "red: $$(sed -n 's/^ - [a-z_]*\.test_\(P[0-9]*\)_.*/\1/p' build/ipc-contract.log | sort -u | sort -k1.2n | tr '\n' ' ')"; \
	test $$lib -eq 0 -a $$tiers -eq 0

test-poller:
	$(ODIN) test src/platform/poller/tests $(CHECK_FLAGS) $(TEST_FLAGS)

test-tabs:
	$(ODIN) test src/features/tabs/tests $(TEST_FLAGS)

test-multiplexer:
	$(ODIN) test src/features/multiplexer/tests $(TEST_FLAGS)

test-interaction:
	$(ODIN) test src/features/interaction/tests $(TEST_FLAGS)

test-features: harness-features
	./$(OUT_DIR)/harness_features --test

harness-features:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build src/cmd/harness_features -out:$(OUT_DIR)/harness_features $(DEBUG_FLAGS) $(COMMON_FLAGS)

run-harness-features: harness-features
	./$(OUT_DIR)/harness_features

term-driver:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build src/cmd/term_driver -out:$(OUT_DIR)/term_driver $(DEBUG_FLAGS) $(COMMON_FLAGS)

test-e2e: term-driver
	python3 tests/e2e/runner.py $(SPEC)

test-e2e-legacy:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build src/cmd/test_e2e_real -out:$(OUT_DIR)/test_e2e_real $(DEBUG_FLAGS) $(COMMON_FLAGS)
	./$(OUT_DIR)/test_e2e_real

video-player:
	@mkdir -p $(OUT_DIR)
	swiftc -O scripts/term_video_player.swift -o $(OUT_DIR)/term_video_player

stress-video: term video-player
	./$(OUT_DIR)/term -e "./$(OUT_DIR)/term_video_player --plasma --fps 60 --duration 10"

demo:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build src/cmd/demo_session -out:$(OUT_DIR)/demo_session $(DEBUG_FLAGS) $(COMMON_FLAGS)
	./$(OUT_DIR)/demo_session

test-composer:
	$(ODIN) test src/core/composer/tests $(CHECK_FLAGS) $(TEST_FLAGS)

test-composer-frame:
	$(ODIN) test src/core/composer/frame/tests $(CHECK_FLAGS) $(TEST_FLAGS)

test-composer-scheduler:
	$(ODIN) test src/core/composer/scheduler/tests $(CHECK_FLAGS) $(TEST_FLAGS)

test-composer-transition:
	$(ODIN) test src/core/composer/transition/tests $(CHECK_FLAGS) $(TEST_FLAGS)

test-chrome:
	$(ODIN) test src/core/chrome/draw_list $(CHECK_FLAGS) $(TEST_FLAGS)
	$(ODIN) test src/core/chrome/tabs $(CHECK_FLAGS) $(TEST_FLAGS)
	$(ODIN) test src/core/chrome/splits $(CHECK_FLAGS) $(TEST_FLAGS)
	$(ODIN) test src/core/chrome/modals $(CHECK_FLAGS) $(TEST_FLAGS)
	$(ODIN) test src/core/chrome/hit_test $(CHECK_FLAGS) $(TEST_FLAGS)

test-gpu: harness-render-terminal
	./$(OUT_DIR)/harness_render_terminal --test


test-render-contract:
	$(ODIN) test src/core/render/contract/tests $(CHECK_FLAGS) $(TEST_FLAGS)

check: $(LUA_LIB)
	$(ODIN) check src/cmd/harness_helper $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/cmd/harness_render_chrome $(CHECK_FLAGS)
	$(ODIN) check src/cmd/harness_render_terminal $(CHECK_FLAGS)
	$(ODIN) check src/cmd/harness_composer $(CHECK_FLAGS)
	$(ODIN) check src/cmd/bench_parser $(CHECK_FLAGS)
	$(ODIN) check src/cmd/term_driver $(CHECK_FLAGS)
	$(ODIN) check src/core/cursor $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/unicode_width $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/unicode_width/reference $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/unicode_width/gen $(CHECK_FLAGS)
	$(ODIN) check src/core/composer $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/composer/layer $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/composer/blit $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/composer/pipeline $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/composer/scheduler $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/composer/transition $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/composer/frame $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/render/contract $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/platform/gpu/wgpu $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/platform/window $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/platform/clipboard $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/platform/ipc $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/platform/ipc/example $(CHECK_FLAGS)
	$(ODIN) check src/features/control $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/features/holder $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/features/session_core $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/features/session_proto $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/features/session_core/tests $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/platform/pty $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/platform/font $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/render/atlas $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/render/terminal $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/render/terminal/instance $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/chrome/draw_list $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/chrome/tabs $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/chrome/splits $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/chrome/hit_test $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/chrome/modals $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/render/chrome/surface $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/render/chrome/batch $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/render/chrome/sdf $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/render/chrome $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/render/three_d $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/terminal/extension $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/features/session $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/features/tabs $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/features/multiplexer $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/features/interaction $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/app/term $(CHECK_FLAGS)

clean:
	rm -rf $(OUT_DIR) $(OUT_DIR)/Term.app $(OUT_DIR)/Term.dmg $(OUT_DIR)/Term-portable.zip $(OUT_DIR)/dmg_staging build term-app app.bin *.dSYM

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  all                         Build both active GUI harnesses (default)"
	@echo "  term                        Build release terminal binary to bin/term"
	@echo "  release                     Alias for term (build release binary)"
	@echo "  bundle                      Create macOS self-contained application bundle (Term.app)"
	@echo "  dmg                         Create macOS disk image installer (Term.dmg)"
	@echo "  portable                    Create macOS portable archive (Term-portable.zip)"
	@echo "  dist                        Create all distribution packages (dmg + portable)"
	@echo "  install                     Install Term.app to /Applications"
	@echo "  uninstall                   Remove Term.app from /Applications"
	@echo "  harness-render-chrome       Build standalone GUI harness & chrome preview benchmark"
	@echo "  harness-render-terminal     Build standalone terminal render harness"
	@echo "  harness-render-composer     Alias for harness-render-chrome"
	@echo "  harness-composer            Build standalone GUI harness & pure compositor benchmark"
	@echo "  test                        Run all active core unit tests"
	@echo "  test-composer               Run composer pipeline unit tests"
	@echo "  test-render-contract        Run render contract & damage unit tests"
	@echo "  check                       Type check all active core modules and harnesses"
	@echo "  esctest                     Run the esctest2 VT conformance suite inside Term"
	@echo "  clean                       Remove build artifacts and binaries"
	@echo "  bench                       Run harness_composer full benchmark suite"
	@echo "  bench-quick                 Run harness_composer quick benchmark suite"
	@echo "  bench-throughput            Output MB/s and CPU per tier (cat in a session; ARGS=...)"
	@echo "  help                        Show this help message"
