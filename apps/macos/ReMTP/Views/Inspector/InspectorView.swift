import AVFoundation
import SwiftUI

/// Right-hand inspector for the active pane's selection.
struct InspectorView: View {
    let app: AppModel

    var body: some View {
        let pane = app.activePane
        let selected = pane.targetItems
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if selected.count == 1, let item = selected.first {
                    ItemInspector(item: item, pane: pane, app: app)
                        .id("\(pane.kind.rawValue)|\(item.url?.path ?? item.devicePath ?? item.name)|\(item.size ?? 0)")
                } else if selected.count > 1 {
                    MultiInspector(items: selected, pane: pane, app: app)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(pane.folderName).font(.system(size: 17, weight: .bold))
                        Text("\(Format.count(pane.items.count, "item")) · \(pane.subtitle)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text("Select a file to see its details.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Audio facts read with AVFoundation (local files only).
struct AudioFacts {
    var title: String?
    var artist: String?
    var album: String?
    var year: String?
    var duration: Double?
    var format: String?
    var artwork: NSImage?

    static func load(_ url: URL) async -> AudioFacts {
        let asset = AVURLAsset(url: url)
        var facts = AudioFacts()
        if let duration = try? await asset.load(.duration), duration.isNumeric { facts.duration = duration.seconds }
        if let metadata = try? await asset.load(.commonMetadata) {
            for item in metadata {
                switch item.commonKey {
                case .commonKeyTitle?: facts.title = try? await item.load(.stringValue)
                case .commonKeyArtist?: facts.artist = try? await item.load(.stringValue)
                case .commonKeyAlbumName?: facts.album = try? await item.load(.stringValue)
                case .commonKeyCreationDate?:
                    if let value = try? await item.load(.stringValue) { facts.year = String(value.prefix(4)) }
                case .commonKeyArtwork?:
                    if let data = try? await item.load(.dataValue) { facts.artwork = NSImage(data: data) }
                default:
                    break
                }
            }
        }
        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
           let description = try? await track.load(.formatDescriptions).first,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            var parts: [String] = []
            if basic.mBitsPerChannel > 0 { parts.append("\(basic.mBitsPerChannel)-bit") }
            if basic.mSampleRate > 0 {
                let khz = basic.mSampleRate / 1_000
                parts.append(khz == khz.rounded() ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz))
            }
            if !parts.isEmpty { facts.format = parts.joined(separator: " / ") }
        }
        return facts
    }
}

struct Track: Identifiable {
    var id: String { name }
    var name: String
    var duration: Double?
}

private struct ItemInspector: View {
    let item: FileItem
    let pane: PaneModel
    let app: AppModel
    @State private var preview: NSImage?
    /// A device file whose device sent no thumbnail.
    @State private var previewMissing = false
    @State private var audio: AudioFacts?
    @State private var folderCount: Int?
    @State private var tracks: [Track] = []

    var body: some View {
        if hasPreview {
            previewView
            titleBlock(size: 17)
        } else {
            HStack(spacing: 12) {
                Image(nsImage: FileIcons.icon(for: item))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 56)
                titleBlock(size: 15)
            }
        }
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            // Without a preview, the line under the title already says kind, size and item count.
            if hasPreview {
                row("Kind", kindText)
                if let size = item.size { row("Size", Format.bytes(size)) }
                if let count = folderCount { row("Contains", Format.count(count, "item")) }
            }
            if let duration = audio?.duration { row("Duration", Format.duration(duration)) }
            // A folder's track count and length head its track list below.
            if let modified = item.modified { row("Modified", Format.date(modified)) }
            if let created = item.created { row("Created", Format.date(created)) }
            row(pane.kind == .mac ? "On Mac" : "On device", locationText)
        }
        .font(.system(size: 12))
        CompareCard(item: item, pane: pane, app: app)
        if !tracks.isEmpty { trackList }
        Color.clear.frame(height: 1)
            .task { await load() }
    }

    /// Local images, video, PDFs and audio (cover art) get the large preview, and so do photos and videos on a
    /// device that has a thumbnail for them. Anything else (folders, documents, other files on a device) has
    /// nothing to show there: its icon sits next to the title.
    private var hasPreview: Bool {
        guard !item.isBrowsable else { return false }
        if item.url != nil { return item.isAudio || Thumbnails.canThumbnail(item) }
        return Thumbnails.canThumbnail(item) && !previewMissing && !Thumbnails.shared.knownMissing(item)
    }

    private func titleBlock(size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(audio?.title ?? item.name)
                .font(.system(size: size, weight: .bold))
                .lineLimit(3)
                .textSelection(.enabled)
            Text(byline).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private var byline: String {
        if let audio, audio.artist != nil || audio.album != nil {
            return [audio.artist, audio.album, audio.year].compactMap { $0 }.joined(separator: " · ")
        }
        return [item.kind, item.size.map(Format.bytes), folderCount.map { Format.count($0, "item") }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var kindText: String {
        if let format = audio?.format { return "\(item.kind) · \(format)" }
        return item.kind
    }

    private var locationText: String {
        let crumbs = pane.crumbs.map(\.title)
        return (pane.kind == .device ? Array(crumbs.dropFirst()) : crumbs).joined(separator: " › ")
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var previewView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05))
            if let image = audio?.artwork ?? preview {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(nsImage: FileIcons.icon(for: item))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 128, height: 128)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }

    private var trackList: some View {
        VStack(alignment: .leading, spacing: 0) {
            // "5 tracks · 45:44": said once, as the list's heading (the folder's item count above also counts covers).
            Text(trackHeading).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.bottom, 2)
            ForEach(Array(tracks.prefix(100).enumerated()), id: \.element.id) { index, track in
                HStack(spacing: 6) {
                    Text("\(index + 1)").foregroundStyle(.secondary).monospacedDigit().frame(width: 18, alignment: .leading)
                    Text(Self.trackTitle(track.name)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let duration = track.duration {
                        Text(Format.duration(duration)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .font(.system(size: 12))
                .padding(.vertical, 4)
                .overlay(alignment: .bottom) { Divider() }
            }
        }
    }

    private var trackHeading: String {
        let total = tracks.compactMap(\.duration).reduce(0, +)
        return [Format.count(tracks.count, "track"), total > 0 ? Format.duration(total) : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// "05 - Flamenco Sketches.flac" → "Flamenco Sketches".
    static func trackTitle(_ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        if let range = stem.range(of: #"^\d{1,3}\s*[-.]\s*"#, options: .regularExpression) {
            return String(stem[range.upperBound...])
        }
        return stem
    }

    private func load() async {
        if let url = item.url {
            if item.isAudio {
                audio = await AudioFacts.load(url)
            } else if Thumbnails.canThumbnail(item) {
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                preview = await Thumbnails.shared.thumbnail(for: item, size: 264, scale: scale)
            }
            if item.isBrowsable {
                let listed = (try? await offMain { try LocalFileSystem.list(url, showHidden: false) }) ?? []
                folderCount = listed.count
                let audioFiles = listed.filter(\.isAudio).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                tracks = audioFiles.map { Track(name: $0.name, duration: nil) }
                var loaded: [String: Double] = [:]
                for file in audioFiles.prefix(60) {
                    guard let fileURL = file.url else { continue }
                    let asset = AVURLAsset(url: fileURL)
                    if let duration = try? await asset.load(.duration), duration.isNumeric { loaded[file.name] = duration.seconds }
                }
                tracks = audioFiles.map { Track(name: $0.name, duration: loaded[$0.name]) }
            }
        } else if Thumbnails.canThumbnail(item) {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            preview = await Thumbnails.shared.thumbnail(for: item, size: 264, scale: scale, urgent: true)
            previewMissing = preview == nil
        } else if item.isBrowsable, let path = item.devicePath, let loc = pane.location?.device,
                  let connection = app.connection(for: loc.deviceID) {
            let entries = (try? await offMain { try connection.list(storageID: loc.storageID, path: path) }) ?? []
            folderCount = entries.count
            tracks = entries.filter { !$0.isDir && FileKinds.type(for: $0.name, isDirectory: false)?.conforms(to: .audio) == true }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { Track(name: $0.name, duration: nil) }
        }
    }
}

/// "Same on SP3000 and Mac" and friends.
private struct CompareCard: View {
    let item: FileItem
    let pane: PaneModel
    let app: AppModel

    var body: some View {
        let status = app.status(for: item, in: pane)
        let device = app.shownSession?.name ?? "the device"
        let otherItem = app.other(pane).index[item.compareKey]
        let content: (String, String, String?, Color)? = {
            switch status {
            case .same:
                // Sync (and its checksum comparison) only exists with the demo backend so far.
                let checksums = app.showsSync ? " Checksums are compared by the sync engine." : ""
                return ("checkmark.circle", "Same on \(device) and Mac",
                        "Name and size match (\(item.size.map(Format.bytes) ?? "")).\(checksums)", .green)
            case .differs:
                let here = item.size.map(Format.bytes) ?? "folder"
                let there = otherItem?.size.map(Format.bytes) ?? "folder"
                return ("circle.lefthalf.filled", pane.kind == .mac ? "Different on \(device)" : "Different on the Mac",
                        "\(there) there, \(here) here.", .orange)
            case .notOnDevice, .notOnMac:
                guard app.foldersOverlap(pane) else { return nil }
                // What was compared is the folder open in the other pane, not the whole other side.
                return (pane.kind == .mac ? "smartphone" : "laptopcomputer", app.missingText(in: pane), nil, .primary)
            case .folderOnBoth:
                return ("equal.circle", "Folder exists on both sides",
                        app.showsSync ? "Folder contents aren’t compared here; use Sync for a full comparison."
                            : "Folder contents aren’t compared here; open the folder on both sides to compare them.",
                        .secondary)
            case .copying(let f), .arriving(let f):
                return ("arrow.right.circle", "Copying · \(Int(f * 100))%", "The file is being copied right now.", .accentColor)
            case .copyingFolder:
                return ("arrow.right.circle", "Copying", "Files in this folder are being copied.", .accentColor)
            case .queued:
                return ("clock", "Queued", "Waiting for earlier files in the queue.", .accentColor)
            case .none:
                return nil
            }
        }()
        if let (symbol, title, detail, tint) = content {
            VStack(alignment: .leading, spacing: 4) {
                // The symbol carries the status colour; the words stay in the label colour (orange or green
                // text on a light background is about 2:1).
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if status.isMissing {
                    Button { app.copyToOtherPane() } label: {
                        Label(MainToolbar.copyTitle(app.copyTargetName), systemImage: app.copyArrowSymbol)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!app.canCopy)
                    .help("Copy it to the other pane (\(app.copyShortcut)). Dragging it there works too.")
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
        }
    }
}

private struct MultiInspector: View {
    let items: [FileItem]
    let pane: PaneModel
    let app: AppModel

    var body: some View {
        let bytes = items.reduce(UInt64(0)) { $0 + ($1.size ?? 0) }
        let kinds = Dictionary(grouping: items, by: \.kind).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
        let statuses = items.map { app.status(for: $0, in: pane) }
        HStack(spacing: -18) {
            ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { _, item in
                FileIconView(item: item, size: 64).shadow(radius: 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        VStack(alignment: .leading, spacing: 2) {
            Text(Format.count(items.count, "item")).font(.system(size: 17, weight: .bold))
            if bytes > 0 { Text(Format.bytes(bytes)).font(.system(size: 12)).foregroundStyle(.secondary) }
        }
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            ForEach(kinds.prefix(6), id: \.0) { kind, count in
                GridRow {
                    Text("\(count)").foregroundStyle(.secondary).monospacedDigit().frame(width: 30, alignment: .trailing)
                    Text(kind)
                }
            }
        }
        .font(.system(size: 12))
        let same = statuses.filter { $0 == .same }.count
        let differs = statuses.filter { $0 == .differs }.count
        // Between unrelated folders every item is "missing"; like the single-item card, say nothing then.
        let missingDirection = app.missingStatusDirection(in: pane)
        let missing = missingDirection == nil ? 0 : statuses.filter(\.isMissing).count
        if same + differs + missing > 0 {
            VStack(alignment: .leading, spacing: 4) {
                if same > 0 { statusLine("\(same) the same on both sides", "checkmark.circle", .green) }
                if differs > 0 { statusLine("\(differs) different", "circle.lefthalf.filled", .orange) }
                if missing > 0, let missingDirection {
                    statusLine("\(missing) not \(app.otherFolderText(for: pane))", missingDirection.symbol, .secondary)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
        }
    }

    /// A count in the label colour; the symbol carries the status colour.
    private func statusLine(_ text: String, _ symbol: String, _ tint: Color) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }
}
