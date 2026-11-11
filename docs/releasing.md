# Releasing Zero

Releases are made by CI from a pushed tag (`.github/workflows/release.yml`). A tag `vX.Y.Z` does this:

1. The **build** job runs on macOS in the `signing` environment. It builds what `make bundle` builds. It signs every
   binary and the app with the Developer ID certificate, the hardened runtime and a secure timestamp. Then it notarises
   the app with `notarytool`, staples the ticket and zips the app with `ditto -c -k --keepParent`. Then `make dmg`
   puts the stapled app in a disk image, which is signed, notarised and stapled too.
2. The **publish** job runs on Linux in the `release` environment. It signs the zip and the disk image with Sigstore
   (cosign, keyless, through GitHub's OIDC) and attests their SLSA build provenance. Then GoReleaser publishes the GitHub release, with
   notes that GitHub generates.

The release has these files:

| File | What it is |
|---|---|
| `Zero.dmg` | The download for people: the notarised app beside a link to Applications. The website links it. |
| `Zero.zip` | The same app, zipped. Zero's updater installs the release's only `.zip`, so keep it the only one. |
| `Zero.dmg.sha256`, `Zero.zip.sha256` | Their SHA-256, as `shasum -a 256` writes it. |
| `Zero.dmg.sigstore.json`, `Zero.zip.sigstore.json` | Their cosign signature bundles. |
| `Zero.intoto.jsonl` | The SLSA build provenance of both: the same attestation that `gh attestation verify` reads. |

## The disk image

`apps/macos/dmg` holds its layout. `settings.py` sets the window, the icon positions and the Applications link for
[dmgbuild](https://github.com/dmgbuild/dmgbuild), which writes Finder's layout file itself, so CI's headless Macs need
no Finder to script. `make dmg` installs dmgbuild in `build/dmgbuild`, pinned with hashes by `requirements.txt`, and
makes `build/Zero.dmg` from `build/Zero.app` (run `make bundle` first). Locally the disk image is unsigned. To sign
one, run `codesign --sign "Developer ID Application: …" --timestamp build/Zero.dmg`.

The background is Zero's mark and name, very large and faint, as the website's footer draws them. To change it, edit
`background.swift` and run `swift apps/macos/dmg/background.swift`. It writes `background.png` and
`background@2x.png`, and dmgbuild makes them one Retina TIFF.

## Set up once

### The `signing` environment and its secrets

In the repository, go to Settings › Environments › New environment and name it `signing`. Under "Deployment branches
and tags", choose "Selected branches and tags" and add the branch `main` and the tag `v*`. Do not add reviewers, so
rehearsals run without approval. Then add these six environment secrets. The `gh secret set` commands read the value
from stdin, so it doesn't pass through your clipboard or shell history.

**`DEVELOPER_ID_CERTIFICATE`** and **`DEVELOPER_ID_CERTIFICATE_PASSWORD`**: the Developer ID Application certificate
and its private key, as a .p12 file.

1. If you don't have the certificate yet, go to Xcode › Settings › Accounts › your team › Manage Certificates › + ›
   Developer ID Application. Only the team's Account Holder can create one.
2. In Keychain Access › login › My Certificates, find "Developer ID Application: Your Name (TEAMID)". Expand it and
   make sure the private key is under it. Select the certificate, choose File › Export Items…, select Personal
   Information Exchange (.p12) and set a strong password.
3. Run:

   ```sh
   base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_CERTIFICATE --env signing -R arsenstorm/zero
   gh secret set DEVELOPER_ID_CERTIFICATE_PASSWORD --env signing -R arsenstorm/zero   # prompts for the password
   rm DeveloperID.p12
   ```

**`APP_STORE_CONNECT_API_KEY`**, **`APP_STORE_CONNECT_API_KEY_ID`** and **`APP_STORE_CONNECT_API_ISSUER_ID`**: the App
Store Connect API key that `notarytool` uses.

1. Go to App Store Connect › Users and Access › Integrations › App Store Connect API › Team Keys and click +. Name the
   key "Zero notarisation" and give it the **Developer** access. Notarisation needs no more than that.
2. Download `AuthKey_<KEYID>.p8`. You can download it only once. The key ID is in the key's row, and the issuer ID is
   above the table.
3. Run:

   ```sh
   base64 -i AuthKey_<KEYID>.p8 | gh secret set APP_STORE_CONNECT_API_KEY --env signing -R arsenstorm/zero
   gh secret set APP_STORE_CONNECT_API_KEY_ID --env signing -R arsenstorm/zero --body <KEYID>
   gh secret set APP_STORE_CONNECT_API_ISSUER_ID --env signing -R arsenstorm/zero --body <ISSUER-ID>
   ```

   Keep the .p8 somewhere safe, such as a password manager, or revoke the key and make a new one if you lose it.

**`ZERO_PRIVATE_KEY`**: the private half of a read-only deploy key on `arsenstorm/zero-private`, the private repo
with the Nucleo icons official builds carry. A release fails without them rather than ship the Lucide ones.

```sh
ssh-keygen -t ed25519 -N '' -C 'zero release' -f zero-private-key
gh repo deploy-key add zero-private-key.pub -R arsenstorm/zero-private --title 'Zero release'
gh secret set ZERO_PRIVATE_KEY --env signing -R arsenstorm/zero < zero-private-key
rm zero-private-key zero-private-key.pub
```

### The `release` environment

Create a second environment named `release`. Under "Deployment branches and tags", add only the tag `v*`. To approve
each release before it is published, add yourself under "Required reviewers" and clear "Prevent self-review". This
environment has no secrets: the publish job uses the workflow's own token and OIDC.

### Recommended

- In Settings › General › Releases, turn on release immutability. After a release is published, its files can't be
  replaced. GoReleaser supports immutable releases, and Scorecard's Signed-Releases check counts them.
- In Settings › Rules › Rulesets, add a tag ruleset for `v*` that only you can bypass, so nobody else can start a
  release.

### Moving to the Developer ID signature

The updater installs a release only when it's signed as the running Zero is. A Zero signed as Apple Development (by
`make install` without a Developer ID in your keychain) doesn't accept the CI's Developer ID releases. Install the first
CI release by hand: download `Zero.dmg`, open it and drag Zero to Applications, replacing the one there. Then keep the Developer ID
certificate in your login keychain, so that `make install` signs with it too.

## Cut a release

1. Set `CFBundleShortVersionString` in `apps/macos/Resources/Info.plist` to the new version `X.Y.Z`. It must have three
   numbers, because GoReleaser reads the tag as semver. Also increment `CFBundleVersion` by one. Commit and push to
   `main`.
2. Optional: rehearse. In Actions › Release › Run workflow, choose `main`. The run builds, signs and notarises the app,
   and keeps `Zero.zip` and `Zero.dmg` as the run's artifact for 7 days. It publishes nothing.
3. Run `make release`. It makes a signed tag `vX.Y.Z` on HEAD (HEAD must already be on `origin/main`) and pushes the
   tag. If the tag isn't the version in Info.plist, the build job stops.
4. In the run, approve the `release` deployment if you set required reviewers. The release then appears with its
   seven files.

If a run fails before the publish job, nothing was published. Delete the tag (`git push --delete origin vX.Y.Z` and
`git tag -d vX.Y.Z`), fix the problem and tag again.

## Verify a release

```sh
shasum -a 256 -c Zero.dmg.sha256
cosign verify-blob Zero.dmg --bundle Zero.dmg.sigstore.json \
  --certificate-identity https://github.com/arsenstorm/zero/.github/workflows/release.yml@refs/tags/vX.Y.Z \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
gh attestation verify Zero.dmg -R arsenstorm/zero
spctl -a -t open --context context:primary-signature -vv Zero.dmg   # "accepted, source=Notarized Developer ID"
```

The zip verifies the same way, with `Zero.zip` in place of `Zero.dmg`. Its app is checked with
`ditto -x -k Zero.zip . && spctl -a -vv Zero.app`.

## Scorecard

- **Packaging** recognises the GoReleaser step. It passes after one successful run of `release.yml`, and a rehearsal
  also counts.
- **Signed-Releases** looks at the last five releases that have files. It finds the signature by its `.sigstore.json`
  extension and the provenance by its `.intoto.jsonl` extension. A release with provenance (or an immutable release)
  scores 10.
