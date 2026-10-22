SIGN ?= locus-dev
APP   = build/Zero.app
BIN   = .build/release

build: drop-client ghostty
	swift build -c release

# Ghostty's terminal engine (libghostty-vt), built from Ghostty's own source at a pinned commit with Zig
# (brew install zig). Only the macOS slice is kept, as Vendor/GhosttyVt.xcframework (not in git).
GHOSTTY_COMMIT = f54340ad77814fe319d136e5e915d6a48de8dd23
GHOSTTY_SRC    = Vendor/ghostty-src
ghostty: Vendor/GhosttyVt.xcframework
Vendor/GhosttyVt.xcframework:
	mkdir -p Vendor
	[ -d $(GHOSTTY_SRC) ] || git clone -q https://github.com/ghostty-org/ghostty.git $(GHOSTTY_SRC)
	cd $(GHOSTTY_SRC) && git fetch -q --depth 1 origin $(GHOSTTY_COMMIT) && git checkout -q $(GHOSTTY_COMMIT)
	cd $(GHOSTTY_SRC) && zig build -Demit-lib-vt=true -Doptimize=ReleaseFast
	rm -rf $@
	xcodebuild -create-xcframework -library $(GHOSTTY_SRC)/zig-out/lib/ghostty-vt.xcframework/macos-arm64_x86_64/libghostty-vt.a \
		-headers $(GHOSTTY_SRC)/zig-out/lib/ghostty-vt.xcframework/macos-arm64_x86_64/Headers -output $@ >/dev/null

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
	cp $(BIN)/zero-host $(APP)/Contents/MacOS/zero-host
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	mkdir -p $(APP)/Contents/Resources
	cp Resources/icons/*.png $(APP)/Contents/Resources/
	cp Resources/AppIcon.icns Resources/logo/menubar.png Resources/logo/menubar@2x.png Resources/logo/mark.svg Resources/logo/mark-small.svg $(APP)/Contents/Resources/
	rm -rf $(APP)/Contents/Resources/plugin && mkdir -p $(APP)/Contents/Resources/plugin
	cp -R .claude-plugin hooks skills $(APP)/Contents/Resources/plugin/
	cp drop-client/target/release/zero-drop $(APP)/Contents/Resources/zero-drop-darwin-arm64
	cp drop-client/target/x86_64-unknown-linux-musl/release/zero-drop $(APP)/Contents/Resources/zero-drop-linux-x86_64
	cp drop-client/target/aarch64-unknown-linux-musl/release/zero-drop $(APP)/Contents/Resources/zero-drop-linux-aarch64
	codesign --force --sign "$(SIGN)" $(APP)/Contents/Resources/zero-drop-darwin-arm64
	codesign --force --sign "$(SIGN)" $(APP)/Contents/MacOS/zero-cli
	codesign --force --sign "$(SIGN)" $(APP)/Contents/MacOS/zero-host
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
