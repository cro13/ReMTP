import AppKit
import Quartz

/// Space / ⌘Y Quick Look for the Mac pane's selection.
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private weak var pane: PaneModel?
    private var urls: [URL] = []
    /// Arrow keys pressed in the panel go back to the pane's view (list, columns or icons).
    weak var keyTarget: NSResponder?

    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func toggle(pane: PaneModel) {
        self.pane = pane
        if isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        } else {
            refreshURLs()
            guard !urls.isEmpty else { return NSSound.beep() }
            QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
        }
    }

    func selectionChanged() {
        guard isVisible else { return }
        refreshURLs()
        QLPreviewPanel.shared().reloadData()
    }

    private func refreshURLs() {
        urls = pane?.targetItems.compactMap(\.url) ?? []
    }

    func take(_ panel: QLPreviewPanel, pane: PaneModel) {
        self.pane = pane
        refreshURLs()
        panel.dataSource = self
        panel.delegate = self
    }

    func release(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    // MARK: QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] as NSURL : nil }
    }

    // MARK: QLPreviewPanelDelegate

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        MainActor.assumeIsolated {
            guard event.type == .keyDown, let target = keyTarget else { return false }
            switch event.keyCode {
            case 125, 126:  // down, up
                target.keyDown(with: event)
                return true
            default:
                return false
            }
        }
    }
}
