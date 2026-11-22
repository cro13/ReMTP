import AppKit
import Quartz

/// A pane's NSTableView (the list, and each column of the column browser): pane-level keys (Tab, Return,
/// Space, F5, ⌘↑/⌘↓, ⌘⌫, ⌘⇧←/→, ← / →), focus tracking for the active pane, and Quick Look panel control.
final class PaneTableView: NSTableView, PaneDragSourceView {
    var onKey: ((PaneKey) -> Bool)?
    var onFocusChange: ((Bool) -> Void)?
    /// The pane this list belongs to (drags between panes tell their source by it).
    var paneKind: PaneKind?
    /// A drag entered (its info) or left (nil) the list.
    var onDragHover: ((NSDraggingInfo?) -> Void)?
    /// A drag over the list ended (dropped or cancelled).
    var onDragEnded: (() -> Void)?
    /// The pane whose selection Quick Look should show (Mac pane only).
    var quickLookPane: (() -> PaneModel?)?
    private var lastTypeSelect: TimeInterval = 0

    override func keyDown(with event: NSEvent) {
        let now = Date().timeIntervalSinceReferenceDate
        let key = PaneKey.from(event, typing: now - lastTypeSelect <= 1.0)
        if key == nil, PaneKey.isTypeSelect(event) { lastTypeSelect = now }
        if let key, onKey?(key) == true { return }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Right-clicking an unselected row selects it, so every command acts on the selection.
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row), delegate?.tableView?(self, shouldSelectRow: row) ?? true {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        window?.makeFirstResponder(self)
        return super.menu(for: event)
    }

    // MARK: Drag hover

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onDragHover?(sender)
        return super.draggingEntered(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        onDragHover?(nil)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        // NSView and NSTableView don't implement it (calling super would throw an unrecognized selector).
        if NSTableView.instancesRespond(to: #selector(NSTableView.draggingEnded(_:))) { super.draggingEnded(sender) }
        onDragEnded?()
    }

    // MARK: Quick Look panel control

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        quickLookPane?() != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        guard let pane = quickLookPane?() else { return }
        QuickLookController.shared.keyTarget = self
        QuickLookController.shared.take(panel, pane: pane)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLookController.shared.release(panel)
    }
}
