# Crisp — convenience wrappers around the existing build scripts.
#
# Fast dev loop (Command Line Tools only, no Xcode):
#   make dev        compile, swap the binary into /Applications/Crisp.app, relaunch
#   make compile    compile the binary only (./Crisp-bin), no swap — quick build check
#   make test       generate the Xcode project and run unit tests
#   make check      lint + tests + localization keys, everything CI enforces: run before pushing
#                   (auto-run on every push after: git config core.hooksPath .githooks)
#
# Distributable DMG:
#   make build      signed universal (arm64 + x86_64) DMG via scripts/release.sh (dry run)
#   make dmg        DMG via Xcode (scripts/build-dmg.sh; needs full Xcode + xcodegen)
#   make release ARGS="vX.Y.Z notes.md --publish"   full release (see scripts/release.sh)
#
#   make clean      remove build artifacts
#   make help       list targets (default)
#
# The dev target honours dev.sh's CRISP_APP override, e.g.:
#   make dev CRISP_APP=/path/to/Crisp.app

# Single source of truth for the version: project.yml (used to tag the dry-run DMG).
VERSION := $(shell grep -E '^[[:space:]]*MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')

# Use Xcode.app's toolchain when installed, even if xcode-select still points at
# the Command Line Tools: xcodebuild (test) and SwiftLint's SourceKit need it.
ifneq (,$(wildcard /Applications/Xcode.app))
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
endif

# swiftc invocation kept in sync with dev.sh's compile step.
SWIFT_SOURCES := Crisp/App/*.swift Crisp/Models/*.swift Crisp/Services/*.swift \
                 Crisp/Views/*.swift Crisp/Utilities/*.swift
SWIFTC_FLAGS := -O -swift-version 5 -strict-concurrency=minimal -parse-as-library \
                -import-objc-header Crisp/Crisp-Bridging-Header.h \
                -framework AppKit -framework SwiftUI -framework IOKit -framework CoreAudio \
                -Xlinker -undefined -Xlinker dynamic_lookup

.DEFAULT_GOAL := help
.PHONY: help dev compile test lint loc-check check build dmg release clean

help:
	@echo "Crisp — make targets:"
	@echo "  make dev        compile + swap into /Applications/Crisp.app + relaunch (dev.sh)"
	@echo "  make compile    compile ./Crisp-bin only, no swap (quick build check)"
	@echo "  make test       generate the Xcode project and run unit tests"
	@echo "  make check      lint + tests + localization keys, everything CI enforces"
	@echo "  make build      signed universal DMG, no Xcode (scripts/release.sh v$(VERSION))"
	@echo "  make dmg        DMG via Xcode (scripts/build-dmg.sh)"
	@echo "  make release ARGS=\"vX.Y.Z notes.md --publish\"   full release (scripts/release.sh)"
	@echo "  make clean      remove build artifacts (Crisp-bin, build/, Crisp.dmg)"

dev:
	./dev.sh

compile:
	@echo "==> Compiling Crisp $(VERSION) -> ./Crisp-bin"
	swiftc $(SWIFTC_FLAGS) $(SWIFT_SOURCES) -o Crisp-bin
	@echo "Done. ./Crisp-bin built (not swapped into the app; use 'make dev' for that)."

# Warnings are errors here (the baseline is zero, issue #47), so a PR that
# introduces one fails make check and CI. `make compile` stays permissive for
# mid-iteration builds.
test:
	xcodegen generate
	xcodebuild -quiet test -project Crisp.xcodeproj -scheme Crisp \
		-destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
		SWIFT_VERSION=5 SWIFT_STRICT_CONCURRENCY=minimal \
		SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

lint:
	@command -v swiftlint >/dev/null || { echo "SwiftLint not installed: brew install swiftlint"; exit 1; }
	swiftlint lint --strict --quiet

# Same check as CI's "Check localization keys" step: every key the code uses
# must exist in the String Catalog (missing keys silently fall back to English).
loc-check:
	xcodegen generate
	xcodebuild -quiet -exportLocalizations -project Crisp.xcodeproj \
		-localizationPath build/loc CODE_SIGNING_ALLOWED=NO \
		SWIFT_EMIT_LOC_STRINGS=YES SWIFT_VERSION=5 SWIFT_STRICT_CONCURRENCY=minimal
	python3 scripts/check-localization-keys.py build/loc/en.xcloc \
		Crisp/Resources/Localizable.xcstrings scripts/i18n-missing-allowlist.txt

# Everything CI enforces (lint + build + tests + localization keys), locally.
check: lint test loc-check
	@echo "check passed: lint clean, tests green, localization keys complete"

build:
	./scripts/release.sh v$(VERSION)

dmg:
	./scripts/build-dmg.sh

release:
	./scripts/release.sh $(ARGS)

clean:
	rm -f Crisp-bin Crisp.dmg
	rm -rf build
	@echo "Cleaned: Crisp-bin, Crisp.dmg, build/"
