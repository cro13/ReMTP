# OpenMTP engine harness

This small Go program produced the OpenMTP numbers in [docs/BENCHMARKS.md](../../docs/BENCHMARKS.md). It runs
OpenMTP's transfer engine without OpenMTP's Electron UI and records when each file finishes.

## What it measures

- **Engine:** `github.com/ganeshrvel/go-mtpx@18f12db` + `github.com/ganeshrvel/go-mtpfs@1c3302b`. These are the
  versions linked into OpenMTP 3.3.0's `kalam.dylib` (checked with `strings`).
- **Call sequence:** the same as OpenMTP's Kalam FFI (`ffi/kalam/native/kalam.go` and `helpers.go`):
  `Initialize` + `FetchDeviceInfo`, `FetchStorages`, `MakeDirectory`, then `UploadFiles` or `DownloadFiles` with
  `preprocessFiles = true` (OpenMTP's default), then `Dispose`. Like Kalam's `verifyMtpSession`, it calls
  `FetchDeviceInfo` before each operation.
- **Not included:** OpenMTP's UI. The harness doesn't marshal JSON to JavaScript, poll progress every 500 ms,
  render anything, show an overwrite prompt or refresh the listing. It measures the engine alone, not the full
  app.
- **Published times** are wall time, from process start to exit (`timed.sh`), so they include opening the
  device, finding the storage and creating the folder. The JSONL log (`-log`) has a timestamp for each file.

## Build

Needs Go, `pkg-config` and Homebrew's `libusb`. `build.sh` writes its output to `out/`.

```sh
./build.sh stock homebrew    # SP3000 run: stock engine, Homebrew libusb (1.0.30 at the time)
./build.sh stock openmtp     # Lenovo run: stock engine, the libusb.dylib copied from /Applications/OpenMTP.app
./build.sh zlpfix openmtp    # Lenovo run, "engine with the fix" column (NOT OpenMTP 3.3.0)
```

The `openmtp` option copies OpenMTP 3.3.0's bundled `libusb.dylib` (recorded as libusb 1.0.24) into `out/`,
changes its install name, ad-hoc signs it and links the harness against it, so the tablet sees the same USB
stack as in the real app. Headers come from Homebrew.

`third_party/go-mtpfs/` is go-mtpfs at `1c3302b` (BSD license, see its `LICENSE`) with one added file,
`mtp/select_vendor.go`. That file lets the harness pick a device by USB vendor ID without opening the other MTP
devices on the bus. Nothing else in the module has changed.

## Run

```sh
cp env.example.sh env.sh   # set DEV, S and the path to remtp, then:
source env.sh && pre
./gen-data.sh "$D"         # A = 100 x 30 MB, B = 1,000 x 1 MB, C = 2 x 1.5 GB of random data
$R mkdir "$DEV" "$S" "$B"
$T openmtp-A 1800 out/openmtp-bench-stock-homebrew upload -log "$L/openmtp-A.jsonl" \
  -storage "$S" -mkdir "$B/openmtp" -dest "$B/openmtp" "$D/A"
$V openmtp-A "$B/openmtp/A" 100 30000000
$T remtp-A 1800 "$R" push "$D/A" "$DEV" "$S" "$B/remtp"
$V remtp-A "$B/remtp/A" 100 30000000
$X cleanup "$B"            # deletes only inside the bench folder
```

Each helper exits non-zero when its step fails (`timed.sh`: the command's status, 124 if it was killed;
`verify.sh`: 1 unless the folder checks out; `saferm.sh`: the delete's status), so a script can stop
before cleanup and keep the evidence. Runs alternated between the two tools with a 10 s pause between them.
Downloads use
`openmtp-bench download -storage "$S" -dest <local dir> <device folder>` and `remtp pull`, and were checked
with `shasum -a 256 -c` against `A.sha256`.

Without `-vendor`, the harness opens the device with go-mtpx's own `Initialize`, as OpenMTP does. That needs
exactly one MTP device on the bus. With a second device connected (as in the Lenovo run), pass
`-vendor 0x17ef` (and optionally `-match <regexp>` on "manufacturer product serial"). The device is then
opened and configured the way `mtpx.Initialize` does it.

## The ZLP fix

On the Lenovo Tab TB311FU (Android 16), every upload with the stock engine fails after about 31 s with
`LIBUSB_ERROR_TIMEOUT`, and no bytes are written (OpenMTP issue #411). `bulkWrite` in go-mtpfs ends each data
phase with a zero-length packet (ZLP) when the last transfer was a whole number of USB packets. When the whole
payload fits in the first (header) packet, as with `SendObjectInfo`, the loop that tracks the last transfer
never runs, so its length stays 0 and the engine sends a ZLP that isn't needed. The tablet then stops
answering.

`zlpfix.patch` records the header packet's length, so the ZLP is only sent when it should be. It is a
3-line diagnostic patch to show what the engine could do with that bug fixed. **A build with it is not
OpenMTP 3.3.0**, and the benchmark tables label it that way.
