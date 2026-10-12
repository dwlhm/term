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

.PHONY: all harness-render-chrome run-harness-render-chrome harness-render-terminal run-harness-render-terminal harness-render-composer run-harness-render-composer harness-composer run-harness-composer test test-composer test-composer-frame test-composer-scheduler test-composer-transition test-chrome test-render-contract check check-linux clean help bench bench-quick

all: harness-render-chrome harness-render-terminal harness-composer

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

test: test-composer test-composer-frame test-composer-scheduler test-composer-transition test-chrome test-render-contract

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
	$(ODIN) check src/core/platform/gpu/wgpu $(CHECK_FLAGS) -no-entry-point
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

check-linux:
	$(ODIN) check src/core/composer $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/core/composer/layer $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/core/composer/blit $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/core/composer/pipeline $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/core/composer/frame $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/core/render/contract $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/core/platform/gpu/wgpu $(CHECK_FLAGS) -no-entry-point
	$(ODIN) check src/core/render/atlas $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/core/render/terminal $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/core/render/terminal/instance $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/core/render/terminal/tile $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/core/render/terminal/fullscreen $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/core/chrome/draw_list $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/core/chrome/tabs $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/core/chrome/splits $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/core/chrome/hit_test $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/core/chrome/modals $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/core/render/chrome/surface $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/core/render/chrome/batch $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/core/render/chrome/sdf $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/core/render/chrome $(CHECK_FLAGS) -no-entry-point -target:linux_arm64
	$(ODIN) check src/core/render/three_d $(CHECK_FLAGS) -no-entry-point

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
	@echo "  check-linux                 Type check core modules targeting Linux ARM64"
	@echo "  clean                       Remove build artifacts and binaries"
	@echo "  bench                       Run harness_composer full benchmark suite"
	@echo "  bench-quick                 Run harness_composer quick benchmark suite"
	@echo "  help                        Show this help message"
