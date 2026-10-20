APP := build/Build/Products/Release/ohmydiff.app
# `make run` builds ohmydiff Dev: its own name, bundle identifier and data, the blueprint app icon, no ohmydiff://
# links and no updates, so it runs beside the installed app.
DEV_APP := build/dev/Build/Products/Release/ohmydiff Dev.app
# Code signing identity (name or SHA-1 from `security find-identity -v -p codesigning`). Ad-hoc by default.
SIGN_IDENTITY := $(OHMYDIFF_SIGN_IDENTITY)
# The commit count, like releases, so a local build is never offered the release it was built from.
BUILD_NUMBER := $(shell git rev-list --count HEAD)

.PHONY: build dev run install test compat compat-record clean large-diff release publish

build:
	xcodebuild -project ohmydiff.xcodeproj -scheme ohmydiff -configuration Release \
		-destination 'platform=macOS,arch=$(shell uname -m)' -derivedDataPath build -quiet \
		CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) build
ifneq ($(SIGN_IDENTITY),)
	scripts/sign.sh $(APP) "$(SIGN_IDENTITY)"
endif

dev:
	xcodebuild -project ohmydiff.xcodeproj -scheme ohmydiff -configuration Release \
		-destination 'platform=macOS,arch=$(shell uname -m)' -derivedDataPath build/dev -quiet \
		CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) APP_NAME='ohmydiff Dev' APP_BUNDLE_ID=dev.koby.ohmydiff.dev \
		APP_INFOPLIST=Config/Info-Dev.plist APP_ICON=AppIcon-Dev build
ifneq ($(SIGN_IDENTITY),)
	scripts/sign.sh "$(DEV_APP)" "$(SIGN_IDENTITY)"
endif

run: dev
	-pkill -x 'ohmydiff Dev'; while pgrep -x 'ohmydiff Dev' >/dev/null; do sleep 0.1; done
	open "$(DEV_APP)"

install: build
	-pkill -x ohmydiff; while pgrep -x ohmydiff >/dev/null; do sleep 0.1; done
	rm -rf /Applications/ohmydiff.app
	cp -R $(APP) /Applications/ohmydiff.app
	open /Applications/ohmydiff.app

test:
	cd OhMyDiffCore && swift test

# Contract tests against the installed `but`; `compat-record` then stores its version as known-good.
compat:
	cd OhMyDiffCore && OHMYDIFF_REQUIRE_BUT=1 swift test --filter 'ButContract|ButCompatibility|ButLive|ButStatus|GitButler'

compat-record: compat
	scripts/but-compat.sh record

# make release VERSION=1.1.0: notarized universal build of origin/main plus the appcast (see scripts/release.sh).
release:
	scripts/release.sh $(VERSION)

# make publish VERSION=1.1.0: the GitHub release that installed copies update from.
publish:
	scripts/publish.sh $(VERSION)

# Throwaway repository with large uncommitted changes, for scroll and highlighting checks.
large-diff:
	scripts/large-diff.sh

clean:
	rm -rf build OhMyDiffCore/.build
