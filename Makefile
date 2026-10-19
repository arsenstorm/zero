SIGN ?= locus-dev
APP   = build/Zero.app
BIN   = .build/release

build:
	swift build -c release

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp $(BIN)/ZeroApp $(APP)/Contents/MacOS/Zero
	cp $(BIN)/zero $(APP)/Contents/MacOS/zero-cli
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign "$(SIGN)" $(APP)/Contents/MacOS/zero-cli
	codesign --force --sign "$(SIGN)" $(APP)

install: bundle
	pkill -x Zero || true
	rm -rf /Applications/Zero.app
	cp -R $(APP) /Applications/Zero.app
	ln -sf /Applications/Zero.app/Contents/MacOS/zero-cli $(HOME)/.local/bin/zero

run: install
	open /Applications/Zero.app

test:
	swift test

.PHONY: build bundle install run test
