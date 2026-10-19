SIGN ?= locus-dev
APP   = build/Zero.app
BIN   = .build/release

build: drop-client
	swift build -c release

# Static drop clients for the folders Zero watches (see drop-client/): Linux via musl + rust-lld, no C toolchain needed.
drop-client:
	cd drop-client && cargo build --release -q
	cd drop-client && cargo build --release -q --target x86_64-unknown-linux-musl --config 'target.x86_64-unknown-linux-musl.linker="rust-lld"'
	cd drop-client && cargo build --release -q --target aarch64-unknown-linux-musl --config 'target.aarch64-unknown-linux-musl.linker="rust-lld"'

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp $(BIN)/ZeroApp $(APP)/Contents/MacOS/Zero
	cp $(BIN)/zero $(APP)/Contents/MacOS/zero-cli
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	mkdir -p $(APP)/Contents/Resources
	cp drop-client/target/release/zero-drop $(APP)/Contents/Resources/zero-drop-darwin-arm64
	cp drop-client/target/x86_64-unknown-linux-musl/release/zero-drop $(APP)/Contents/Resources/zero-drop-linux-x86_64
	cp drop-client/target/aarch64-unknown-linux-musl/release/zero-drop $(APP)/Contents/Resources/zero-drop-linux-aarch64
	codesign --force --sign "$(SIGN)" $(APP)/Contents/Resources/zero-drop-darwin-arm64
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

.PHONY: build bundle install run test drop-client
