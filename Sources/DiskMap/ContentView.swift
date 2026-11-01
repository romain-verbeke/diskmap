import AppKit
import Combine
import DiskMapCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.isRestoring {
            ProgressView("Loading your last scan…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.tree == nil {
            StartView(model: model)
                .navigationTitle("DiskMap")
        } else {
            results
        }
    }

    private var results: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 460)
        } detail: {
            MapPane(model: model)
        }
        .navigationTitle("DiskMap")
        .navigationSubtitle(model.currentPath)
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.goUp()
                } label: {
                    Label("Up one folder", systemImage: "chevron.left")
                }
                .disabled(model.currentRoot == FileTree.root)
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("Color by", selection: $model.colorMode) {
                    ForEach(ColorMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(model.tree == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.startOver()
                } label: {
                    Label("New Scan", systemImage: "plus")
                }
            }
        }
    }
}

/// Shown at launch: asks which volume or folder to scan.
private struct StartView: View {
    let model: AppModel
    @State private var volumes = ScanTargets.volumes()
    private let folders = ScanTargets.folders()

    private let mountChanges = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)
        .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification))

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("What do you want to scan?")
                    .font(.title2.weight(.semibold))

                TargetSection(title: "Volumes", targets: volumes) { model.scan(path: $0.path) }
                TargetSection(title: "Folders", targets: folders) { model.scan(path: $0.path) }

                Button("Choose Another Folder…") { model.chooseFolder() }
                    .controlSize(.large)
            }
            .padding(32)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onReceive(mountChanges) { _ in volumes = ScanTargets.volumes() }
    }
}

private struct TargetSection: View {
    let title: String
    let targets: [ScanTarget]
    let onPick: (ScanTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(targets.enumerated()), id: \.element.id) { index, target in
                    if index > 0 { Divider() }
                    TargetRow(target: target) { onPick(target) }
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct TargetRow: View {
    let target: ScanTarget
    let onPick: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 12) {
                Image(nsImage: target.icon)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(target.name)
                        .lineLimit(1)
                    if let detail = target.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(target.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let used = target.usedFraction {
                        ProgressView(value: used)
                            .accessibilityHidden(true)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.volumeTotal > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(formatBytes(UInt64(max(model.volumeUsed, 0)))) of \(formatBytes(UInt64(model.volumeTotal))) used on this disk")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: Double(max(model.volumeUsed, 0)), total: Double(model.volumeTotal))
                        .accessibilityLabel("Disk used")
                }
                .padding(.horizontal, 12)
            }
            Picker("List", selection: $model.tab) {
                ForEach(SidebarTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            Text(model.listIntro)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
            List {
                ForEach(model.rows) { row in
                    RowView(
                        row: row, isSelected: row.id == model.selected,
                        onSelect: { model.selectRow(row) },
                        onOpen: { model.zoom(to: row.id) })
                }
                if model.hasMoreRows {
                    Text("Showing the largest 500 items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .padding(.top, 10)
    }
}

private struct RowView: View {
    let row: ListRow
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(row.color)
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                        Text(row.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(row.sizeText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let note = row.note {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    GeometryReader { geometry in
                        Capsule()
                            .fill(row.color)
                            .frame(width: max(geometry.size.width * row.fraction, 2))
                    }
                    .frame(height: 3)
                    .accessibilityHidden(true)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if row.isFolder {
                Button(action: onOpen) {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Open \(row.name)")
            }
        }
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
    }
}

private struct MapPane: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Breadcrumbs(model: model)
            if model.stats.isFinished && model.stats.unreadableDirectories > 0 {
                AccessBanner(model: model)
            }
            TreemapView(
                tree: model.tree, root: model.currentRoot, selected: model.selected,
                colorMode: model.colorMode, revision: model.revision,
                onClick: { model.click(cell: $0) },
                onDoubleClick: { model.doubleClick(cell: $0) },
                onHover: { model.setHover(cell: $0) },
                onOpenInFinder: { model.openInFinder($0) },
                onAskGoogle: { model.askGoogle($0) })
            Legend(mode: model.colorMode)
            Divider()
            DetailBar(model: model)
        }
    }
}

private struct Breadcrumbs: View {
    let model: AppModel

    var body: some View {
        // Long paths shorten their earlier folders, so the current folder stays readable.
        HStack(spacing: 2) {
            ForEach(Array(model.crumbs.enumerated()), id: \.element.id) { index, crumb in
                let isCurrent = index == model.crumbs.count - 1
                if index > 0 && !model.crumbs[index - 1].name.hasSuffix("/") {
                    Text("/")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Button {
                    model.zoom(to: crumb.id)
                } label: {
                    Text(crumb.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .layoutPriority(isCurrent ? 1 : 0)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 30)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Current path")
    }
}

private struct AccessBanner: View {
    let model: AppModel

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("\(model.stats.unreadableDirectories) folders couldn’t be read, so totals are incomplete. Full Disk Access lets DiskMap include them.")
                .font(.callout)
            Spacer()
            Button("Open Privacy Settings") { model.openPrivacySettings() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.orange.opacity(0.12))
    }
}

private struct Legend: View {
    let mode: ColorMode

    private var entries: [(String, Color)] {
        switch mode {
        case .fileType:
            FileCategory.allCases.map { ($0.label, Color(cgColor: Palette.color(for: $0).cgColor)) }
        case .lastModified:
            Palette.ageBuckets.map { ($0.label, Color(cgColor: $0.color.cgColor)) }
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(entries, id: \.0) { entry in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(entry.1)
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Text(entry.0)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

private struct DetailBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            if let selection = model.selection {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(selection.name) · \(selection.sizeText) · \(selection.percent, specifier: "%.1f")% of this scan")
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(selection.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
                if selection.isFolder {
                    Button("Open") { model.zoom(to: selection.id) }
                }
                Button("Reveal in Finder") { model.revealSelection() }
                Button("Move to Trash…", role: .destructive) { model.trashSelection() }
                    .disabled(model.isScanning)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .lineLimit(1)
                    Text(model.hoverText.isEmpty ? "Click to select. Double-click to zoom in." : model.hoverText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if model.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 50)
    }

    private var summary: String {
        let count = model.stats.files.formatted()
        if model.isScanning {
            return "Scanning… \(count) files, \(formatBytes(model.totalSize))"
        }
        let total = "\(formatBytes(model.totalSize)) in \(count) files"
        guard let date = model.scanDate else { return total }
        return "\(total) · Scanned \(date.formatted(.relative(presentation: .named)))"
    }
}
