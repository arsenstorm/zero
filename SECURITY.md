# Security policy

## Reporting a vulnerability

If you find a security vulnerability in Zero, don't open a public issue, discussion or pull request. Report it
privately through GitHub's private vulnerability reporting:

https://github.com/arsenstorm/zero/security/advisories/new

A useful report has:

- what the vulnerability is and what an attacker could do with it
- steps to reproduce it, or a proof of concept
- the Zero version (in Settings) or commit, your macOS version, and the agent CLI involved, if any
- logs or screenshots, with tokens, keys and personal data removed
- how to reach you with questions

Reports about these are especially welcome:

- **Sign-ins.** Zero keeps the agent CLIs' sign-ins in the macOS Keychain and hands each CLI only its own when it
  starts. Anything that lets a sign-in leak (to a log, another process, another CLI, the network) is in scope.
- **The relay and the iPhone app.** The phone and the Mac talk end to end encrypted (Noise) through a relay that should
  learn nothing but each Mac's token hash. Anything that lets the relay, or anyone on the path, read or forge frames,
  or pair a phone without the user, is in scope.
- **zerod's socket and the zero CLI**, which agents call: anything that lets one agent, a drop folder or a web page act
  as another, or approve its own requests.
- **The browser extension**, which lets agents act in the user's browser tabs.

## What happens next

You'll get a reply as soon as the report is read, and updates as it's worked on. Please don't disclose the issue
publicly until it's fixed or a mitigation is out; we'll agree on a date together. Reporters are credited in the
advisory unless they'd rather not be.

## Supported versions

Fixes go into the latest release; Zero updates itself, so there are no older lines to patch.
