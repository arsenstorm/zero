import Foundation

/// What Zero places in every drop folder: static `zero-drop` binaries per platform, built from `crates/zero-drop/`
/// in this repository, and a three-line `zero` shim that picks the right one. The binaries speak the `zero` CLI
/// contract over files: `asks/<id>.json` in, `answers/<id>.json` back.
public enum DropClient {
    /// Resource names in the app bundle, by `uname -s | tr A-Z a-z`-`uname -m`.
    public static let binaries = ["zero-drop-linux-x86_64", "zero-drop-linux-aarch64", "zero-drop-darwin-arm64"]

    public static let shim = """
    #!/bin/sh
    # zero — placed here by Zero.app. Runs the static client for this machine; see crates/zero-drop/ in the Zero repo.
    exec "$(dirname "$0")/zero-drop-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)" "$@"
    """
}
