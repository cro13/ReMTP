import Foundation
import ImageIO
import UniformTypeIdentifiers

// DEMO ONLY. In-memory file trees for the demo devices. Not used by the real backend.

/// A node in a demo device's file tree. Guarded by `DemoDeviceService`'s lock.
final class DemoNode {
    var name: String
    let isDir: Bool
    var size: UInt64
    var modified: Int64?
    /// Keyed by lowercased name: Android's emulated storage and FAT/exFAT cards are case-insensitive.
    private(set) var children: [String: DemoNode] = [:]

    init(name: String, isDir: Bool, size: UInt64 = 0, modified: Int64? = nil) {
        self.name = name
        self.isDir = isDir
        self.size = size
        self.modified = modified
    }

    func child(_ name: String) -> DemoNode? { children[name.lowercased()] }

    func insert(_ node: DemoNode) { children[node.name.lowercased()] = node }

    func remove(_ name: String) { children[name.lowercased()] = nil }

    @discardableResult
    func folder(_ name: String, modified: Int64? = nil) -> DemoNode {
        if let existing = child(name), existing.isDir { return existing }
        let node = DemoNode(name: name, isDir: true, modified: modified ?? DemoLibrary.now - 86_400 * 30)
        insert(node)
        return node
    }

    func file(_ name: String, _ size: UInt64, modified: Int64? = nil) {
        insert(DemoNode(name: name, isDir: false, size: size, modified: modified ?? DemoLibrary.date(for: name)))
    }

    var sortedChildren: [DemoNode] { children.values.sorted { $0.name < $1.name } }

    var totalBytes: UInt64 { isDir ? children.values.reduce(0) { $0 + $1.totalBytes } : size }

    var entry: FileEntry { FileEntry(name: name, isDir: isDir, size: isDir ? 0 : size, modified: modified) }
}

enum DemoLibrary {
    /// The demo's "now": file dates and camera file names count back from it. `REMTP_DEMO_NOW` (seconds since
    /// 1970) pins it, so the documentation screens (design/app-shots.sh) show the same files on every run.
    static let now = ProcessInfo.processInfo.environment["REMTP_DEMO_NOW"].flatMap { Int64($0) }
        ?? Int64(Date().timeIntervalSince1970)

    static let MB: UInt64 = 1_000_000
    static let GB: UInt64 = 1_000_000_000

    /// Stable pseudo-random number for a string (FNV-1a).
    static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h
    }

    static func date(for name: String) -> Int64 {
        now - Int64(hash(name) % (86_400 * 200))
    }

    static func mb(_ value: Double) -> UInt64 { UInt64(value * Double(MB)) }

    // MARK: Thumbnails

    /// What a phone answers to GetThumb for a photo or video: a small JPEG. Here a gradient with a soft sun,
    /// coloured by the file's path (like the self-check's Mac sample images); videos are darker 16:9 frames.
    static func thumbnail(for path: String) -> Data? {
        guard let type = FileKinds.type(for: DevicePath.lastComponent(path), isDirectory: false) else { return nil }
        let isVideo = type.conforms(to: .movie)
        guard isVideo || type.conforms(to: .image) else { return nil }
        let h = hash(path)
        let (width, height) = isVideo ? (160, 90) : h % 3 == 0 ? (120, 160) : (160, 120)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let hue = Double((h >> 32) % 360) / 360
        let brightness = isVideo ? 0.55 : 0.92
        let colors = [rgb(hue, 0.62, brightness), rgb(hue + 0.09 + Double((h >> 9) % 8) / 100, 0.7, brightness - 0.08)]
        let components = colors.flatMap { [$0.0, $0.1, $0.2, 1] }.map { CGFloat($0) }
        guard let gradient = CGGradient(colorSpace: space, colorComponents: components, locations: [0, 1], count: 2) else { return nil }
        let w = CGFloat(width), side = CGFloat(min(width, height))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: w * 0.7), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        if isVideo {
            context.setFillColor(CGColor(gray: 0, alpha: 0.22))
            context.fill(CGRect(x: 0, y: 0, width: w, height: CGFloat(height) * 0.36))
        }
        let sun = side * 0.34
        context.setFillColor(CGColor(gray: 1, alpha: isVideo ? 0.32 : 0.4))
        context.fillEllipse(in: CGRect(x: w * (0.58 + Double((h >> 4) % 12) / 100), y: CGFloat(height) - sun * 1.45,
                                       width: sun, height: sun))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func rgb(_ hue: Double, _ saturation: Double, _ brightness: Double) -> (Double, Double, Double) {
        let h = (hue - hue.rounded(.down)) * 6, sector = Int(h) % 6, f = h - h.rounded(.down)
        let p = brightness * (1 - saturation), q = brightness * (1 - saturation * f), t = brightness * (1 - saturation * (1 - f))
        switch sector {
        case 0: return (brightness, t, p)
        case 1: return (q, brightness, p)
        case 2: return (p, brightness, t)
        case 3: return (p, q, brightness)
        case 4: return (t, p, brightness)
        default: return (brightness, p, q)
        }
    }

    // MARK: Galaxy S23

    static func galaxyInternal() -> DemoNode {
        let root = DemoNode(name: "", isDir: true)
        for name in ["Alarms", "Audiobooks", "Movies", "Notifications", "Podcasts", "Recordings", "Ringtones"] {
            root.folder(name)
        }
        let android = root.folder("Android")
        android.folder("data")
        android.folder("media")
        android.folder("obb")

        // DCIM/Camera: about six weeks of photos and videos, named like Samsung's camera does.
        let dcim = root.folder("DCIM")
        let camera = dcim.folder("Camera")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        var t = now - 86_400 * 45
        var k = 0
        while t < now - 3_600 {
            let h = hash("cam\(k)")
            let isVideo = k % 7 == 3
            let stamp = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
            if isVideo {
                camera.file("VID_\(stamp).mp4", mb(Double(60 + h % 840)), modified: t)
            } else {
                camera.file("IMG_\(stamp).jpg", mb(3.0 + Double(h % 14) / 10), modified: t)
            }
            t += Int64(1_800 + h % 21_000)
            k += 1
        }
        let shots = dcim.folder("Screenshots")
        for (i, name) in ["Screenshot_20261030_220114_Maps.png", "Screenshot_20261102_081544_Chrome.png",
                          "Screenshot_20261103_191201_Gallery.png", "Screenshot_20261110_120533_Settings.png",
                          "Screenshot_20261116_231907_Messages.png"].enumerated() {
            shots.file(name, mb(0.8 + Double(i) * 0.15))
        }

        // Download/Lisbon 2026: mixed files, partly copied from the Mac already.
        let download = root.folder("Download")
        let lisbon = download.folder("Lisbon 2026")
        lisbon.file("Boarding pass.pdf", 182_000)
        lisbon.file("Hotel confirmation.pdf", 96_000)
        lisbon.file("IMG_0412.HEIC", mb(2.8))
        lisbon.file("IMG_0413.HEIC", mb(3.1))
        lisbon.file("IMG_0415.MOV", mb(212))
        lisbon.file("IMG_0416.HEIC", mb(2.6))
        lisbon.file("IMG_0418.HEIC", mb(3.4))
        lisbon.file("IMG_0419.MOV", mb(148))
        lisbon.file("IMG_0421.HEIC", mb(2.9))
        lisbon.file("IMG_0458.HEIC", mb(2.9))
        lisbon.file("Screenshot_20261103.png", mb(1.1))
        let edited = lisbon.folder("Edited")
        edited.file("IMG_0412-edit.jpg", mb(4.1))
        edited.file("IMG_0416-edit.jpg", mb(3.7))
        download.file("Menu Time Out Market.pdf", 2_400_000)
        download.file("Train tickets Porto.pdf", 310_000)
        download.file("whatsapp-backup.crypt14", mb(486))
        download.file("Firmware notes.txt", 4_200)

        let documents = root.folder("Documents")
        documents.file("Lease agreement.pdf", 1_800_000)
        documents.file("Insurance 2026.pdf", 640_000)
        documents.file("Budget 2026.xlsx", 88_000)
        documents.file("CV.docx", 54_000)
        documents.file("Packing list.txt", 2_100)
        let scans = documents.folder("Scans")
        for i in 1...12 { scans.file(String(format: "Scan_%03d.pdf", i), mb(0.4 + Double(i % 5) / 10)) }

        let music = root.folder("Music")
        let playlists = music.folder("Playlists")
        playlists.file("Running.m3u8", 3_200)
        let pictures = root.folder("Pictures")
        let wa = pictures.folder("WhatsApp")
        for i in 1...24 { wa.file("IMG-20261\(100 + i)-WA0001.jpg", mb(0.2 + Double(i % 6) / 10)) }
        return root
    }

    // MARK: SP3000

    struct Album {
        var artist: String
        var title: String
        var year: Int
        var tracks: [(String, Int)]  // title, seconds
    }

    static let albums: [Album] = [
        Album(artist: "Miles Davis", title: "Walkin'", year: 1954, tracks: generic(6, seed: "walkin")),
        Album(artist: "Miles Davis", title: "'Round About Midnight", year: 1956, tracks: [
            ("'Round Midnight", 357), ("Ah-Leu-Cha", 353), ("All of You", 423),
            ("Bye Bye Blackbird", 476), ("Tadd's Delight", 268), ("Dear Old Stockholm", 470)]),
        Album(artist: "Miles Davis", title: "Miles Ahead", year: 1957, tracks: generic(10, seed: "ahead")),
        Album(artist: "Miles Davis", title: "Milestones", year: 1958, tracks: [
            ("Dr. Jekyll", 349), ("Sid's Ahead", 780), ("Two Bass Hit", 314),
            ("Milestones", 345), ("Billy Boy", 432), ("Straight, No Chaser", 645)]),
        Album(artist: "Miles Davis", title: "Kind of Blue", year: 1959, tracks: [
            ("So What", 562), ("Freddie Freeloader", 586), ("Blue in Green", 337),
            ("All Blues", 693), ("Flamenco Sketches", 566)]),
        Album(artist: "Miles Davis", title: "Sketches of Spain", year: 1960, tracks: [
            ("Concierto de Aranjuez (Adagio)", 979), ("Will o' the Wisp", 227), ("The Pan Piper", 232),
            ("Saeta", 306), ("Solea", 735)]),
        Album(artist: "Miles Davis", title: "Someday My Prince Will Come", year: 1961, tracks: generic(6, seed: "someday")),
        Album(artist: "Miles Davis", title: "Four & More", year: 1964, tracks: generic(7, seed: "four")),
        Album(artist: "Miles Davis", title: "In a Silent Way", year: 1969, tracks: [
            ("Shhh/Peaceful", 1099), ("In a Silent Way/It's About That Time", 1201)]),
        Album(artist: "Miles Davis", title: "Bitches Brew", year: 1970, tracks: [
            ("Pharaoh's Dance", 1200), ("Bitches Brew", 1620), ("Spanish Key", 1054),
            ("John McLaughlin", 263), ("Miles Runs the Voodoo Down", 841), ("Sanctuary", 655)]),
        Album(artist: "John Coltrane", title: "A Love Supreme", year: 1965, tracks: [
            ("Part I: Acknowledgement", 467), ("Part II: Resolution", 442),
            ("Part III: Pursuance", 645), ("Part IV: Psalm", 422)]),
        Album(artist: "Bill Evans Trio", title: "Waltz for Debby", year: 1962, tracks: [
            ("My Foolish Heart", 296), ("Waltz for Debby", 415), ("Detour Ahead", 457),
            ("My Romance", 432), ("Some Other Time", 305), ("Milestones", 386)]),
        Album(artist: "Radiohead", title: "OK Computer", year: 1997, tracks: [
            ("Airbag", 284), ("Paranoid Android", 383), ("Subterranean Homesick Alien", 267),
            ("Exit Music (For a Film)", 264), ("Let Down", 299), ("Karma Police", 261),
            ("Fitter Happier", 117), ("Electioneering", 230), ("Climbing Up the Walls", 285),
            ("No Surprises", 228), ("Lucky", 259), ("The Tourist", 324)]),
        Album(artist: "Daft Punk", title: "Random Access Memories", year: 2013, tracks: [
            ("Give Life Back to Music", 274), ("The Game of Love", 321), ("Giorgio by Moroder", 544),
            ("Within", 228), ("Instant Crush", 337), ("Lose Yourself to Dance", 353), ("Touch", 498),
            ("Get Lucky", 367), ("Beyond", 290), ("Motherboard", 341), ("Fragments of Time", 279),
            ("Doin' It Right", 251), ("Contact", 381)]),
    ]

    static func generic(_ count: Int, seed: String) -> [(String, Int)] {
        (1...count).map { i in ("Track \(i)", 180 + Int(hash("\(seed)\(i)") % 420)) }
    }

    /// FLAC 24-bit/192 kHz is roughly 0.95 MB per second of music.
    static func flacSize(_ seconds: Int, salt: String) -> UInt64 {
        UInt64(Double(seconds) * 950_000 * (0.92 + Double(hash(salt) % 16) / 100))
    }

    static func addAlbum(_ album: Album, to music: DemoNode, variant: Int = 0) {
        let artist = music.folder(album.artist)
        let folder = artist.folder("\(album.year) - \(album.title)")
        let released = now - Int64(hash(album.title) % (86_400 * 400))
        for (i, track) in album.tracks.enumerated() {
            let name = String(format: "%02d - %@.flac", i + 1, track.0)
            folder.file(name, flacSize(track.1, salt: name) + UInt64(variant), modified: released)
        }
        folder.file("folder.jpg", 388_000 + hash(album.title) % 200_000, modified: released)
    }

    static func sp3000Internal() -> DemoNode {
        let root = DemoNode(name: "", isDir: true)
        let music = root.folder("Music")
        for album in albums where album.artist != "Radiohead" {
            // "Someday My Prince Will Come" differs from the Mac copy (re-tagged on the Mac).
            addAlbum(album, to: music, variant: album.title.hasPrefix("Someday") ? 41_213 : 0)
        }
        let playlists = root.folder("Playlists")
        playlists.file("Late night.m3u8", 2_800)
        playlists.file("Miles.m3u8", 4_100)
        root.folder("Download")
        return root
    }

    static func sp3000Card() -> DemoNode {
        let root = DemoNode(name: "", isDir: true)
        let music = root.folder("Music")
        for album in albums where ["Radiohead", "Daft Punk", "Bill Evans Trio"].contains(album.artist) {
            addAlbum(album, to: music)
        }
        root.folder("Playlists")
        return root
    }
}
