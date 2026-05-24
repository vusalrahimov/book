# =============================================================================
# Enterprise Java & Distributed Systems Engineering — Makefile
# =============================================================================

.PHONY: all pdf html diagrams clean check docker help watch

BOOK_DIR    := $(shell pwd)
OUTPUT_DIR  := $(BOOK_DIR)/output
BUILD_SH    := $(BOOK_DIR)/build.sh

# Default target
all: check diagrams pdf html
	@echo "Build complete."

pdf:
	@bash $(BUILD_SH) pdf

html:
	@bash $(BUILD_SH) html

diagrams:
	@bash $(BUILD_SH) diagrams

check:
	@bash $(BUILD_SH) check

clean:
	@bash $(BUILD_SH) clean

docker:
	@bash $(BUILD_SH) docker

# Watch mode — rebuild on file change (requires fswatch or inotifywait)
watch:
	@echo "Watching for changes..."
	@if command -v fswatch >/dev/null 2>&1; then \
		fswatch -o $(BOOK_DIR)/chapters $(BOOK_DIR)/diagrams | xargs -n1 -I{} make pdf; \
	elif command -v inotifywait >/dev/null 2>&1; then \
		while inotifywait -r -e modify $(BOOK_DIR)/chapters $(BOOK_DIR)/diagrams; do make pdf; done; \
	else \
		echo "Install fswatch (macOS) or inotify-tools (Linux) for watch mode"; \
		exit 1; \
	fi

# Open PDF after build
open: pdf
	@if [[ "$(shell uname)" == "Darwin" ]]; then \
		open $(OUTPUT_DIR)/enterprise-java-distributed-systems.pdf; \
	else \
		xdg-open $(OUTPUT_DIR)/enterprise-java-distributed-systems.pdf; \
	fi

help:
	@echo ""
	@echo "Enterprise Java & Distributed Systems Engineering — Build Targets"
	@echo "=================================================================="
	@echo ""
	@echo "  make all       — Full build: diagrams + PDF + HTML"
	@echo "  make pdf       — Build PDF only"
	@echo "  make html      — Build HTML only"
	@echo "  make diagrams  — Render Mermaid/PlantUML diagrams"
	@echo "  make check     — Check build dependencies"
	@echo "  make clean     — Remove build artifacts"
	@echo "  make docker    — Build inside Docker"
	@echo "  make watch     — Watch and rebuild on file changes"
	@echo "  make open      — Build and open PDF"
	@echo ""
