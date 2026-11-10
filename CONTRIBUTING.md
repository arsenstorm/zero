# Contributing to Zero

Thank you for helping. Zero is free software under the [GNU General Public License, version 3 or later](LICENSE).

## The Contributor License Agreement

Before your first pull request can be merged, you sign the [Contributor License Agreement](CLA.md). You keep the
copyright in what you write; the agreement gives the maintainer a license to use and distribute it, including under
other licenses, which keeps Zero free to change its license or offer it on other terms later.

You sign once, on your first pull request: a bot comments with a link to the agreement, and you reply with

> I have read the CLA Document and I hereby sign the CLA

It covers all your later contributions. If you contribute as part of your job, check first that your employer allows
it (section 4 of the agreement).

## Working on Zero

[README.md](README.md) explains how to build Zero and how its tests are laid out. Once per clone, run

```sh
make setup
```

It sets up the pre-commit hook in `.githooks/`, which formats what you stage (Rust with rustfmt, Swift with
swift-format, the site, relay and browser extension with Biome) and stages the result, and installs Biome (needs
[Bun](https://bun.sh)). `make format` formats everything at once. For `git blame` to skip the commits that only
reformatted the code, also run `git config blame.ignoreRevsFile .git-blame-ignore-revs`.

In short:

- Changes to the daemon (`crates/zerod`) start with a failing test in `crates/zerod/tests/integration/`.
- Before opening a pull request, run `make lint` (formatting, and `cargo clippy` with no warnings),
  `cargo test -p zerod` and `swift test --package-path apps/macos`. CI runs the same.
- Commit messages are one line: `type(scope): message`, under 72 characters.

Found a security issue? Don't open an issue: [SECURITY.md](SECURITY.md) explains how to report it privately. Everyone
taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).
