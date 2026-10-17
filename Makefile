APP := build/Build/Products/Release/ohmydiff.app
# Code signing identity (name or SHA-1 from `security find-identity -v -p codesigning`). Ad-hoc by default.
SIGN_IDENTITY := $(OHMYDIFF_SIGN_IDENTITY)

.PHONY: build run install test clean

build:
	xcodebuild -project ohmydiff.xcodeproj -scheme ohmydiff -configuration Release \
		-destination 'platform=macOS,arch=$(shell uname -m)' -derivedDataPath build -quiet build
ifneq ($(SIGN_IDENTITY),)
	codesign --force --sign "$(SIGN_IDENTITY)" --options runtime $(APP)
endif

run: build
	-pkill -x ohmydiff; while pgrep -x ohmydiff >/dev/null; do sleep 0.1; done
	open $(APP)

install: build
	-pkill -x ohmydiff; while pgrep -x ohmydiff >/dev/null; do sleep 0.1; done
	rm -rf /Applications/ohmydiff.app
	cp -R $(APP) /Applications/ohmydiff.app
	open /Applications/ohmydiff.app

test:
	cd OhMyDiffCore && swift test

clean:
	rm -rf build OhMyDiffCore/.build
