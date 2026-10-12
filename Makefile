# Always build with the full Xcode 27 install, regardless of what xcode-select points at.
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
export PATH := /opt/homebrew/opt/rustup/bin:$(HOME)/.cargo/bin:/opt/homebrew/bin:$(PATH)
export CARGO_TARGET_DIR := $(CURDIR)/tapo-helper/target

PROJECT := GB10PowerMonitor.xcodeproj
SCHEME := GB10PowerMonitor
DERIVED := $(CURDIR)/build
CONFIG ?= Release
APP := $(DERIVED)/Build/Products/$(CONFIG)/GB10PowerMonitor.app
INSTALLED := /Applications/GB10PowerMonitor.app
HELPER := $(CARGO_TARGET_DIR)/aarch64-apple-darwin/release/tapo-helper

.PHONY: bootstrap project helper build test test-helper test-core install run run-sim clean

bootstrap:
	brew list rustup >/dev/null 2>&1 || brew install rustup
	brew list xcodegen >/dev/null 2>&1 || brew install xcodegen
	rustup default stable
	rustup target add aarch64-apple-darwin

project:
	xcodegen generate --spec project.yml --quiet

helper:
	./scripts/build-helper.sh

build: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=arm64' build

test: test-helper test-core

test-helper:
	cd tapo-helper && cargo test --locked

test-core: helper
	TAPO_HELPER_PATH=$(HELPER) swift test --package-path Packages/PowerCore

install: build
	-osascript -e 'tell application id "com.w3joe.GB10PowerMonitor" to quit' >/dev/null 2>&1
	rm -rf "$(INSTALLED)"
	ditto "$(APP)" "$(INSTALLED)"

run: install
	open "$(INSTALLED)"

# Fake plugs and a fake SSH shell, for trying the UI without hardware.
run-sim: build
	open -n "$(APP)" --args --simulate

clean:
	rm -rf $(DERIVED) $(PROJECT)
	cd tapo-helper && cargo clean
