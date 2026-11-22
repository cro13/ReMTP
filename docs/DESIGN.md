# ReMTP design

Open-source macOS app for moving files of any kind between a Mac and any Android device
(phones, tablets, Android-based DAPs). It is a Path Finder-grade two-pane file manager with
folder sync. Media files get richer previews, but nothing in the core is music-specific.

Screens: `design/screenshots/` holds shots of the macOS app with its demo devices (main window, transfers,
inspector, device access; `design/app-shots.sh`). Sync and Windows are mockups of what isn't built yet, in
`design/mockup/renders/` (`design/render.sh`; all mockup screens are in `design/mockup/`). The sample data is a trip's
photos and a music library; the same screens apply to DCIM, Download, Documents, backups and so on.

## Decisions

| Topic | Decision |
| --- | --- |
| Scope | Any Android device over USB; any file type; music, photo and video awareness is a layer on top |
| Product | Two-pane file manager (Mac pane + device pane) with folder sync pairs and diff preview |
| Transports | MTP for every device; ADB as an opt-in faster connection; Wi-Fi only for convenience |
| Device access | Show which process holds the device; one-click, opt-in release of `ptpcamerad`; always restore |
| Core | Rust: `mtp-rs` (MIT/Apache-2.0) for MTP, `remtp-adb` (the project's own direct-USB client) or an existing adb server for ADB |
| UI | Native per platform on one Rust core: macOS first (SwiftUI shell + AppKit lists, UniFFI), Windows later (native, same core) |
| License | MIT |
| Signing | Developer ID signed and notarized macOS builds |
| Platform | macOS 14+ (Intel and Apple Silicon builds), then Windows 10/11 with the same UX. mtp-rs uses Windows' own WPD stack, so no driver is needed |
| Distribution | Developer ID signed and notarized DMG plus Homebrew cask; not the Mac App Store |

Rejected: Apple's camera framework (ImageCaptureCore), which doesn't see Android in MTP mode
(Comprador's tests on macOS 26.4); FSKit mounting, which needs macOS 26+; Electron;
USB Mass Storage (gone from modern Android); a companion app on the device (for now).

## Why OpenMTP was slow, and what that means for ReMTP

The "10–20 s per file" in OpenMTP was a host-side bug, not MTP itself. Its USB layer
(`go-mtpfs` `bulkWrite`) sent a zero-length packet after each file's data and waited for the full
device timeout. Users saw the data arrive fast and then a ~15 s stall per file
(openmtp#308, #353). OpenMTP 3.2.20 (Apr 2024) capped the wait at 250 ms, so up to a quarter
second per file is still lost.

What a correct MTP implementation costs per file (SolidFerry's published measurements, `docs/QUIRKS.md`):

| Device | Per-file upload overhead | Large-file upload |
| --- | --- | --- |
| Galaxy S23, USB 3 | 22 ms (direct write), 39 ms (temp name + rename) | ~325 MB/s |
| Lenovo Tab P11 | ~42 ms | — |
| Any device on USB 2.0 | — | ~35–42 MB/s (link limit) |

Part of that overhead is on the device: Android's MTP server runs a blocking `MediaStore.scanFile`
on every received file before it replies (`MtpServer::doSendObject` → `MtpDatabase.endSendObject`).
Every MTP client pays this, so ReMTP has to measure it per device.

**Target:** 100 files of ~30 MB are dominated by bytes, not overhead. That's ~0.1–0.2 s per file on a
USB 3 link, and ~0.8 s per file on USB 2.0, plus tens of milliseconds of overhead per file.

## Transports

| | MTP | ADB | Wi-Fi (FTP / wireless ADB) |
| --- | --- | --- | --- |
| Availability | Every Android device, no setup | Needs Developer options → USB debugging + RSA prompt; hidden on some OEM builds (A&K DAPs) | Needs a server on the device (AK File Drop) or wireless debugging |
| Concurrency | One operation at a time per session | Multiplexed streams (≈3 concurrent was best in SolidFerry's tests) | — |
| Small files (10k files, 1.1 GB) | Upload 49–75 ms per file; download 136 s | Upload 28 ms per file; download 10 s | — |
| Large files (S23, USB 3) | Upload ~325 MB/s | Upload ~180 MB/s; download ~300 MB/s | 2–30× slower than USB 2.0 |
| Dates | Dropped by some devices (Samsung) | Preserved | — |
| macOS | PTP-class interface, grabbed by `ptpcamerad` | Separate vendor interface; not contested by `ptpcamerad` | No USB issues |

Policy:
- **MTP is always available and must be excellent on its own.**
- **ADB is opt-in per device**, even if the device is already authorized. When both are available, the
  planner picks per job: ADB for downloads and many small files, MTP for large uploads. Measure
  the whole job, not the throughput display. One transport mutates a tree at a time.
- **adb ownership:** if a local adb server is running (e.g. Android Studio), go through it; otherwise
  connect directly over USB. Never both, and never kill another tool's server. Keys that ReMTP
  creates live in the Keychain.
- **MediaStore consistency:** ADB writes skip MTP's scan hook. Trigger a rescan after a job and
  invalidate cached listings; test that adds, replacements and deletes show up.
- **Wi-Fi** is a convenience (AK File Drop is FTP to internal storage only, on trusted networks), never
  the speed path.
- **No tar bundling, no companion app** for now. Small-file cost is dominated by per-file opens through
  FUSE on the device, so bundling didn't help in SolidFerry's tests.

## USB modes

Android picks its USB function on the device (File transfer, charging only, PTP, MIDI, tethering), and
most devices go back to charging only on every replug. In charging-only mode there's no MTP interface,
so an MTP client can't see the device or ask it to change.
- **With USB debugging on**, the device is still on USB with its ADB interface alone. ReMTP lists it
  ("Charging only") and switches it to File transfer and back over ADB (`svc usb setFunctions mtp`, and
  with no function for charging only), following the adb ownership rule above. This is the first use of
  ADB and works before the ADB transport exists.
- The device then leaves USB and comes back with a different USB product ID, so its id changes with the
  mode. The app matches the two by vendor and serial: one sidebar row, one custom name.
- **Per device:** "Switch to Charging Only on Eject", for devices that shouldn't stay in file transfer.
- **Without USB debugging** the device stays invisible until the user picks File transfer on it. The
  empty state says how: the "Charging this device via USB" notification → File transfer, or Developer
  options → Default USB configuration → File transfer to make it stick.
- **Approval:** the first command from a new key makes the device ask "Allow USB debugging?". Through
  the adb server that's the server's key; directly over USB it's ReMTP's own key (Keychain).

## MTP done right (engine rules)

1. Send a zero-length packet only when the USB/MTP spec requires it, and never block on a timeout.
2. Plan with bulk `GetObjectPropList` (1,500 files in 0.16 s vs 2.0 s with per-file `GetObjectInfo`).
3. Never re-list a folder after each file (that makes folder copies quadratic). Update the cached tree
   locally and from device events.
4. Write new files directly; use temp name + rename (+~17 ms) only to replace existing files safely.
5. Read ahead on the Mac (parallel disk reads and hashing into a bounded buffer).
6. Use adaptive chunk sizes: small while the user is browsing, large otherwise.
7. Claim the interface on connect and explain contention (`ptpcamerad`, Photos, other apps).
8. Show effective MB/s, idle time between files and the negotiated USB link speed.

## Architecture

```
ReMTP.app (Swift, AppKit + SwiftUI)
  └─ UniFFI bindings
remtp-core (Rust)
  ├─ transport  trait Transport { list, stat, read, write, mkdir, rename, delete, events }
  │    ├─ mtp   mtp-rs session actor, quirk table, interface acquisition
  │    ├─ adb   adb server or direct USB, N concurrent sync streams, shell (stat, hash, rescan)
  │    └─ ftp   later
  ├─ access     IORegistry exclusive-owner lookup; ptpcamerad suppress/restore with crash recovery
  ├─ tree       cached object tree per storage
  ├─ transfer   planner (picks transport per job) + read-ahead pipeline + persisted queue
  ├─ sync       Mac scan → manifest diff → plan (add/update/conflict/device-only/unchanged)
  ├─ names      FAT32/exFAT rules, NFC normalization, case-fold collisions, recorded name mapping
  ├─ quirks     per-vendor/per-device behaviors (dates dropped, handles, link drops), with tests
  └─ store      SQLite manifest per device + storage
remtp-cli (Rust)  benchmarks, device reports, scripting
```

## Per-device behaviour (no profiles)

There are no device profiles: any device is used as plain storage for any file type. Differences between
devices are detected, not configured. On first connect ReMTP probes each storage:
- whether file dates survive an upload;
- whether bulk listing works;
- whether files over 4 GB are accepted;
- whether interrupted uploads can resume;
- whether ADB is available.

It also reads whether a storage is removable. The engine uses the results: compare by size + checksum
when dates are dropped, card-safe names on removable storages, and a warning before a file that's too
large. The user never has to pick a device type.

## UX

Mockups: two panes, transfers, sync preview, inspector, device access, Windows. They are unchanged in structure from v1, generalized:
- **Kind column** instead of Format: "FLAC 24/192", "JPEG 4032×3024", "PDF", "Folder".
- **Inspector by type:** audio (tracks, tags), image (preview, EXIF), video (frame, duration,
  codec), other (size, dates, checksum).
- **Sync pairs** work for any folder (camera roll → Mac, Documents ↔ tablet, music → DAP).
- **Device row** shows the connection: "USB 3 · MTP" (later "USB 3 · ADB"), or "Charging only" with
  Switch to File Transfer (see USB modes).
- **Keyboard and drag and drop** as before (Tab switches panes, Space Quick Look, F5 / ⌘⇧→ copy to
  other pane).

## Device support (open source means "any Android")

- Test matrix: the A&K SP3000 (MTP only), at least one Samsung, one Pixel, one low-end tablet.
  Run both USB 2 and USB 3 links.
- The device report issue template asks for `remtp info` (device, storages, link speed) and `remtp bench`
  (throughput, per-file overhead) output, so contributors can add devices without owning them all.
- CI runs the Rust tests against an in-memory transport and the app's self-check with the demo backend;
  quirk entries come with regression tests. Testing against mtp-rs's virtual device mode is planned.

## Phases

The plan as written before the first release. 0.1 ships phase 0 and most of phase 1 (no persistent queue
and no sync yet), plus Quick Look and the inspector from phase 2; the README lists what's in it.

0. **Benchmark spike (gate).** `remtp-cli bench` with 100 × 30 MB files and 1,000 × 200 KB files,
   up and down, on each test device. It measures per-file phases (SendObjectInfo, data, response wait
   = device-side scan, host gap) for MTP, and sequential vs concurrent streams for ADB. Run the same
   set through current OpenMTP for comparison. Defaults come from the numbers.
1. **MVP.** Two panes, copy both ways over MTP, persistent queue, transfer drawer, device access flow,
   add-and-update sync with preview.
2. ADB transport, inspector by type, Quick Look, mirror deletes, name-mapping review, AK File Drop.
3. Playlists for DAPs, Universal build, Finder integration on macOS 26+.

## Prior art

- **SolidFerry** (MIT, Swift, MTP + ADB, created Nov 2026, one author): single-window browser;
  two-way sync is an open question; no two-pane. Its `docs/QUIRKS.md` is the best public set of
  measurements, so ReMTP should reuse its findings as test cases.
- **Cmdr** (BSL, Tauri + mtp-rs): two-pane general file manager with MTP and ADB (beta).
- **Comprador** (GPL-3): Finder mount via a loopback NFS server.
- **OpenMTP** (MIT, Electron + Go).

ReMTP is justified by the two-pane workflow, reliable folder sync and verified DAP support, not
by speed alone.

## Open questions

- Exact DAP model and firmware; microSD card file system (FAT32 vs exFAT).
