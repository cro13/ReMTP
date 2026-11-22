# Releasing

Releases are macOS only for now; the Rust core keeps building and testing on Windows in CI.

Merging to `main` never releases. Bump the version, then push a version tag; GitHub Actions builds
everything and creates a **draft** release:

```sh
# version in the root Cargo.toml (the CLI's --version) and MARKETING_VERSION in apps/macos/project.yml
cargo update --workspace   # the workspace crates' versions in Cargo.lock
git tag v0.1.1 && git push origin v0.1.1
```

The release build takes the app's version from the tag.

A tag run needs all five signing secrets below. If any is missing it fails in the first job, before any
macOS build, and `scripts/ci/sign-macos.sh` refuses to package a tag build that isn't Developer ID signed
and notarized. A manual run (**Actions → Release → Run workflow** on a branch) works without secrets for a
dry run: the app is ad-hoc signed, nothing is notarized, no release is created, and the packages are the
run's artifacts.

Artifacts:
- `ReMTP-<version>-macos-arm64.dmg` (Apple Silicon) and `ReMTP-<version>-macos-x86_64.dmg` (Intel):
  `ReMTP.app`, an Applications link, `LICENSE.txt` and `THIRD_PARTY_LICENSES.txt`
- `remtp-cli-<version>-macos-{arm64,x86_64}.tar.gz`: a `remtp-cli-<version>-macos-<arch>/` folder with
  `remtp`, `LICENSE.txt` and `THIRD_PARTY_LICENSES.txt`
- `SHA256SUMS.txt`

Before publishing the draft:

1. The first time, and after changing signing: run the workflow manually with the secrets set and check
   that both architectures sign, notarize and staple.
2. Download a DMG from the draft, install it, and with a real device check listing, a copy each way,
   Release/Restore of `ptpcamerad`, and an ADB USB-mode switch (the first switch creates ReMTP's key in the
   login Keychain under the signed app's identity).
3. Check `SHA256SUMS.txt` against the downloads, then publish the draft.

## What the pipeline does

The build job (`scripts/ci/build-macos.sh`) has no access to any secret. It builds the app and the CLI,
then writes the license notices (below) into `ReMTP.app/Contents/Resources` and next to the CLI. A
separate job receives only that output, imports the certificate and runs `scripts/ci/sign-macos.sh`:

1. signs the app (hardened runtime) and the CLI with the Developer ID certificate;
2. notarizes both in one submission, staples the ticket to the app, and checks it with
   `xcrun stapler validate` and `spctl --assess --type execute`. The CLI is a bare Mach-O, which can't
   be stapled: Gatekeeper looks its ticket up online the first time it runs;
3. builds the DMG (app, Applications link, license files), then signs, notarizes and staples it, and
   checks it with `codesign --verify --strict`, `xcrun stapler validate` and `spctl --assess --type open`;
4. packs the CLI tarball.

A notarization that Apple doesn't accept fails the job and prints the notary log.

## License notices

The app statically links the Rust crates of `remtp-ffi` and the CLI those of `remtp-cli`. Their licenses
(MIT, Apache-2.0, BSD, Zlib, Unicode-3.0 and, for the `uniffi` crates, MPL-2.0, which also asks us to say
where their source is) ship as `THIRD_PARTY_LICENSES.txt` in every artifact. They are generated at build
time from the crates in the build, so they never go stale:

```sh
scripts/third-party-licenses.py --package remtp-ffi --output /tmp/app-licenses.txt   # the app
scripts/third-party-licenses.py --package remtp-cli --output /tmp/cli-licenses.txt   # the CLI
```

The script lists `cargo tree -e normal` for each macOS target (no dev-dependencies, no build-script
dependencies) and copies each crate's own LICENSE/COPYING/NOTICE files from the cargo registry. It fails
on a license outside its accepted list, and on a crate without a license file unless that crate is in
`NO_LICENSE_FILE` with a reason: the `uniffi` crates are published without one, so the script uses
`scripts/licenses/MPL-2.0.txt`, the LICENSE of uniffi-rs at v0.32.2. When a dependency update adds a
license or a crate like that, the build fails until the script's lists are updated.

## Signing and notarization (one-time setup)

You need a paid Apple Developer Program membership and two credentials.

**A Developer ID Application certificate.** An "Apple Development" or "Apple Distribution" certificate
can't sign apps distributed outside the App Store; Gatekeeper rejects them.
1. On a Mac, open Keychain Access → Certificate Assistant → Request a Certificate From a Certificate
   Authority, enter your email, choose "Saved to disk". This creates the private key in your keychain.
2. In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list),
   add a certificate of type **Developer ID Application** (G2 Sub-CA) and upload the request. Only the
   team's **Account Holder** can create Developer ID certificates.
3. Download the certificate and double-click it to add it to your login keychain. In Keychain Access →
   My Certificates, check that "Developer ID Application: Your Name (TEAMID)" shows a private key under it.
4. Right-click it → Export, as a `.p12` with a strong password. Keep the `.p12` and the password safe
   (a password manager), and delete the exported file after setting the secrets.

**An App Store Connect API key** for `notarytool`. In [App Store Connect](https://appstoreconnect.apple.com/access/integrations/api)
→ Users and Access → Integrations → App Store Connect API, create a **Team Key** with the "Developer"
role. Note the key ID and the issuer ID, and download `AuthKey_<id>.p8` (it can be downloaded only once).

Then add the secrets under **Settings → Secrets and variables → Actions**:

| Secret | What it is |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | The Developer ID Application certificate + private key (.p12), base64-encoded |
| `MACOS_CERTIFICATE_PASSWORD` | The password you set when exporting the .p12 |
| `NOTARY_KEY_ID` | The App Store Connect API key ID |
| `NOTARY_ISSUER_ID` | The issuer ID shown above the keys |
| `NOTARY_KEY_P8_BASE64` | The downloaded `AuthKey_<id>.p8`, base64-encoded |

With the GitHub CLI:

```sh
base64 -i DeveloperID.p12 | gh secret set MACOS_CERTIFICATE_P12_BASE64 -R cro13/ReMTP
gh secret set MACOS_CERTIFICATE_PASSWORD -R cro13/ReMTP
gh secret set NOTARY_KEY_ID -R cro13/ReMTP
gh secret set NOTARY_ISSUER_ID -R cro13/ReMTP
base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_KEY_P8_BASE64 -R cro13/ReMTP
```

To try them before tagging, run the Release workflow manually: with all five set it signs and notarizes
exactly like a tag build, without creating a release.

## Local release build

```sh
scripts/ci/build-macos.sh "$(uname -m)" 0.1.0
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/ci/sign-macos.sh "$(uname -m)" 0.1.0
```

Leave `SIGNING_IDENTITY` unset for an ad-hoc signed build. To notarize as well, set `NOTARY_KEY_ID`,
`NOTARY_ISSUER_ID` and `NOTARY_KEY_P8_BASE64` (all three, or none). Output goes to `dist/`.
