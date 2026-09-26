# macos-cli — build / test / release helpers.
#
# The previous `install` target copied a Go-era product (a differently named
# binary that this repo no longer builds) into a Go toolchain bin directory,
# and the previous `test` target shelled out to the installed binary to read
# live Reminders / Calendar / Contacts data. Neither the product nor the Go
# toolchain assumption exists any more, so both are retired: installation is
# owned by install.sh (which signs and verifies), and `test` is hermetic.

SHELL := /bin/bash

.PHONY: build install install-adhoc test test-swift test-installer stage clean help

help:
	@echo "make build          — release build"
	@echo "make test           — hermetic tests (Swift core + installer contract)"
	@echo "make install        — build, sign (Developer ID) and install via install.sh"
	@echo "make install-adhoc  — same, contributor ad-hoc signature (permissions reset on rebuild)"
	@echo "make stage          — build + sign a staging artifact and record its hashes (no install)"
	@echo "make clean          — swift package clean + drop dist/staging"

build:
	swift build -c release

# Installation, signing and verification live in one place: install.sh.
# MACOS_CLI_SIGN_IDENTITY (or ~/.config/macos-cli/signing.env) must be set.
install:
	./install.sh

install-adhoc:
	MACOS_CLI_SIGN_MODE=adhoc ./install.sh

test: test-swift test-installer

test-swift:
	swift run MacCLICoreTestRunner

test-installer:
	bash scripts/tests/installer_contract_test.sh

stage:
	./scripts/stage-release.sh

clean:
	swift package clean
	rm -rf dist/staging
