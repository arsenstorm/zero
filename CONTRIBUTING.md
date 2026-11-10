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

[README.md](README.md) explains how to build Zero and how its tests are laid out. In short:

- Changes to the daemon (`crates/zerod`) start with a failing test in `crates/zerod/tests/integration/`.
- Before opening a pull request, run `cargo test -p zerod`, `cargo clippy -p zerod --all-targets` (no warnings) and
  `swift test --package-path apps/macos`.
- Commit messages are one line: `type(scope): message`, under 72 characters.
