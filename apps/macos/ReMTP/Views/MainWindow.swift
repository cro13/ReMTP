import SwiftUI

struct MainWindow: View {
    @Bindable var app: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(app: app)
                .navigationSplitViewColumnWidth(min: 200, ideal: 244, max: 340)
        } detail: {
            TransferArea(app: app) {
                HStack(spacing: 0) {
                    panes
                    if app.inspectorVisible {
                        Divider()
                        InspectorView(app: app)
                            .frame(width: 300)
                            .transition(.move(edge: .trailing))
                    }
                }
            }
            .toolbar(id: app.isDemo ? "main-demo" : "main") { MainToolbar(app: app) }
            .navigationTitle(app.windowTitle)
            .navigationSubtitle(app.windowSubtitle)
            .searchable(text: $app.searchText, placement: .toolbar, prompt: "Filter")
            .background(ToolbarItemLabels())
        }
        .sheet(item: $app.syncPreview) { pair in
            SyncPreviewSheet(pair: pair, app: app)
        }
        .frame(minWidth: 1100, minHeight: 600)
    }

    /// Identity follows the pane, so swapping moves the tables instead of rebuilding them.
    private var panes: some View {
        let ordered = [app.leftPane, app.rightPane]
        return GeometryReader { geometry in
            let width = geometry.size.width - 1
            let listWidth = FileTableCoordinator.deviceListComfortWidth
            let deviceWidth = app.inspectorVisible && app.devicePaneBrowsable && app.devicePane.viewMode == .list && width >= listWidth + 300
                ? max(width / 2, listWidth) : width / 2
            HStack(spacing: 0) {
                ForEach(Array(ordered.enumerated()), id: \.element.kind) { index, pane in
                    if index > 0 { Divider().frame(width: 1) }
                    PaneView(pane: pane, app: app)
                        .frame(width: max(300, pane.kind == .device ? deviceWidth : width - deviceWidth))
                        .anchorPreference(key: PaneBoundsKey.self, value: .bounds) { [pane.kind: $0] }
                        #if DEBUG
                        .snapshotFrame(.pane(pane.kind))
                        #endif
                }
            }
        }
    }
}

struct PaneBoundsKey: PreferenceKey {
    static let defaultValue: [PaneKind: Anchor<CGRect>] = [:]

    static func reduce(value: inout [PaneKind: Anchor<CGRect>], nextValue: () -> [PaneKind: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
