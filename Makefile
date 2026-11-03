CONFIGURATION ?= release
APP := dist/harnessmd.app

.PHONY: all build run demo test self-test package appcast icon ci help

all: build

build:
	CONFIGURATION="$(CONFIGURATION)" sh build.sh

# `open` only activates an instance that is already running, so quit any first.
run: build
	@if pgrep -qx HarnessApp; then \
		osascript -e 'tell application id "md.harnessmd.app" to quit' >/dev/null 2>&1 || true; \
		for attempt in 1 2 3 4 5 6 7 8 9 10; do pgrep -qx HarnessApp || break; sleep 0.5; done; \
		pkill -x HarnessApp || true; \
	fi
	open "$(APP)"

demo: build
	open -n "$(APP)" --args --demo

test:
	swift test --no-parallel

ci:
	bash scripts/ci.sh

package:
	bash scripts/package-app.sh

appcast:
	bash scripts/make-appcast.sh

# Rerun after editing the artwork; the build copies the committed .icns.
icon:
	swift scripts/make-icon.swift Support/AppIcon.svg Support/AppIcon.icns

self-test: build
	"$(APP)/Contents/MacOS/HarnessApp" --self-test

help:
	@printf '%s\n' 'make              Build and ad-hoc sign the release app' 'make run          Build and launch the app' 'make demo         Build and launch isolated fixture data' 'make test         Run unit tests' 'make ci           Run the CI checks locally' 'make package      Build ZIP and DMG (requires SPARKLE_PUBLIC_ED_KEY)' 'make appcast      Sign the feed (requires SPARKLE_ED_PRIVATE_KEY)' 'make icon         Render Support/AppIcon.svg into Support/AppIcon.icns' 'make self-test    Build and run the packaged fixture self-test' 'make build CONFIGURATION=debug    Build a debug app'
