# ReMTP

Open-source MTP file manager. Rust core (`crates/`) + native apps (`apps/macos` now, `apps/windows` later).
Read `docs/DESIGN.md` (product), `docs/ARCHITECTURE.md` (code layout and the FFI contract) and
`docs/RELEASING.md` (release pipeline) first.

## Commands

- Rust: `cargo fmt --all`, `cargo clippy --workspace --all-targets --locked -- -D warnings`, `cargo test --workspace --locked`
- Windows check from a Mac: `cargo clippy --workspace --all-targets --locked --target x86_64-pc-windows-msvc -- -D warnings`
- CLI: `cargo run -p remtp-cli -- devices` (also `info`, `ls`, `push`, `pull`, `mkdir`, `rm`, `usb-mode`, `bench`, `access`, `release`, `restore`)
- macOS app: `scripts/build-macos-core.sh` (Rust static lib + Swift bindings into `apps/macos/Generated` and
  `apps/macos/Frameworks`, both git-ignored), then `cd apps/macos && xcodegen generate && xcodebuild -scheme ReMTP -configuration Debug build`.
  Launch with `--demo` for simulated devices.
- App self-check (Debug, demo backend, prints PASS/FAIL and writes screenshots):
  `REMTP_SNAPSHOT_DIR=/tmp/shots REMTP_SNAPSHOT_MAC_PATH="$(mktemp -d)" <app>/Contents/MacOS/ReMTP`
  (the Mac folder must be empty: the run writes, renames and deletes files in it)
- Release dry run: `scripts/ci/build-macos.sh "$(uname -m)" 0.0.1 && scripts/ci/sign-macos.sh "$(uname -m)" 0.0.1` (ad-hoc without `SIGNING_IDENTITY`)
- License notices: `scripts/third-party-licenses.py --package remtp-ffi --output /tmp/licenses.txt` (or
  `--package remtp-cli`); `scripts/ci/build-macos.sh` generates and bundles them.
- Screenshots: `design/app-shots.sh` writes the app's own screens (main, transfers, inspector, access) to
  `design/screenshots/` from a Debug build with the demo backend (needs a 2x screen). The "Screenshots" workflow
  does the same on CI, on a 2x virtual display (`scripts/ci/virtual-display.m`), after app changes land on main
  (or by hand) and commits the PNGs when a screen changed; don't commit them by hand. `design/render.sh` renders the mockups of what isn't built yet
  (sync, Windows) from `design/mockup/` to `design/mockup/renders/` (headless Chrome).

## Rules

- Dependencies: pin direct deps exactly in the root `Cargo.toml`; only versions published 7+ days ago. After
  `cargo update`, check new transitive versions' publish dates too. Their licenses must be in `ACCEPTED` in
  `scripts/third-party-licenses.py`, or the release build fails.
- The apps only talk to `remtp-ffi`. Keep its API in sync with `docs/ARCHITECTURE.md`.
- Toolchain: Rust 1.95 (`rust-toolchain.toml`), Xcode 16.4 / Swift 6.1, macOS 14+ deployment target.
- CI: keep macOS jobs lean; macOS runners are the slowest and scarcest.
