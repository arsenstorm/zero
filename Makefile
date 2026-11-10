# Signed as a Developer ID when there is one (what other Macs need), else as Apple Development. Updates install only
# when signed as the running build is, so keep to one.
identity = $(shell security find-identity -v -p codesigning | grep -m1 -o '"$(1)[^"]*"' | tr -d '"')
ifndef SIGN
SIGN := $(or $(call identity,Developer ID Application),$(call identity,Apple Development))
endif
VERSION = $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' $(MACOS)/Resources/Info.plist)
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
	cp $(BIN)/zero-full $(APP)/Contents/MacOS/zero-full
	cp $(BIN)/zero-host $(APP)/Contents/MacOS/zero-host
	cp target/release/zerod $(APP)/Contents/MacOS/zerod
	cp $(MACOS)/Resources/Info.plist $(APP)/Contents/Info.plist
	cp $(MACOS)/Resources/install.sh $(APP)/Contents/Resources/install.sh
	cp $(MACOS)/Resources/icons/*.png $(APP)/Contents/Resources/
	cd $(MACOS)/Resources && cp AppIcon.icns logo/menubar.png logo/menubar@2x.png logo/mark.svg logo/mark-small.svg $(CURDIR)/$(APP)/Contents/Resources/
	cp -R $(MACOS)/Resources/nucleo $(APP)/Contents/Resources/nucleo
	cp /System/Library/Sounds/*.aiff $(APP)/Contents/Resources/
	cp -R plugin $(APP)/Contents/Resources/plugin
	rm -rf $(APP)/Contents/Resources/chrome && cp -R apps/chrome $(APP)/Contents/Resources/chrome
	rm -rf $(APP)/Contents/Resources/firefox && cp -R apps/chrome $(APP)/Contents/Resources/firefox && mv $(APP)/Contents/Resources/firefox/manifest.firefox.json $(APP)/Contents/Resources/firefox/manifest.json
	cp target/drop/zero-drop $(APP)/Contents/Resources/zero-drop-darwin-arm64
	cp target/x86_64-unknown-linux-musl/drop/zero-drop $(APP)/Contents/Resources/zero-drop-linux-x86_64
	cp target/aarch64-unknown-linux-musl/drop/zero-drop $(APP)/Contents/Resources/zero-drop-linux-aarch64
	codesign --force --sign "$(SIGN)" $(APP)/Contents/Resources/zero-drop-darwin-arm64
	codesign --force --sign "$(SIGN)" $(APP)/Contents/MacOS/zero-cli
	codesign --force --sign "$(SIGN)" $(APP)/Contents/MacOS/zero-full
	codesign --force --sign "$(SIGN)" $(APP)/Contents/MacOS/zero-host
	codesign --force --sign "$(SIGN)" $(APP)/Contents/MacOS/zerod
	codesign --force --sign "$(SIGN)" $(APP)

# The app quits and opens again where you were; zerod, only when it changed, restarts gracefully (install.sh).
install: bundle
	@sh $(MACOS)/Resources/install.sh $(APP) $$(cmp -s target/release/zerod build/zerod.installed && echo keep || echo restart)
	@cp target/release/zerod build/zerod.installed

# A GitHub release of the version in Info.plist (raise it first), from HEAD as pushed: Zero's updater offers it.
release: bundle
	git merge-base --is-ancestor HEAD origin/main || { echo "Push HEAD first"; exit 1; }
	ditto -c -k --keepParent $(APP) build/Zero.zip
	gh release create v$(VERSION) build/Zero.zip --target $$(git rev-parse HEAD) --title "Zero $(VERSION)" --generate-notes

run: install

test:
	cargo test --workspace
	swift test --package-path $(MACOS)

.PHONY: build zerod ghostty drop bundle install release run test
