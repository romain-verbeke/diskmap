import AppKit
import DiskMapCore
import Observation
import SwiftUI

struct ListRow: Identifiable {
    let id: NodeID
    let name: String
    let sizeText: String
    let fraction: Double
    let color: Color
    let isFolder: Bool
    let note: String?
}

struct Crumb: Identifiable {
    let id: NodeID
    let name: String
}

struct SelectionInfo {
    let id: NodeID
    let name: String
    let path: String
    let sizeText: String
    let percent: Double
    let isFolder: Bool
}

enum SidebarTab: String, CaseIterable, Identifiable {
    case contents = "Contents"
    case cleanup = "Cleanup"
    var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
    private(set) var tree: FileTree?
    private(set) var isScanning = false
    private(set) var isRestoring = false
    /// Full path of the folder the map is showing.
    private(set) var currentPath = ""
    /// When the results on screen were scanned.
    private(set) var scanDate: Date?
    private(set) var stats = ScanStats()
    private(set) var currentRoot: NodeID = FileTree.root
    private(set) var selected: NodeID?
    private(set) var crumbs: [Crumb] = []
    private(set) var rows: [ListRow] = []
    private(set) var listIntro = ""
    private(set) var selection: SelectionInfo?
    private(set) var hasMoreRows = false
    private(set) var totalSize: UInt64 = 0
    private(set) var volumeUsed: Int64 = 0
    private(set) var volumeTotal: Int64 = 0
    private(set) var hoverText = ""
    /// Bumped whenever the map's contents change.
    private(set) var revision = 0

    var colorMode: ColorMode = .fileType { didSet { refresh() } }
    var tab: SidebarTab = .contents { didSet { refresh() } }
    var query = "" { didSet { queryChanged() } }

    private var scanner: DiskScanner?
    private var pollTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchHits: [NodeID]?
    private var scanPath: String?
    private let rowLimit = 500
    private static let cacheQueue = DispatchQueue(label: "DiskMap.cache", qos: .utility)

    // MARK: Scanning

    /// `DiskMap <path>` scans right away. Otherwise the last finished scan is restored.
    func handleLaunch() {
        guard tree == nil, !isRestoring else { return }
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let path = arguments.first {
            scan(path: path)
        } else {
            restoreLastScan()
        }
    }

    private func restoreLastScan() {
        guard FileManager.default.fileExists(atPath: ScanCache.defaultURL.path) else { return }
        isRestoring = true
        Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { () -> ScanCache.LoadedScan? in
                do {
                    return try ScanCache.load()
                } catch {
                    // Damaged or from an older version. It can't be used, so remove it.
                    try? FileManager.default.removeItem(at: ScanCache.defaultURL)
                    return nil
                }
            }.value
            guard let self else { return }
            self.isRestoring = false
            // A scan the user started meanwhile wins. A missing folder (such as an
            // ejected volume) keeps its cache for next time but shows the start screen.
            guard self.tree == nil, let loaded,
                FileManager.default.fileExists(atPath: loaded.tree.rootPath)
            else { return }
            self.tree = loaded.tree
            self.scanPath = loaded.tree.rootPath
            self.scanDate = loaded.scanDate
            self.updateVolume(path: loaded.tree.rootPath)
            self.refresh()
        }
    }

    /// Saves in the background. Saves run in order, so the newest state ends up on disk.
    private func saveCache() {
        guard let tree, let scanDate else { return }
        Self.cacheQueue.async {
            do {
                try ScanCache.save(tree, scanDate: scanDate)
            } catch {
                NSLog("DiskMap could not save its scan cache: \(error)")
            }
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder or disk to scan"
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url { scan(path: url.path) }
    }

    func rescan() {
        if let scanPath { scan(path: scanPath) }
    }

    /// Stops any scan and returns to the start screen.
    func startOver() {
        scanner?.cancel()
        pollTask?.cancel()
        scanner = nil
        scanPath = nil
        scanDate = nil
        tree = nil
        isScanning = false
        stats = ScanStats()
        currentRoot = FileTree.root
        selected = nil
        selection = nil
        searchHits = nil
        query = ""
        tab = .contents
        crumbs = []
        rows = []
        hasMoreRows = false
        listIntro = ""
        hoverText = ""
        totalSize = 0
        volumeUsed = 0
        volumeTotal = 0
    }

    func scan(path: String) {
        scanner?.cancel()
        pollTask?.cancel()
        query = ""
        let scanner = DiskScanner(path: path)
        self.scanner = scanner
        scanPath = path
        scanDate = nil
        tree = scanner.tree
        currentRoot = FileTree.root
        selected = nil
        searchHits = nil
        isScanning = true
        updateVolume(path: path)
        refresh()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            scanner.run()
            DispatchQueue.main.async {
                guard let self = self, self.scanner === scanner else { return }
                self.isScanning = false
                self.scanDate = Date()
                self.pollTask?.cancel()
                self.refresh()
                self.saveCache()
            }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
                self?.refresh()
            }
        }
    }

    private func updateVolume(path: String) {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
            let total = values.volumeTotalCapacity,
            let free = values.volumeAvailableCapacityForImportantUsage
        else { return }
        volumeTotal = Int64(total)
        volumeUsed = Int64(total) - free
    }

    // MARK: Navigation

    func zoom(to node: NodeID) {
        currentRoot = node
        selected = nil
        query = ""
        tab = .contents
        refresh()
    }

    func goUp() {
        guard let tree, currentRoot != FileTree.root else { return }
        zoom(to: tree.read { $0.node(currentRoot).parent })
    }

    /// A single click selects the item. The "smaller items" block has no single item to select.
    func click(cell: TreemapCell) {
        guard cell.kind != .aggregate else { return }
        selected = cell.node
        refresh()
    }

    /// A double click zooms into that folder, or for a file, to the folder containing it.
    func doubleClick(cell: TreemapCell) {
        guard let tree else { return }
        switch cell.kind {
        case .frame, .header:
            zoom(to: cell.node)
        case .aggregate:
            if cell.node != currentRoot { zoom(to: cell.node) }
        case .tile:
            let (hasChildren, parent) = tree.read { reader in
                (!reader.sortedChildren(of: cell.node).isEmpty, reader.node(cell.node).parent)
            }
            if hasChildren {
                zoom(to: cell.node)
            } else {
                show(cell.node, in: parent)
            }
        }
    }

    func selectRow(_ row: ListRow) {
        guard let tree else { return }
        if tab == .contents && searchHits == nil {
            selected = row.id
            refresh()
        } else {
            show(row.id, in: tree.read { $0.node(row.id).parent })
        }
    }

    private func show(_ node: NodeID, in parent: NodeID) {
        currentRoot = parent
        selected = node
        refresh()
    }

    func setHover(cell: TreemapCell?) {
        guard let cell, let tree else {
            hoverText = ""
            return
        }
        let path = tree.read { $0.path(cell.node) }
        hoverText = cell.kind == .aggregate
            ? "\(cell.name) in \(path), \(formatBytes(cell.size))"
            : "\(path), \(formatBytes(cell.size))"
    }

    // MARK: Actions

    func revealSelection() {
        guard let selection else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: selection.path)])
    }

    /// Shows a folder's contents in Finder, or selects a file there.
    /// Apps and other packages are selected too, so this never launches anything.
    func openInFinder(_ node: NodeID) {
        guard let tree else { return }
        let (path, isDirectory) = tree.read { ($0.path(node), $0.node(node).kind == .directory) }
        let workspace = NSWorkspace.shared
        if isDirectory && !workspace.isFilePackage(atPath: path) {
            workspace.selectFile(nil, inFileViewerRootedAtPath: path)
        } else {
            workspace.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    func askGoogle(_ node: NodeID) {
        guard let tree else { return }
        let url = tree.read { reader -> URL? in
            let item = reader.node(node)
            let isRoot = node == FileTree.root
            let name = isRoot ? FileManager.default.displayName(atPath: tree.rootPath) : reader.name(node)
            let parent: String? = {
                if isRoot { return nil }
                return item.parent == FileTree.root
                    ? FileManager.default.displayName(atPath: tree.rootPath)
                    : reader.name(item.parent)
            }()
            return GoogleSearch.removalQuestionURL(name: name, parentName: parent, isFolder: item.kind == .directory)
        }
        if let url { NSWorkspace.shared.open(url) }
    }

    func trashSelection() {
        guard let selection, let tree, !isScanning else { return }
        let alert = NSAlert()
        alert.messageText = "Move “\(selection.name)” to the Trash?"
        alert.informativeText = "\(selection.path)\n\(selection.sizeText) will be freed when you empty the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: selection.path), resultingItemURL: nil)
            tree.remove(selection.id)
            selected = nil
            refresh()
            saveCache()
        } catch {
            let failure = NSAlert(error: error)
            failure.runModal()
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Search

    private func queryChanged() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let tree else {
            if searchHits != nil {
                searchHits = nil
                refresh()
            }
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
            let hits = await Task.detached(priority: .userInitiated) { tree.search(text) }.value
            if Task.isCancelled { return }
            self?.searchHits = hits
            self?.refresh()
        }
    }

    // MARK: Derived state

    private func refresh() {
        guard let tree else { return }
        stats = tree.currentStats
        let state = tree.read { reader -> (crumbs: [Crumb], total: UInt64, selection: SelectionInfo?) in
            var chain: [Crumb] = []
            var current = currentRoot
            while true {
                // Starting from the scanned path makes the row read as a full path.
                let name = current == FileTree.root ? tree.rootPath : reader.name(current)
                chain.insert(Crumb(id: current, name: name), at: 0)
                if current == FileTree.root { break }
                current = reader.node(current).parent
            }
            let total = reader.node(FileTree.root).size
            var info: SelectionInfo?
            if let selected, reader.isInside(selected) {
                let node = reader.node(selected)
                info = SelectionInfo(
                    id: selected, name: reader.name(selected), path: reader.path(selected),
                    sizeText: formatBytes(node.size),
                    percent: total > 0 ? Double(node.size) / Double(total) * 100 : 0,
                    isFolder: node.kind == .directory && node.childCount > 0)
            }
            return (chain, total, info)
        }
        crumbs = state.crumbs
        currentPath = tree.read { $0.path(currentRoot) }
        totalSize = state.total
        selection = state.selection
        buildRows(tree)
        revision += 1
    }

    private func buildRows(_ tree: FileTree) {
        var notes: [NodeID: String] = [:]
        var ids: [NodeID]
        if let searchHits {
            ids = searchHits
            listIntro = "\(ids.count) \(ids.count == 1 ? "match" : "matches")\(ids.count == 200 ? " (largest 200 shown)" : "")"
        } else if tab == .cleanup {
            let candidates = tree.cleanupCandidates()
            ids = candidates.map(\.node)
            for candidate in candidates { notes[candidate.node] = candidate.reason }
            let total = tree.read { reader in candidates.reduce(UInt64(0)) { $0 + reader.node($1.node).size } }
            listIntro = candidates.isEmpty
                ? "No rebuildable folders found yet."
                : "\(formatBytes(total)) you can probably remove. Review each item first."
        } else {
            ids = tree.read { $0.sortedChildren(of: currentRoot) }
            listIntro = "Largest first"
        }
        hasMoreRows = ids.count > rowLimit
        ids = Array(ids.prefix(rowLimit))

        rows = tree.read { reader in
            let largest = ids.reduce(UInt64(1)) { max($0, reader.node($1).size) }
            return ids.map { id in
                let node = reader.node(id)
                let isFolder = node.kind == .directory && node.childCount > 0
                let rgb = Palette.color(for: reader.dominantCategory(of: id))
                return ListRow(
                    id: id, name: reader.name(id), sizeText: formatBytes(node.size),
                    fraction: Double(node.size) / Double(largest),
                    color: Color(cgColor: rgb.cgColor), isFolder: isFolder,
                    note: notes[id] ?? (searchHits != nil ? reader.path(id) : nil))
            }
        }
    }
}
