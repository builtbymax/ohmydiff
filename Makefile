APP := build/Build/Products/Release/ohmydiff.app

.PHONY: build run install test clean

build:
	xcodebuild -project ohmydiff.xcodeproj -scheme ohmydiff -configuration Release \
		-destination 'platform=macOS,arch=$(shell uname -m)' -derivedDataPath build -quiet build

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
