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

.PHONY: all term run term-debug harness-features run-harness-features harness-render-chrome run-harness-render-chrome harness-render-terminal run-harness-render-terminal harness-render-composer run-harness-composer test test-composer test-composer-frame test-composer-scheduler test-composer-transition test-chrome test-render-contract test-gpu check clean help bench bench-quick

all: term harness-features harness-render-chrome harness-render-terminal harness-composer

term:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build src/app/term -out:$(OUT_DIR)/term $(RELEASE_FLAGS) $(COMMON_FLAGS)

term-debug:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build src/app/term -out:$(OUT_DIR)/term $(DEBUG_FLAGS) $(COMMON_FLAGS)

run: term
	./$(OUT_DIR)/term

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

bench-session:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build src/cmd/bench_session -out:$(OUT_DIR)/bench_session $(RELEASE_FLAGS) $(COMMON_FLAGS)
	./$(OUT_DIR)/bench_session

test: test-terminal test-pty test-session test-tabs test-multiplexer test-interaction test-composer test-composer-frame test-composer-scheduler test-composer-transition test-chrome test-render-contract test-gpu test-features test-e2e

test-terminal:
	$(ODIN) test src/core/terminal/tests $(TEST_FLAGS)

test-pty:
	$(ODIN) test src/platform/pty/tests $(TEST_FLAGS)

test-session:
	$(ODIN) test src/features/session/tests $(TEST_FLAGS)

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

test-e2e:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build src/cmd/test_e2e_real -out:$(OUT_DIR)/test_e2e_real $(DEBUG_FLAGS) $(COMMON_FLAGS)
	./$(OUT_DIR)/test_e2e_real

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

check:
	$(ODIN) check src/cmd/harness_helper $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/cmd/harness_render_chrome $(CHECK_FLAGS)
	$(ODIN) check src/cmd/harness_render_terminal $(CHECK_FLAGS)
	$(ODIN) check src/cmd/harness_composer $(CHECK_FLAGS)
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
	$(ODIN) check src/platform/font $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/render/atlas $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/render/terminal $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/render/terminal/instance $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/render/terminal/tile $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/render/terminal/fullscreen $(CHECK_FLAGS) -no-entry-point
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
	$(ODIN) check src/app/term $(CHECK_FLAGS)

clean:
	rm -rf $(OUT_DIR) $(OUT_DIR)/Term.app $(OUT_DIR)/Term.dmg $(OUT_DIR)/dmg_staging build term-app app.bin *.dSYM

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  all                         Build both active GUI harnesses (default)"
	@echo "  harness-render-chrome       Build standalone GUI harness & chrome preview benchmark"
	@echo "  harness-render-terminal     Build standalone terminal render harness"
	@echo "  harness-render-composer     Alias for harness-render-chrome"
	@echo "  harness-composer            Build standalone GUI harness & pure compositor benchmark"
	@echo "  test                        Run all active core unit tests"
	@echo "  test-composer               Run composer pipeline unit tests"
	@echo "  test-render-contract        Run render contract & damage unit tests"
	@echo "  check                       Type check all active core modules and harnesses"
	@echo "  clean                       Remove build artifacts and binaries"
	@echo "  bench                       Run harness_composer full benchmark suite"
	@echo "  bench-quick                 Run harness_composer quick benchmark suite"
	@echo "  help                        Show this help message"
