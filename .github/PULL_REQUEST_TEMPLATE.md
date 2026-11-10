<!--
Thanks for opening a pull request. Fill in each section; write `n/a` with a one-line reason where one doesn't apply.

Don't disclose a security vulnerability, or a fix for one, in a public pull request: follow SECURITY.md first.
-->

## Summary

<!-- What changes, in two or three sentences or up to three bullets: what someone using Zero notices. -->

## Why

<!-- The reason. Link issues with `Closes #NN` or `Related: #NN`. -->

## Test plan

<!-- What you checked. Tick what you ran; say what you couldn't check. -->

- [ ] `make lint` (rustfmt, clippy with no warnings, swift-format, Biome)
- [ ] `cargo test -p zerod` (a zerod change starts with a failing test in `crates/zerod/tests/integration/`)
- [ ] `swift test --package-path apps/macos`
- [ ] `bun run build` in `site/`, if the site changed
- [ ] Tried in the app (what you did and saw), or n/a

## Notes

<!-- Optional: compatibility, follow-ups, anything a reviewer should know. -->

- [ ] I have signed the [Contributor License Agreement](../CLA.md) (the CLA bot asks on your first pull request).
