/// Zero Dev: a build for testing Zero beside the user's own (`-Xswiftc -DZERO_DEV`, never in a release). It keeps its
/// state in ~/.zero-dev, talks only to its own zerod (ZERO_DAEMON), and leaves out what is the user's Zero's alone:
/// moving to /Applications, the LaunchAgent, the login item, the updater, the hot key, the menu bar item, launching
/// zerod and taking focus at launch.
public enum DevBuild {
    #if ZERO_DEV
        public static let on = true
    #else
        public static let on = false
    #endif
}
