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
# The icons are the only difference between official builds and builds from source. Official builds bundle the
# licensed Nucleo icons from the private zero-private repo (a checkout beside this one, or ZERO_PRIVATE=path); without
# it, the closest Lucide icons (ISC) in $(MACOS)/Resources/lucide. The app shows which in Settings (ZeroIcons).
ZERO_PRIVATE ?= ../zero-private
ICONS     = $(if $(wildcard $(ZERO_PRIVATE)/icons/macos/*.svg),Nucleo,Lucide)
ICONS_DIR = $(if $(filter Nucleo,$(ICONS)),$(ZERO_PRIVATE)/icons/macos,$(MACOS)/Resources/lucide)

# zerod and the app side by side: each is mostly one long single-threaded step, so together they take the longer's time.
build:
	@cargo build --release -p zerod & zerod=$$!; swift build -c release --package-path $(MACOS); app=$$?; wait $$zerod && exit $$app

# zerod, Zero's daemon (crates/zerod): owns agent sessions whether or not the app is open.
zerod:
	cargo build --release -p zerod

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN)/ZeroApp $(APP)/Contents/MacOS/Zero
	cp $(BIN)/zero $(APP)/Contents/MacOS/zero-cli
	cp $(BIN)/zero-full $(APP)/Contents/MacOS/zero-full
	cp target/release/zerod $(APP)/Contents/MacOS/zerod
	cp $(MACOS)/Resources/Info.plist $(APP)/Contents/Info.plist
	cp $(MACOS)/Resources/install.sh $(APP)/Contents/Resources/install.sh
	mkdir -p $(APP)/Contents/Library/LaunchAgents
	cp $(MACOS)/Resources/com.arsen.zero.zerod.plist $(APP)/Contents/Library/LaunchAgents/
	cp $(MACOS)/Resources/icons/*.png $(APP)/Contents/Resources/
	cd $(MACOS)/Resources && cp AppIcon.icns logo/menubar.png logo/menubar@2x.png logo/mark.svg logo/mark-small.svg $(CURDIR)/$(APP)/Contents/Resources/
	@echo "Icons: $(ICONS), from $(ICONS_DIR)"
	cp -R $(ICONS_DIR) $(APP)/Contents/Resources/icons
	/usr/libexec/PlistBuddy -c 'Add :ZeroIcons string $(ICONS)' $(APP)/Contents/Info.plist
	cp /System/Library/Sounds/*.aiff $(APP)/Contents/Resources/
	cp -R plugin $(APP)/Contents/Resources/plugin
	rm -rf $(APP)/Contents/Resources/chrome && cp -R apps/chrome $(APP)/Contents/Resources/chrome
	rm -rf $(APP)/Contents/Resources/firefox && cp -R apps/chrome $(APP)/Contents/Resources/firefox && mv $(APP)/Contents/Resources/firefox/manifest.firefox.json $(APP)/Contents/Resources/firefox/manifest.json
	$(CODESIGN) $(APP)/Contents/MacOS/zero-cli
	$(CODESIGN) $(APP)/Contents/MacOS/zero-full
	$(CODESIGN) $(APP)/Contents/MacOS/zerod
	SIGN="$(SIGN)" SIGNFLAGS="$(SIGNFLAGS)" apps/browser/helper.sh $(CURDIR)/$(APP) com.arsen.zero.browser "Zero Browser"
	$(CODESIGN) $(APP)

# The app quits and opens again where you were; zerod, only when it changed, restarts gracefully (install.sh).
install: bundle
	@sh $(MACOS)/Resources/install.sh $(APP) $$(cmp -s target/release/zerod build/zerod.installed && echo keep || echo restart)
	@cp target/release/zerod build/zerod.installed

# The disk image people download, from build/Zero.app as it is (apps/macos/dmg: the layout, its background and how
# it's drawn). dmgbuild, pinned with hashes in a virtual environment of its own, writes Finder's layout without
# AppleScript, so CI's headless Macs make the same one. Unsigned here; CI signs, notarises and staples it
# (`codesign --sign "$(SIGN)" --timestamp build/Zero.dmg` signs one by hand).
DMGBUILD = build/dmgbuild/bin/dmgbuild
$(DMGBUILD): $(MACOS)/dmg/requirements.txt
	rm -rf build/dmgbuild
	python3 -m venv build/dmgbuild
	build/dmgbuild/bin/pip install -q --require-hashes -r $<
dmg: $(DMGBUILD)
	@[ -d $(APP) ] || { echo "No $(APP): run make bundle first"; exit 1; }
	rm -f build/Zero.dmg
	$(DMGBUILD) -s $(MACOS)/dmg/settings.py -D app=$(APP) Zero build/Zero.dmg

# The update for a Zero that has this release's Chromium already: the app as it is (stapled, in CI) without CEF's
# framework, about a tenth of Zero.zip. The updater puts the installed Zero's framework in and checks the seal
# (Updates.download); a Zero with another Chromium downloads Zero.zip. Not a .zip: updaters before it take the only one.
CEF_FRAMEWORK = Contents/Helpers/Zero Browser.app/Contents/Frameworks/Chromium Embedded Framework.framework
slim:
	rm -rf build/slim build/Zero.slim && mkdir build/slim
	ditto $(APP) build/slim/Zero.app
	rm -rf "build/slim/Zero.app/$(CEF_FRAMEWORK)"
	cd build/slim && ditto -c -k --keepParent Zero.app ../Zero.slim
	rm -rf build/slim

# Releases are built, signed, notarised and published by CI (.github/workflows/release.yml, docs/releasing.md) from a
# pushed tag: raise the version in Info.plist (X.Y.Z), commit and push, then `make release` tags HEAD and pushes the tag.
release:
	git merge-base --is-ancestor HEAD origin/main || { echo "Push HEAD first"; exit 1; }
	git tag -s v$(VERSION) -m "Zero $(VERSION)"
	git push origin v$(VERSION)

run: install

# Zero Dev (apps/macos/scripts/dev.sh): Zero built for testing beside the user's own, in build-dev/, with its own
# zerod, state (~/.zero-dev) and Zero Browser; started in the background, never taking focus.
dev:
	@$(MACOS)/scripts/dev.sh && $(MACOS)/scripts/dev-run.sh start

dev-stop:
	@$(MACOS)/scripts/dev-run.sh stop

# Zero Dev's end-to-end checks (DevE2E): built, run, stopped; the results in build-dev/e2e/results.md.
# One run at a time: Zero Dev and build-dev are shared, so a second run waits for the first.
e2e:
	@mkdir -p build-dev && lockf -k build-dev/e2e.lock $(MACOS)/scripts/e2e.sh

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

.PHONY: build zerod bundle dmg slim install release run dev dev-stop e2e test setup format lint
