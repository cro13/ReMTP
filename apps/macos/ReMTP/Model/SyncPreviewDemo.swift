import Foundation

// DEMO ONLY — NOT WIRED TO A SYNC ENGINE.
// Sync pairs and sync plans are placeholder data so the sidebar section and the sync preview sheet
// can be designed and reviewed. Nothing here reads the Mac or the device, and pressing Sync in the
// sheet changes nothing. Replace with the core's sync API (manifest diff → plan) when it exists.

struct SyncPairDemo: Identifiable, Hashable {
    enum Kind: Hashable { case camera, music, documents }

    let id: String
    let kind: Kind
    let sourceName: String
    let targetName: String
    let deviceName: String
    let devicePath: String
    let macPath: String
    let twoWay: Bool
    let badge: Int?
    /// False when the pair's device isn't connected (shown dimmed).
    let available: Bool

    var title: String { "\(sourceName) \(twoWay ? "↔" : "→") \(targetName)" }
}

struct SyncPlanItem: Identifiable, Hashable {
    enum Action: Hashable { case add, update, conflict, onlyTarget, unchanged }

    var id: String { name }
    var name: String
    var group: String
    var action: Action
    var reason: String
    var size: UInt64
    var excludedByDefault = false
}

struct SyncPlan {
    var items: [SyncPlanItem]
    var comparedFiles: Int
    var comparedSeconds: Double
    var targetUsed: UInt64
    var targetCapacity: UInt64
    var notes: [String]
}

enum SyncPreviewDemo {
    static let pairs: [SyncPairDemo] = [
        SyncPairDemo(id: "camera", kind: .camera, sourceName: "Camera", targetName: "Phone Imports", deviceName: "Galaxy S23",
                     devicePath: "DCIM › Camera", macPath: "~/Pictures/Phone Imports", twoWay: false, badge: 450, available: true),
        SyncPairDemo(id: "hires", kind: .music, sourceName: "HiRes", targetName: "SP3000 microSD", deviceName: "SP3000",
                     devicePath: "microSD › Music", macPath: "~/Music/HiRes", twoWay: false, badge: 44, available: true),
        SyncPairDemo(id: "docs", kind: .documents, sourceName: "Documents", targetName: "Tab S9", deviceName: "Galaxy Tab S9",
                     devicePath: "Documents", macPath: "~/Documents/Tab S9", twoWay: true, badge: nil, available: false),
    ]

    static func pair(_ id: String) -> SyncPairDemo? {
        pairs.first { $0.id == id && $0.available }
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "LLLL yyyy"
        return f
    }()

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()

    private static let takenFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d 'at' HH:mm"
        return f
    }()

    /// `reversed` flips the direction (Mac → device for the camera pair, and so on).
    static func plan(for pair: SyncPairDemo, reversed: Bool) -> SyncPlan {
        var plan: SyncPlan
        switch pair.kind {
        case .camera, .documents: plan = cameraPlan()
        case .music: plan = musicPlan()
        }
        if reversed {
            plan.items = plan.items.map { item in
                var item = item
                switch item.action {
                case .add:
                    item.action = .onlyTarget
                    item.reason = "Only on \(pair.deviceName) · left alone"
                case .onlyTarget:
                    item.action = .add
                    item.reason = "New · not on \(pair.deviceName) yet"
                default: break
                }
                return item
            }
            // The target is now the other side: the Mac for the music pair, the device otherwise.
            plan.targetUsed = pair.kind == .music ? 790 * DemoLibrary.GB : 74 * DemoLibrary.GB
            plan.targetCapacity = pair.kind == .music ? 2_000 * DemoLibrary.GB : 256 * DemoLibrary.GB
        }
        return plan
    }

    private static func cameraPlan() -> SyncPlan {
        var items: [SyncPlanItem] = []
        let now = Date()
        var t = now.addingTimeInterval(-3_600 * 3)
        var k = 0
        func add(_ count: Int) {
            for _ in 0..<count {
                let h = DemoLibrary.hash("plan\(k)")
                let stamp = stampFormatter.string(from: t)
                let group = monthFormatter.string(from: t)
                if k % 37 == 5 {
                    items.append(SyncPlanItem(name: "Screenshot_\(stamp).png", group: group, action: .add,
                                              reason: "New · screenshot · excluded by you", size: 900_000 + h % 400_000,
                                              excludedByDefault: true))
                } else if k % 9 == 1 {
                    let seconds = 20 + Int(h % 300)
                    items.append(SyncPlanItem(name: "VID_\(stamp).mp4", group: group, action: .add,
                                              reason: "New · 4K video · \(Format.duration(Double(seconds)))",
                                              size: UInt64(seconds) * 2_800_000))
                } else {
                    items.append(SyncPlanItem(name: "IMG_\(stamp).jpg", group: group, action: .add,
                                              reason: "New · photo · taken \(takenFormatter.string(from: t)) · 4000×3000",
                                              size: 3_100_000 + (h % 12) * 100_000))
                }
                t = t.addingTimeInterval(-Double(2_400 + h % 9_000))
                k += 1
            }
        }
        add(450)
        for i in 0..<2 {
            let stamp = stampFormatter.string(from: now.addingTimeInterval(-86_400 * Double(1 + i * 3)))
            items.insert(SyncPlanItem(name: "IMG_\(stamp).jpg", group: monthFormatter.string(from: now), action: .conflict,
                                      reason: "A different file with this name is already in Phone Imports (3.9 MB there, 4.2 MB here)",
                                      size: 4_200_000), at: 2 + i * 5)
        }
        for i in 0..<31 {
            items.append(SyncPlanItem(name: "Edited_\(1000 + i).jpg", group: "Only in Phone Imports", action: .onlyTarget,
                                      reason: "Only in Phone Imports · left alone", size: 2_000_000 + UInt64(i) * 90_000))
        }
        for i in 0..<5_762 {
            items.append(SyncPlanItem(name: "IMG_2025\(String(format: "%04d", i)).jpg", group: "Unchanged", action: .unchanged,
                                      reason: "Same name, size and date", size: 3_000_000 + UInt64(i % 13) * 100_000))
        }
        return SyncPlan(items: items, comparedFiles: 6_214, comparedSeconds: 0.9, targetUsed: 790 * DemoLibrary.GB,
                        targetCapacity: 2_000 * DemoLibrary.GB, notes: [
                            "Original dates are kept. Galaxy S23 reports when each photo and video was taken.",
                        ])
    }

    private static func musicPlan() -> SyncPlan {
        var items: [SyncPlanItem] = []
        let new = DemoLibrary.albums.filter { ["Miles Davis"].contains($0.artist) }.prefix(4)
        for album in new {
            for (i, track) in album.tracks.enumerated() {
                let name = String(format: "%02d - %@.flac", i + 1, track.0)
                items.append(SyncPlanItem(name: name, group: "\(album.artist) › \(album.year) - \(album.title)", action: .add,
                                          reason: "New · FLAC 24/192 · \(Format.duration(Double(track.1)))",
                                          size: DemoLibrary.flacSize(track.1, salt: name)))
            }
        }
        items = Array(items.prefix(40))
        for (i, name) in ["01 - Airbag.flac", "06 - Karma Police.flac", "10 - No Surprises.flac", "12 - The Tourist.flac"].enumerated() {
            items.append(SyncPlanItem(name: name, group: "Radiohead › 1997 - OK Computer", action: .update,
                                      reason: "Tags changed on the Mac (size differs by \(30 + i * 7) KB)",
                                      size: 41_000_000 + UInt64(i) * 3_000_000))
        }
        for i in 0..<6 {
            items.append(SyncPlanItem(name: "Live \(i + 1).flac", group: "Only on SP3000 microSD", action: .onlyTarget,
                                      reason: "Only on SP3000 microSD · left alone", size: 60_000_000))
        }
        for i in 0..<1_180 {
            items.append(SyncPlanItem(name: "Track \(i + 1).flac", group: "Unchanged", action: .unchanged,
                                      reason: "Same name and size", size: 50_000_000))
        }
        return SyncPlan(items: items, comparedFiles: 1_230, comparedSeconds: 0.4, targetUsed: 588 * DemoLibrary.GB,
                        targetCapacity: 1_000 * DemoLibrary.GB, notes: [
                            "Card-safe names: 2 file names will change for the microSD card (for example “AC/DC” → “AC_DC”).",
                        ])
    }
}
