import AppKit
import SwiftUI

/// List / Columns / Icons for the active pane (⌘1 / ⌘2 / ⌘3).
struct ViewModeControl: NSViewRepresentable {
    let mode: PaneViewMode
    let select: (PaneViewMode) -> Void

    final class Coordinator: NSObject {
        var select: (PaneViewMode) -> Void

        init(select: @escaping (PaneViewMode) -> Void) {
            self.select = select
        }

        @MainActor @objc func changed(_ sender: NSSegmentedControl) {
            let modes = PaneViewMode.allCases
            guard modes.indices.contains(sender.selectedSegment) else { return }
            select(modes[sender.selectedSegment])
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(select: select) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let modes = PaneViewMode.allCases
        let images = modes.map { NSImage(systemSymbolName: $0.systemImage, accessibilityDescription: $0.title) ?? NSImage() }
        let control = NSSegmentedControl(images: images, trackingMode: .selectOne, target: context.coordinator,
                                         action: #selector(Coordinator.changed(_:)))
        for (index, mode) in modes.enumerated() {
            control.setToolTip("\(mode.title) (⌘\(mode.shortcut))", forSegment: index)
        }
        control.segmentStyle = .automatic
        control.selectedSegment = modes.firstIndex(of: mode) ?? 0
        control.setAccessibilityLabel("View")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.select = select
        let index = PaneViewMode.allCases.firstIndex(of: mode) ?? 0
        if control.selectedSegment != index { control.selectedSegment = index }
    }
}

/// The toolbar's one filled button: accent-coloured while it can act and the window is active, like a
/// default button. (The system's prominent style draws as a plain bordered button in a toolbar.)
struct ProminentToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Filled(configuration: configuration)
    }

    private struct Filled: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlActiveState) private var activeState

        var body: some View {
            let filled = isEnabled && activeState != .inactive
            configuration.label
                // Disabled shows status ("Copying 314…"), so it stays readable: secondary, not tertiary.
                .foregroundStyle(filled ? AnyShapeStyle(Color.white) : isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 6)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(filled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.07))))
                .opacity(configuration.isPressed ? 0.75 : 1)
                .contentShape(Rectangle())
        }
    }
}

struct MainToolbar: CustomizableToolbarContent {
    @Bindable var app: AppModel

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "back", placement: .navigation) {
            Button { app.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!app.activePane.canGoBack)
                .help("Back")
        }
        ToolbarItem(id: "forward", placement: .navigation) {
            Button { app.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!app.activePane.canGoForward)
                .help("Forward")
        }
        ToolbarItem(id: "view", placement: .primaryAction) {
            Label {
                Text("View")
            } icon: {
                ViewModeControl(mode: app.activePane.viewMode) { app.setViewMode($0) }
            }
            .help("View as List, Columns or Icons")
        }
        ToolbarItem(id: "swap-panes", placement: .primaryAction) {
            Button { app.swapPanes() } label: { Label("Swap Panes", systemImage: "arrow.left.arrow.right") }
                .help("Swap Panes")
        }
        ToolbarItem(id: "new-folder", placement: .primaryAction) {
            Button { app.newFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                .disabled(app.activePane.location == nil || (app.activeKind == .device && !app.devicePaneBrowsable))
                .help("New Folder (⇧⌘N)")
        }
        // The app's main action: the only filled button, with how many items it would copy.
        ToolbarItem(id: "copy", placement: .primaryAction) {
            CopyToolbarButton(app: app)
        }
        .customizationBehavior(.reorderable)
        if app.showsSync {
            ToolbarItem(id: "sync", placement: .primaryAction) {
                Button { app.openSync() } label: {
                    Label("Sync", systemImage: "repeat")
                }
                .help("Preview a sync (demo data)")
            }
        }
        ToolbarItem(id: "transfers", placement: .primaryAction) {
            TransfersToolbarButton(app: app)
        }
        .customizationBehavior(.reorderable)
        ToolbarItem(id: "inspector", placement: .primaryAction) {
            Toggle(isOn: $app.inspectorVisible) {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help("Show or hide the inspector (⌘I)")
        }
    }

    /// "Copy 3 to <name>" ("Copy to <name>" with nothing to copy). A name too long for the button reads
    /// "Device" there, so the button stays narrow and never pushes the filter field into the overflow; the
    /// tooltip has the full name.
    static func copyTitle(_ name: String, count: Int = 0) -> String {
        // A name that fits is never shortened for the count.
        let fits = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width <= 80
        return "Copy \(count > 0 ? "\(number(count)) " : "")to \(fits ? name : "Device")"
    }

    /// "Copying 314…": everything the button would copy is already on its way.
    static func copyingTitle(count: Int) -> String { "Copying \(number(count))…" }

    private static func number(_ count: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
    }
}

struct ToolbarItemLabels: NSViewRepresentable {
    func makeNSView(context: Context) -> ToolbarView { ToolbarView() }

    func updateNSView(_ view: ToolbarView, context: Context) { view.refreshItems() }

    final class ToolbarView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if window != nil {
                NotificationCenter.default.addObserver(self, selector: #selector(itemsChanged(_:)),
                                                       name: NSToolbar.willAddItemNotification, object: nil)
                refreshItems()
            }
        }

        @objc private func itemsChanged(_ notification: Notification) {
            if notification.object as? NSToolbar === window?.toolbar { refreshItems() }
        }

        func refreshItems() {
            DispatchQueue.main.async { [weak self] in
                guard let toolbar = self?.window?.toolbar else { return }
                if #available(macOS 15, *) { toolbar.allowsDisplayModeCustomization = true }
                for item in toolbar.items {
                    if item is NSSearchToolbarItem {
                        if item.label != "Filter" { item.label = "Filter" }
                        if item.paletteLabel != "Filter" { item.paletteLabel = "Filter" }
                    } else if item.label.hasPrefix("Copy") {
                        item.visibilityPriority = .high
                    }
                }
            }
        }
    }
}

/// Copies the active pane's selection to the other pane. Items a transfer is already copying there are left
/// out; when that is all of them, the button waits as "Copying N…".
private struct CopyToolbarButton: View {
    let app: AppModel

    var body: some View {
        let targets = app.canCopy ? app.activePane.targetItems.count : 0
        let inFlight = app.copyTargetsInFlight.count
        let copying = targets > 0 && inFlight == targets
        let name = app.copyTargetName
        Button { app.copyToOtherPane() } label: {
            Label(copying ? MainToolbar.copyingTitle(count: inFlight) : MainToolbar.copyTitle(name, count: targets - inFlight),
                  systemImage: app.copyArrowSymbol)
                .labelStyle(.titleAndIcon)
                .monospacedDigit()
        }
        .buttonStyle(ProminentToolbarButtonStyle())
        .disabled(!app.canCopy || copying)
        .help(help(name, inFlight: inFlight, copying: copying))
    }

    private func help(_ name: String, inFlight: Int, copying: Bool) -> String {
        if copying { return "Already copying to \(app.copyInFlightDestination ?? name). See Transfers (⌥⌘T)." }
        guard inFlight > 0 else { return "Copy the selection to \(name) (\(app.copyShortcut))" }
        return "Copy the rest of the selection to \(name) (\(app.copyShortcut)). \(Format.count(inFlight, "item")) \(inFlight == 1 ? "is" : "are") already being copied."
    }
}
