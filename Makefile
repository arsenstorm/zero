SIGN  ?= locus-dev
MACOS  = apps/macos
APP    = build/Zero.app
BIN    = $(MACOS)/.build/release
LINUX  = x86_64-unknown-linux-musl aarch64-unknown-linux-musl

build: drop ghostty zerod
	swift build -c release --package-path $(MACOS)

# zerod, Zero's daemon (crates/zerod): owns agent sessions whether or not the app is open.
zerod:
	cargo build --release -p zerod

# Ghostty's terminal engine (libghostty-vt), built from Ghostty's own source at a pinned commit with Zig
# (brew install zig). Only the macOS slice is kept, as $(MACOS)/Vendor/GhosttyVt.xcframework (not in git).
GHOSTTY_COMMIT = f54340ad77814fe319d136e5e915d6a48de8dd23
GHOSTTY_SRC    = $(MACOS)/Vendor/ghostty-src
GHOSTTY        = $(MACOS)/Vendor/GhosttyVt.xcframework
ghostty: $(GHOSTTY)
$(GHOSTTY):
	mkdir -p $(MACOS)/Vendor
	[ -d $(GHOSTTY_SRC) ] || git clone -q https://github.com/ghostty-org/ghostty.git $(GHOSTTY_SRC)
	cd $(GHOSTTY_SRC) && git fetch -q --depth 1 origin $(GHOSTTY_COMMIT) && git checkout -q $(GHOSTTY_COMMIT)
	cd $(GHOSTTY_SRC) && zig build -Demit-lib-vt=true -Doptimize=ReleaseFast
	rm -rf $@
	xcodebuild -create-xcframework -library $(GHOSTTY_SRC)/zig-out/lib/ghostty-vt.xcframework/macos-arm64_x86_64/libghostty-vt.a \
		-headers $(GHOSTTY_SRC)/zig-out/lib/ghostty-vt.xcframework/macos-arm64_x86_64/Headers -output $@ >/dev/null

# Static drop clients for the folders Zero watches (crates/zero-drop): Linux via musl + rust-lld, no C toolchain needed.
drop:
	cargo build -q --profile drop -p zero-drop
	for target in $(LINUX); do \
		cargo build -q --profile drop -p zero-drop --target $$target --config "target.$$target.linker=\"rust-lld\"" || exit 1; \
	done

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN)/ZeroApp $(APP)/Contents/MacOS/Zero
	cp $(BIN)/zero $(APP)/Contents/MacOS/zero-cli
	cp $(BIN)/zero-host $(APP)/Contents/MacOS/zero-host
	cp $(MACOS)/Resources/Info.plist $(APP)/Contents/Info.plist
	cp $(MACOS)/Resources/icons/*.png $(APP)/Contents/Resources/
	cd $(MACOS)/Resources && cp AppIcon.icns logo/menubar.png logo/menubar@2x.png logo/mark.svg logo/mark-small.svg $(CURDIR)/$(APP)/Contents/Resources/
	cp -R plugin $(APP)/Contents/Resources/plugin
	cp target/drop/zero-drop $(APP)/Contents/Resources/zero-drop-darwin-arm64
	cp target/x86_64-unknown-linux-musl/drop/zero-drop $(APP)/Contents/Resources/zero-drop-linux-x86_64
	cp target/aarch64-unknown-linux-musl/drop/zero-drop $(APP)/Contents/Resources/zero-drop-linux-aarch64
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
	cargo test --workspace
	swift test --package-path $(MACOS)

.PHONY: build zerod ghostty drop bundle install run test
