# Signed as a Developer ID when there is one (what other Macs need), else as Apple Development. Updates install only
# when signed as the running build is, so keep to one.
identity = $(shell security find-identity -v -p codesigning | grep -m1 -o '"$(1)[^"]*"' | tr -d '"')
ifndef SIGN
SIGN := $(or $(call identity,Developer ID Application),$(call identity,Apple Development))
endif
# With the hardened runtime, as notarisation requires. CI adds a secure timestamp (SIGNFLAGS=--timestamp), which asks
# Apple's server for every binary, so local builds skip it.
CODESIGN = codesign --force --options runtime $(SIGNFLAGS) --sign "$(SIGN)"
VERSION = $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' $(MACOS)/Resources/Info.plist)
MACOS  = apps/macos
APP    = build/Zero.app
BIN    = $(MACOS)/.build/release
LINUX  = x86_64-unknown-linux-musl aarch64-unknown-linux-musl
# The icons are the only difference between official builds and builds from source. Official builds bundle the
# licensed Nucleo icons from the private zero-private repo (a checkout beside this one, or ZERO_PRIVATE=path); without
# it, the closest Lucide icons (ISC) in $(MACOS)/Resources/lucide. The app shows which in Settings (ZeroIcons).
ZERO_PRIVATE ?= ../zero-private
ICONS     = $(if $(wildcard $(ZERO_PRIVATE)/icons/macos/*.svg),Nucleo,Lucide)
ICONS_DIR = $(if $(filter Nucleo,$(ICONS)),$(ZERO_PRIVATE)/icons/macos,$(MACOS)/Resources/lucide)

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
	@echo "Icons: $(ICONS), from $(ICONS_DIR)"
	cp -R $(ICONS_DIR) $(APP)/Contents/Resources/icons
	/usr/libexec/PlistBuddy -c 'Add :ZeroIcons string $(ICONS)' $(APP)/Contents/Info.plist
	cp /System/Library/Sounds/*.aiff $(APP)/Contents/Resources/
	cp -R plugin $(APP)/Contents/Resources/plugin
	rm -rf $(APP)/Contents/Resources/chrome && cp -R apps/chrome $(APP)/Contents/Resources/chrome
	rm -rf $(APP)/Contents/Resources/firefox && cp -R apps/chrome $(APP)/Contents/Resources/firefox && mv $(APP)/Contents/Resources/firefox/manifest.firefox.json $(APP)/Contents/Resources/firefox/manifest.json
	cp target/drop/zero-drop $(APP)/Contents/Resources/zero-drop-darwin-arm64
	cp target/x86_64-unknown-linux-musl/drop/zero-drop $(APP)/Contents/Resources/zero-drop-linux-x86_64
	cp target/aarch64-unknown-linux-musl/drop/zero-drop $(APP)/Contents/Resources/zero-drop-linux-aarch64
	$(CODESIGN) $(APP)/Contents/Resources/zero-drop-darwin-arm64
	$(CODESIGN) $(APP)/Contents/MacOS/zero-cli
	$(CODESIGN) $(APP)/Contents/MacOS/zero-full
	$(CODESIGN) $(APP)/Contents/MacOS/zero-host
	$(CODESIGN) $(APP)/Contents/MacOS/zerod
	$(CODESIGN) --entitlements $(MACOS)/Resources/Zero.entitlements $(APP)

# The app quits and opens again where you were; zerod, only when it changed, restarts gracefully (install.sh).
install: bundle
	@sh $(MACOS)/Resources/install.sh $(APP) $$(cmp -s target/release/zerod build/zerod.installed && echo keep || echo restart)
	@cp target/release/zerod build/zerod.installed

# Releases are built, signed, notarised and published by CI (.github/workflows/release.yml, docs/releasing.md) from a
# pushed tag: raise the version in Info.plist (X.Y.Z), commit and push, then `make release` tags HEAD and pushes the tag.
release:
	git merge-base --is-ancestor HEAD origin/main || { echo "Push HEAD first"; exit 1; }
	git tag -s v$(VERSION) -m "Zero $(VERSION)"
	git push origin v$(VERSION)

run: install

test:
	cargo test --workspace
	swift test --package-path $(MACOS)

# Once per clone: the pre-commit hook (.githooks: formats what's staged) and the JavaScript formatter.
setup:
	git config core.hooksPath .githooks
	bun install

SWIFT_SOURCES = $(MACOS)/Package.swift $(MACOS)/Sources $(MACOS)/Tests $(MACOS)/scripts apps/ios

# Formats everything: Rust (rustfmt.toml), Swift (.swift-format), the site, relay and extension (biome.jsonc).
format:
	cargo fmt --all
	swift format --in-place --recursive --parallel $(SWIFT_SOURCES)
	bun run format

# What CI checks, short of the tests.
lint:
	cargo fmt --all --check
	cargo clippy -p zerod --all-targets -- -D warnings
	swift format lint --strict --recursive --parallel $(SWIFT_SOURCES)
	bun run format:check

.PHONY: build zerod ghostty drop bundle install release run test setup format lint
