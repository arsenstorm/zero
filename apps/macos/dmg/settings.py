# dmgbuild's settings for Zero.dmg (`make dmg`, release.yml), run from the repository's root: Zero over the left of its
# faint name, the Applications folder over the right. dmgbuild writes Finder's layout (.DS_Store) itself, so it runs on
# a headless Mac with no Finder to script. -D app=… names the app to put in it.
app = defines.get("app", "build/Zero.app")  # noqa: F821 (dmgbuild's own)

format = "ULFO"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = ["Zero.app"]
icon = "apps/macos/Resources/AppIcon.icns"
# With background@2x.png beside it, made into one Retina TIFF (background.swift draws both).
background = "apps/macos/dmg/background.png"

# The background's size, in points, plus macOS 26's 32 pt title bar (Finder's bounds are the whole window's); toolbar,
# sidebar, status and path bars hidden.
window_rect = ((200, 160), (640, 432))
icon_size = 128
text_size = 13
# Low enough to leave room above them for the words and the arrow between them (background.swift).
icon_locations = {"Zero.app": (200, 210), "Applications": (440, 210)}
