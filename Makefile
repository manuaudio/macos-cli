INSTALL_DIR := $(shell go env GOPATH)/bin

.PHONY: build install clean test

build:
	swift build -c release

install: build
	cp .build/release/apple-cli $(INSTALL_DIR)/apple
	@echo "Installed to $(INSTALL_DIR)/apple"

clean:
	swift package clean

test: install
	@echo "--- reminders lists ---"
	apple reminders lists --json
	@echo "--- calendar events (today) ---"
	apple calendar events --from $(shell date +%Y-%m-%d) --to $(shell date +%Y-%m-%d) --json
	@echo "--- contacts search ---"
	apple contacts search "test" --json || true
