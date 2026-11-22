# ReMTP for macOS

Native two-pane app (SwiftUI shell, AppKit file lists). macOS 14+, Xcode 16.4, Swift 6.1 in Swift 5 mode.

```sh
scripts/build-macos-core.sh  # from the repo root: Rust static library + Swift bindings
cd apps/macos
xcodegen generate            # ReMTP.xcodeproj is generated and git-ignored
xcodebuild -project ReMTP.xcodeproj -scheme ReMTP -configuration Debug -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/ReMTP-*/Build/Products/Debug/ReMTP.app   # add --args --demo for simulated devices
```

With `--demo`, the sidebar shows a DEMO badge and the Debug menu can simulate `ptpcamerad` holding a device
or a cable being unplugged. Sync (toolbar button, Transfer › Sync…, sidebar sync pairs) previews placeholder data
and only shows in demo runs (`AppModel.showsSync`) until the sync engine exists.

## Layout

```
ReMTP/
  App/        ReMTPApp (scene, AppDelegate, backend factory), AppModel (state + every action), AppCommands (menus)
  Service/    DeviceService.swift: the remtp-ffi contract as Swift protocols and app-level types
              DemoDeviceService / DemoTransfer / DemoLibrary: demo backend (DEMO ONLY)
  Model/      PaneModel (one pane: location, listing, sort, history, drag hover), TransferCenter (queue, progress,
              issues), DeviceSession, Locations (known devices, device names, defaults domains), LocalFileSystem
              (+ directory watcher), FileItem/kinds, drag items, DropTargets (where a drop goes),
              SyncPreviewDemo (placeholder sync pairs and plans, DEMO ONLY)
  Views/      MainWindow, Sidebar, Toolbar, Pane (the list, column browser and icon grid as NSViewRepresentables,
              their shared keys / context menu / drags / inline rename in PaneInteraction, path bar, footer,
              device access prompt), Transfers (bar, drawer, speed graph), Inspector, Sync (preview sheet)
  Support/    Format, Thumbnails (QuickLookThumbnailing), QuickLookController, off-main helpers,
              DebugSnapshots (DEBUG only)
scripts/make-icon.swift   renders the placeholder app icon
```

## Backends

`DeviceService` maps 1:1 onto `remtp-ffi` (the table at the top of `Service/DeviceService.swift` lists every
pair). The Swift types use app-level names (`DeviceRef`, `StorageRef`, `FileEntry`, `TransferJobSpec`, …) so
they don't clash with the generated UniFFI types.

- `RustDeviceService` (default) wraps the generated bindings in `Generated/` and the static library in
  `Frameworks/RemtpFFI.xcframework`. Build both first with `scripts/build-macos-core.sh` from the repo root.
- `DemoDeviceService` simulates two file-transfer devices and a Pixel that starts in charging-only mode.
  Launch with `--demo` (or set the `UseDemoDevices` default) to use it.

`DeviceServiceFactory.make()` in `App/ReMTPApp.swift` picks between them; no view knows which one runs.

Demo runs and the self-check share the real app's bundle id, so they keep known devices and device names in
their own defaults domain, `io.github.cro13.ReMTP.demo`, and don't autosave window, sidebar or column layout.
With the Rust backend, the app drops known devices with demo ids at launch (older demo runs wrote them into
the real domain).

## Views

Each pane shows its folder as a list (`FileTable`, NSTableView), columns (`FileColumns`, one NSTableView per
folder level) or icons (`FileIconGrid`, NSCollectionView with QuickLook thumbnails and status badges). The
toolbar control and View › as List / Columns / Icons (⌘1 / ⌘2 / ⌘3) switch the active pane; each pane remembers
its mode (`viewMode.mac` / `viewMode.device` in the app's defaults, the demo domain in demo runs). All three use
the same selection model: commands act on `PaneModel.targetItems`. In columns the open folder is the deepest
selected folder (the pane's location, which the path bar shows); with nothing selected inside it, commands act
on that folder itself. ← / → move between columns.

The list's columns are Name, a status symbol, Date Modified, Size and Kind. The status column compares each
item with the folder open in the other pane and only marks what there is to say (same, different, queued,
copying); an item that isn't there has no mark. Its header shows the other side's symbol, and the words
("Not in “Lisbon 2026” on Galaxy S23") are in the tooltip and the inspector. Narrow panes hide Kind first
(under 640 pt), then Date Modified (under 480 pt), so names keep their width. Only rows that exist are striped.

The path bar starts with a location pill (the Mac's volume or home folder, or the device and its storage),
filled with the accent colour in the active pane; on a device with several storages it is the storage menu.
The folders below it are the crumbs.

## Drag and drop

Drops go into the pane's open folder unless they land `.on` a folder row or folder icon (that row or icon
highlights; between rows or icons, on a file or below them the whole list or grid highlights). In columns, a
drop anywhere else in a column goes into that column's folder (the open folder for the last one). While a drag the open folder accepts is over a pane,
a bar under the list ("Drop here to copy into “Albums”") is an always-there target for it, and every path bar
segment takes drops (the pill: the root folder; earlier segments: that folder). Resting on a folder row for a second opens it. The rules
for what a drop does are in `AppModel.dropOperation`; device rows can't be dropped back onto the device (the
core has no on-device move or copy).

## Self-check (Debug builds)

`REMTP_SNAPSHOT_DIR=/tmp/shots REMTP_SNAPSHOT_MAC_PATH="$(mktemp -d)" …/ReMTP.app/Contents/MacOS/ReMTP` runs a
scripted demo. It prints PASS/FAIL for keyboard, rename, new-folder and copy checks, device names, drop-target
resolution and drops (simulated through AppKit's dragging-destination calls, so the table and the SwiftUI drop
bar and path bar are covered), list / columns / icons (switching in both panes, ⌘1–3, remembering, opening
folders, arrow keys between columns, type-select and rename in icons, drops on folder icons and column rows),
Sync showing only with the demo backend, delete revalidation, Finder promises, unplugging mid-transfer, ptpcamerad restore
on eject/unplug, USB mode switching and selection, transfer issue rows and the demo defaults domain, and writes
PNGs of each screen (including the charging-only prompt in light and dark). It starts from
empty demo defaults. The app renders its own windows, so Screen Recording permission isn't needed. It writes, renames
and deletes demo files in the given Mac folder, so it only takes an empty folder (or one an earlier run used: it leaves
a hidden `.remtp-selfcheck` marker there) and fails at once otherwise. Every check prints a line starting with
`PASS` or `FAIL`; if any printed `FAIL`, the app exits with status 1 when it is done, so scripts and CI can rely
on the exit code.

With `REMTP_SNAPSHOT_SCREENS=1` as well, it skips most checks and only writes the screens the README and docs
show (main window, inspector, device access, transfers; light and dark). Those screens run the demo backend but
show the app as it ships: no Sync (toolbar, Transfer menu, sidebar pairs), no DEMO badge, and the home folder
labelled "Home" instead of the account name (`AppModel.presentsAsShipping`, Debug builds only).
`design/app-shots.sh [path/to/ReMTP.app]` runs that and copies exactly the canonical set,
`design/screenshots/{01-main,03-transfers,05-inspector,06-access}-{light,dark}.png`; run it after changing how
those screens look. Mockups of screens that aren't built yet (sync, Windows) are rendered by `design/render.sh`
to `design/mockup/renders/`, apart from the app's own shots.
