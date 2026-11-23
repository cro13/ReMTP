# Contributing to ReMTP

Thanks for helping. The most valuable contributions right now are **device reports** (does it work with
your phone, tablet or player, and how fast?) and focused fixes.

## Ground rules

- Be kind; see the [Code of Conduct](CODE_OF_CONDUCT.md).
- Open an issue before large changes so we can agree on the approach.
- Security problems: follow [SECURITY.md](SECURITY.md), not public issues.

## Setup

- Xcode 16.4+ (Swift 6.1; needs macOS 15.3 or later to run, while the app targets macOS 14+), [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Rust via [rustup](https://rustup.rs). `rust-toolchain.toml` pins the version; rustup installs it automatically.

```sh
cargo fmt --all
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
scripts/build-macos-core.sh           # add --release and --arch arm64|x86_64 as needed
cd apps/macos && xcodegen generate && xcodebuild -scheme ReMTP -configuration Debug build
```

Run the app's self-check before a pull request that touches the app. It uses the demo backend, prints
`PASS`/`FAIL` lines and writes screenshots (the Mac folder must be empty: the run writes, renames and
deletes files in it):

```sh
REMTP_SNAPSHOT_DIR=/tmp/shots REMTP_SNAPSHOT_MAC_PATH="$(mktemp -d)" <Debug build>/ReMTP.app/Contents/MacOS/ReMTP
```

The app talks to the Rust core only through `remtp-ffi`. If you change that API, update
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and the Swift adapter in the same pull request.

## Testing with devices

- Unit and integration tests use an in-memory transport, so `cargo test` needs no device.
- With a device connected (unlocked, USB mode "File transfer"):
  `cargo run --locked -p remtp-cli --release -- bench 0 <storage-id> /Download/remtp-bench --files 100 --size-mb 30`
  prints MB/s, average time per file, device wait and idle time. Paste the output into a
  [device report](https://github.com/cro13/ReMTP/issues/new?template=device_report.yml).
- If macOS's `ptpcamerad` holds the device, `remtp access 0` shows who has it and `remtp release 0`
  frees it (reversed by `remtp restore`).

## Dependencies

- Direct Rust dependencies are pinned exactly in the root `Cargo.toml`.
- Only add or bump to versions published at least 7 days ago, and say why in the pull request.
- No new dependency for something a few lines of code can do.

## Pull requests

- One topic per pull request, with a short description of the why and how you tested it.
- CI must pass: Rust formatting, clippy with warnings as errors and tests on macOS (arm64) and Windows
  (the core stays cross-platform); the macOS app build for arm64 and Intel; and the app's self-check on
  arm64, which fails on any `FAIL` line.
- Keep UI changes consistent with the existing screens in `design/` and attach a screenshot. Leave
  `design/screenshots/` alone: after a change to the app lands on main, the "Screenshots" workflow renders
  those screens again and commits the ones that changed.
- Commit messages: imperative mood, focused on why ("Avoid re-listing folders after each upload").

## Project layout

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/DESIGN.md](docs/DESIGN.md).

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
