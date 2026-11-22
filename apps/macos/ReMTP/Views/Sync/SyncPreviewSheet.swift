import SwiftUI

// DEMO ONLY — the sync preview UI, driven by `SyncPreviewDemo` placeholder data.
// It is not connected to a sync engine: toggling items, the direction and the options only
// changes this sheet, and "Sync" just closes it. Wire it to the core's sync plan API later.

struct SyncPreviewSheet: View {
    let pair: SyncPairDemo
    let app: AppModel
    @Environment(\.dismiss) private var dismiss

    private enum Filter: Hashable { case changes, add, conflicts, onlyTarget, unchanged }

    @State private var reversed = false
    @State private var filter: Filter = .changes
    @State private var excluded: Set<String> = []
    @State private var choices: [String: ConflictResolution] = [:]
    @State private var afterCopying = 0
    @State private var verify = 1
    @State private var plan: SyncPlan?

    private var sourceSide: String { pair.kind == .music ? "Mac" : pair.deviceName }
    private var targetSide: String { pair.kind == .music ? pair.deviceName : "Mac" }
    private var fromSide: String { reversed ? targetSide : sourceSide }
    private var toSide: String { reversed ? sourceSide : targetSide }

    var body: some View {
        let plan = self.plan ?? SyncPreviewDemo.plan(for: pair, reversed: reversed)
        VStack(spacing: 0) {
            header(plan)
            spaceBar(plan)
            chips(plan)
            Divider()
            planList(plan).frame(height: 352)
            notes(plan)
            Divider()
            footer(plan)
        }
        .frame(width: 860)
        .onAppear { resetPlan() }
        .onChange(of: reversed) { resetPlan() }
    }

    private func resetPlan() {
        let fresh = SyncPreviewDemo.plan(for: pair, reversed: reversed)
        plan = fresh
        excluded = Set(fresh.items.filter(\.excludedByDefault).map(\.name))
        choices = [:]
    }

    // MARK: Header

    private func header(_ plan: SyncPlan) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
                .frame(width: 40, height: 40)
                .overlay { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 19, weight: .medium)).foregroundStyle(.tint) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Sync “\(reversed ? pair.targetName : pair.sourceName)”")
                    Text("→").foregroundStyle(.tertiary).fontWeight(.regular)
                    Text(reversed ? pair.sourceName : pair.targetName)
                }
                .font(.system(size: 16, weight: .bold))
                Text("\(pair.deviceName) › \(pair.devicePath) \(pair.kind == .music ? "←" : "→") \(pair.macPath) · compared \(plan.comparedFiles.formatted()) files in \(String(format: "%.1f", plan.comparedSeconds)) s. Nothing changes until you press Sync.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Picker("Direction", selection: $reversed) {
                Text("\(sourceSide) → \(targetSide)").tag(false)
                Text("\(targetSide) → \(sourceSide)").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: Space

    private func spaceBar(_ plan: SyncPlan) -> some View {
        let adds = selectedBytes(plan)
        let capacity = Double(max(plan.targetCapacity, 1))
        let free = plan.targetCapacity > plan.targetUsed + adds ? plan.targetCapacity - plan.targetUsed - adds : 0
        return VStack(alignment: .leading, spacing: 7) {
            BarGauge(fraction: Double(plan.targetUsed) / capacity, secondFraction: max(0.004, Double(adds) / capacity), height: 10)
            HStack(spacing: 16) {
                legend(Color.secondary.opacity(0.55), "\(toSide) used", Format.bytes(plan.targetUsed))
                legend(.accentColor, "This sync adds", Format.bytes(adds))
                legend(Color.primary.opacity(0.1), "Free afterwards", Format.bytes(free), suffix: " of \(Format.bytes(plan.targetCapacity))")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
    }

    private func legend(_ color: Color, _ label: String, _ value: String, suffix: String = "") -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(label) + Text(" \(value)").fontWeight(.semibold).foregroundStyle(.primary) + Text(suffix)
        }
    }

    // MARK: Filter chips

    private func chips(_ plan: SyncPlan) -> some View {
        let count = { (a: SyncPlanItem.Action) in plan.items.filter { $0.action == a }.count }
        return HStack(spacing: 6) {
            chip(.changes, "Changes", count(.add) + count(.update) + count(.conflict), dot: nil)
            chip(.add, "Add", count(.add) + count(.update), dot: .accentColor)
            chip(.conflicts, "Conflicts", count(.conflict), dot: .red)
            chip(.onlyTarget, "Only in \(reversed ? pair.sourceName : pair.targetName)", count(.onlyTarget), dot: .deviceTint)
            chip(.unchanged, "Unchanged", count(.unchanged), dot: .secondary)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
    }

    private func chip(_ value: Filter, _ title: String, _ count: Int, dot: Color?) -> some View {
        let on = filter == value
        return Button {
            filter = value
        } label: {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(title).font(.system(size: 12, weight: .medium))
                Text(count.formatted()).font(.system(size: 11)).monospacedDigit().opacity(0.7)
            }
            .foregroundStyle(on ? Color(nsColor: .windowBackgroundColor) : .primary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(on ? Color.primary : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Plan

    private func visible(_ plan: SyncPlan) -> [SyncPlanItem] {
        plan.items.filter { item in
            switch filter {
            case .changes: return [.add, .update, .conflict].contains(item.action)
            case .add: return item.action == .add || item.action == .update
            case .conflicts: return item.action == .conflict
            case .onlyTarget: return item.action == .onlyTarget
            case .unchanged: return item.action == .unchanged
            }
        }
    }

    private func planList(_ plan: SyncPlan) -> some View {
        let items = visible(plan)
        let groups = Dictionary(grouping: items, by: \.group)
        let order = items.reduce(into: [String]()) { if $0.last != $1.group, !$0.contains($1.group) { $0.append($1.group) } }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(order, id: \.self) { group in
                    Section {
                        ForEach(Array((groups[group] ?? []).enumerated()), id: \.element.id) { index, item in
                            planRow(item, striped: index % 2 == 1)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: pair.kind == .music ? "music.note.list" : "clock").font(.system(size: 11))
                            Text(group).fontWeight(.semibold)
                            Text("· \(Format.count(groups[group]?.count ?? 0, "file"))").foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                        .background(.background)
                    }
                }
                if items.isEmpty {
                    Text("Nothing here.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private func planRow(_ item: SyncPlanItem, striped: Bool) -> some View {
        let actionable = [.add, .update, .conflict].contains(item.action)
        let included = actionable && !excluded.contains(item.name)
        let fileItem = FileItem(name: item.name, isDirectory: false, size: item.size, modified: nil)
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { included },
                set: { on in if on { excluded.remove(item.name) } else { excluded.insert(item.name) } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!actionable)
                .opacity(actionable ? 1 : 0.3)
            FileIconView(item: fileItem, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(item.reason).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            .opacity(actionable && !included ? 0.45 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            actionView(item).frame(width: 150, alignment: .leading)
            Text(Format.bytes(item.size))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(striped ? Color.primary.opacity(0.03) : .clear))
    }

    @ViewBuilder
    private func actionView(_ item: SyncPlanItem) -> some View {
        switch item.action {
        case .add: actionLabel("Add", .accentColor)
        case .update: actionLabel("Update", .orange)
        case .onlyTarget: actionLabel("Leave", .deviceTint)
        case .unchanged: actionLabel("Same", .green)
        case .conflict:
            Picker("Conflict", selection: Binding(get: { choices[item.name] ?? .keepBoth }, set: { choices[item.name] = $0 })) {
                Text("Keep both").tag(ConflictResolution.keepBoth)
                Text("Replace").tag(ConflictResolution.replace)
                Text("Skip").tag(ConflictResolution.skip)
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }

    /// What happens to the file, as a label (the filter chips' dot and a word), not a button-like capsule.
    private func actionLabel(_ text: String, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12)).foregroundStyle(.primary)
        }
    }

    // MARK: Notes and footer

    private func notes(_ plan: SyncPlan) -> some View {
        let only = plan.items.filter { $0.action == .onlyTarget }.count
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(plan.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle").labelStyle(NoteLabelStyle(tint: .accentColor))
            }
            if only > 0 {
                HStack {
                    Label("\(Format.count(only, "file")) are only in \(reversed ? pair.sourceName : pair.targetName). They’ll be left alone.",
                          systemImage: "info.circle")
                        .labelStyle(NoteLabelStyle(tint: .accentColor))
                    Spacer()
                    Button("Show") { filter = .onlyTarget }.buttonStyle(.link)
                }
            }
            Label("Preview with demo data: the sync engine isn’t connected yet, so Sync doesn’t copy anything.",
                  systemImage: "exclamationmark.triangle")
                .labelStyle(NoteLabelStyle(tint: .orange))
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Divider() }
    }

    private func selectedItems(_ plan: SyncPlan) -> [SyncPlanItem] {
        plan.items.filter { item in
            guard [.add, .update, .conflict].contains(item.action), !excluded.contains(item.name) else { return false }
            return item.action != .conflict || (choices[item.name] ?? .keepBoth) != .skip
        }
    }

    private func selectedBytes(_ plan: SyncPlan) -> UInt64 {
        selectedItems(plan).reduce(0) { $0 + $1.size }
    }

    private func footer(_ plan: SyncPlan) -> some View {
        let selected = selectedItems(plan)
        return HStack(spacing: 14) {
            if toSide == "Mac" {
                HStack(spacing: 7) {
                    Text("After copying")
                    Picker("After copying", selection: $afterCopying) {
                        Text("Keep on \(pair.deviceName)").tag(0)
                        Text("Remove from \(pair.deviceName)").tag(1)
                    }
                    .labelsHidden()
                }
                .fixedSize()
            }
            HStack(spacing: 7) {
                Text("Verify")
                Picker("Verify", selection: $verify) {
                    Text("Size").tag(0)
                    Text("Size + checksum").tag(1)
                }
                .labelsHidden()
            }
            .fixedSize()
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Sync \(Format.count(selected.count, "File")) · \(Format.bytes(selectedBytes(plan)))") {
                // DEMO: not wired to a sync engine yet.
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(selected.isEmpty)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .controlSize(.regular)
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }
}

private struct NoteLabelStyle: LabelStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}
