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
	cp target/release/zerod $(APP)/Contents/MacOS/zerod
	cp $(MACOS)/Resources/Info.plist $(APP)/Contents/Info.plist
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
	codesign --force --sign "$(SIGN)" $(APP)/Contents/MacOS/zero-host
	codesign --force --sign "$(SIGN)" $(APP)/Contents/MacOS/zerod
	codesign --force --sign "$(SIGN)" $(APP)

# The app quits and opens again straight away, where you were. zerod, only when it changed, restarts gracefully: turns
# under way pause between steps (a running command finishes first), the new zerod takes over and they carry on.
install: bundle
	@changed=$$(cmp -s target/release/zerod build/zerod.installed && echo no || echo yes); \
	pid=$$(ps -axo pid=,comm= | awk '$$2 == "/Applications/Zero.app/Contents/MacOS/Zero" {print $$1}'); \
	[ -z "$$pid" ] || kill $$pid; \
	for i in $$(seq 1 50); do [ -n "$$pid" ] && ps -p $$pid >/dev/null 2>&1 || break; sleep 0.1; done; \
	rm -rf /Applications/Zero.app; \
	cp -R $(APP) /Applications/Zero.app; \
	mkdir -p $(HOME)/.local/bin && ln -sf /Applications/Zero.app/Contents/MacOS/zero-cli $(HOME)/.local/bin/zero; \
	cp target/release/zerod build/zerod.installed; \
	if [ $$changed = yes ] && printf '{"op":"restart"}\n' | nc -U $(HOME)/.zero/zerod.sock 2>/dev/null | grep -q restarting; then \
		echo "zerod: restarting as the new build, the agents running on through it"; \
	fi; \
	open -g /Applications/Zero.app

run: install

test:
	cargo test --workspace
	swift test --package-path $(MACOS)

.PHONY: build zerod ghostty drop bundle install run test
