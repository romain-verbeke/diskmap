import Foundation

public typealias NodeID = UInt32

public enum NodeKind: UInt8, Sendable {
    case file, directory, symlink, other
}

/// One file or folder. Kept small and free of references, because a disk can
/// hold millions of these and per-object reference counting would dominate.
public struct Node: Sendable {
    public var parent: NodeID
    public var firstChild: NodeID = 0
    public var childCount: UInt32 = 0
    var nameOffset: UInt32
    var nameLength: UInt16
    public var kind: NodeKind
    public var category: FileCategory
    public var isDeleted = false
    /// Latest modification time in this subtree, in seconds since 1970.
    public var modTime: UInt32
    /// Files in this subtree (1 for a file).
    public var fileCount: UInt32
    /// Allocated bytes in this subtree. Hard links count once.
    public var size: UInt64
}

/// A folder worth reviewing because its contents can usually be recreated.
public struct CleanupCandidate: Sendable {
    public let node: NodeID
    public let reason: String
}

public struct ScanStats: Sendable {
    public var files = 0
    public var directories = 0
    public var unreadableDirectories = 0
    public var isFinished = false

    public init() {}
}

/// The scanned tree, stored flat. Children of a folder sit next to each other,
/// and folder totals update as each folder is scanned, so the tree can be read
/// and drawn at any moment during a scan.
public final class FileTree: @unchecked Sendable {
    public static let root: NodeID = 0
    public let rootPath: String

    private let lock = NSLock()
    private var nodes: ContiguousArray<Node> = []
    private var names: ContiguousArray<UInt8> = []
    private var seenHardLinks = Set<HardLinkKey>()
    private var candidates: [CleanupCandidate] = []
    private var stats = ScanStats()

    struct HardLinkKey: Hashable {
        let device: Int32
        let fileID: UInt64
    }

    struct PendingEntry {
        var nameStart: Int
        var nameLength: Int
        var kind: NodeKind
        var category: FileCategory
        var modTime: UInt32
        var size: UInt64
        var hardLink: HardLinkKey?
    }

    public init(rootPath: String) {
        self.rootPath = rootPath
        let name = Array((rootPath as NSString).lastPathComponent.utf8)
        nodes.reserveCapacity(1 << 16)
        names.reserveCapacity(1 << 20)
        names.append(contentsOf: name)
        nodes.append(Node(
            parent: Self.root, nameOffset: 0, nameLength: UInt16(clamping: name.count),
            kind: .directory, category: .other, modTime: 0, fileCount: 0, size: 0))
    }

    /// Recreates a finished scan from the cache.
    init(
        rootPath: String, nodes: ContiguousArray<Node>, names: ContiguousArray<UInt8>,
        candidates: [CleanupCandidate], stats: ScanStats
    ) {
        self.rootPath = rootPath
        self.nodes = nodes
        self.names = names
        self.candidates = candidates
        self.stats = stats
    }

    /// A consistent copy for saving. Arrays are copy-on-write, so this is cheap.
    func snapshot() -> (nodes: ContiguousArray<Node>, names: ContiguousArray<UInt8>, candidates: [CleanupCandidate], stats: ScanStats) {
        lock.lock()
        defer { lock.unlock() }
        return (nodes, names, candidates, stats)
    }

    // MARK: Writing (scanner)

    /// Adds a folder's entries in one contiguous block and updates every ancestor's totals.
    /// Returns the ID of the first new node.
    func commit(parent: NodeID, entries: [PendingEntry], nameBytes: [UInt8]) -> NodeID {
        lock.lock()
        defer { lock.unlock() }

        let base = NodeID(nodes.count)
        var totalSize: UInt64 = 0
        var totalFiles: UInt32 = 0
        var latest: UInt32 = 0

        for entry in entries {
            var size = entry.size
            if let link = entry.hardLink, !seenHardLinks.insert(link).inserted {
                size = 0
            }
            let offset = UInt32(names.count)
            let length = min(entry.nameLength, Int(UInt16.max))
            nameBytes.withUnsafeBufferPointer { bytes in
                names.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[entry.nameStart..<(entry.nameStart + length)]))
            }
            let isDirectory = entry.kind == .directory
            nodes.append(Node(
                parent: parent, nameOffset: offset, nameLength: UInt16(length),
                kind: entry.kind, category: entry.category, modTime: entry.modTime,
                fileCount: isDirectory ? 0 : 1, size: size))
            totalSize += size
            if isDirectory {
                stats.directories += 1
            } else {
                totalFiles += 1
            }
            latest = max(latest, entry.modTime)
        }
        stats.files += Int(totalFiles)

        nodes[Int(parent)].firstChild = base
        nodes[Int(parent)].childCount = UInt32(entries.count)

        var current = parent
        while true {
            nodes[Int(current)].size += totalSize
            nodes[Int(current)].fileCount += totalFiles
            nodes[Int(current)].modTime = max(nodes[Int(current)].modTime, latest)
            if current == Self.root { break }
            current = nodes[Int(current)].parent
        }
        return base
    }

    func addCandidate(_ node: NodeID, reason: String) {
        lock.lock()
        candidates.append(CleanupCandidate(node: node, reason: reason))
        lock.unlock()
    }

    func noteUnreadableDirectory() {
        lock.lock()
        stats.unreadableDirectories += 1
        lock.unlock()
    }

    func markFinished() {
        lock.lock()
        stats.isFinished = true
        lock.unlock()
    }

    /// Removes a node from all totals, after its files were moved to the Trash.
    public func remove(_ id: NodeID) {
        lock.lock()
        defer { lock.unlock() }
        guard id != Self.root, !nodes[Int(id)].isDeleted else { return }
        let removed = nodes[Int(id)]
        nodes[Int(id)].isDeleted = true
        var current = removed.parent
        while true {
            nodes[Int(current)].size -= removed.size
            nodes[Int(current)].fileCount -= removed.fileCount
            if current == Self.root { break }
            current = nodes[Int(current)].parent
        }
    }

    // MARK: Reading

    /// Read access to the tree while it is locked. Keep the work short: the scanner waits.
    public struct Reader {
        fileprivate let tree: FileTree

        public func node(_ id: NodeID) -> Node { tree.nodes[Int(id)] }

        public func name(_ id: NodeID) -> String {
            let node = tree.nodes[Int(id)]
            let start = Int(node.nameOffset)
            return tree.names[start..<(start + Int(node.nameLength))]
                .withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) }
        }

        /// Non-deleted children with space on disk, largest first.
        public func sortedChildren(of id: NodeID) -> [NodeID] {
            let parent = tree.nodes[Int(id)]
            guard parent.childCount > 0 else { return [] }
            var result: [NodeID] = []
            result.reserveCapacity(Int(parent.childCount))
            for child in parent.firstChild..<(parent.firstChild + parent.childCount) {
                let node = tree.nodes[Int(child)]
                if !node.isDeleted && node.size > 0 { result.append(child) }
            }
            let nodes = tree.nodes
            result.sort { nodes[Int($0)].size > nodes[Int($1)].size }
            return result
        }

        /// Follows the largest child downward, to color a folder drawn as a single block.
        public func dominantCategory(of id: NodeID) -> FileCategory {
            var current = tree.nodes[Int(id)]
            if current.category != .other || current.kind != .directory { return current.category }
            for _ in 0..<6 {
                guard current.childCount > 0 else { break }
                var largest: Node?
                for child in current.firstChild..<(current.firstChild + current.childCount) {
                    let node = tree.nodes[Int(child)]
                    if !node.isDeleted, node.size > (largest?.size ?? 0) { largest = node }
                }
                guard let next = largest else { break }
                if next.category != .other || next.kind != .directory { return next.category }
                current = next
            }
            return .other
        }

        public func path(_ id: NodeID) -> String {
            var parts: [String] = []
            var current = id
            while current != FileTree.root {
                parts.append(name(current))
                current = tree.nodes[Int(current)].parent
            }
            let suffix = parts.reversed().joined(separator: "/")
            if suffix.isEmpty { return tree.rootPath }
            return tree.rootPath.hasSuffix("/") ? tree.rootPath + suffix : tree.rootPath + "/" + suffix
        }

        /// False when this node or any folder above it was removed.
        public func isInside(_ id: NodeID) -> Bool {
            var current = id
            while true {
                if tree.nodes[Int(current)].isDeleted { return false }
                if current == FileTree.root { return true }
                current = tree.nodes[Int(current)].parent
            }
        }

        public var nodeCount: Int { tree.nodes.count }
    }

    public func read<Result>(_ body: (Reader) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(Reader(tree: self))
    }

    public var currentStats: ScanStats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    /// Cleanup candidates still on disk, largest first.
    public func cleanupCandidates() -> [CleanupCandidate] {
        read { reader in
            candidates
                .filter { reader.isInside($0.node) && reader.node($0.node).size > 0 }
                .sorted { reader.node($0.node).size > reader.node($1.node).size }
        }
    }

    /// Case-insensitive name search across the whole tree, largest first.
    public func search(_ query: String, limit: Int = 200) -> [NodeID] {
        let needle = Array(query.lowercased().utf8)
        guard !needle.isEmpty else { return [] }
        let needleIsASCII = needle.allSatisfy { $0 < 0x80 }
        return read { reader in
            var hits: [NodeID] = []
            var buffer: [UInt8] = []
            for id in 1..<max(1, NodeID(nodes.count)) {
                let node = nodes[Int(id)]
                let length = Int(node.nameLength)
                guard node.size > 0 else { continue }
                let start = Int(node.nameOffset)
                let found: Bool
                if needleIsASCII {
                    guard length >= needle.count else { continue }
                    buffer.removeAll(keepingCapacity: true)
                    for byte in names[start..<(start + length)] {
                        buffer.append((byte >= 65 && byte <= 90) ? byte + 32 : byte)
                    }
                    found = buffer.withUnsafeBytes { hay in
                        needle.withUnsafeBytes { memmem(hay.baseAddress, hay.count, $0.baseAddress, $0.count) != nil }
                    }
                } else {
                    // Accents can be stored composed or decomposed, so bytes can't be compared.
                    // Only names that have non-ASCII bytes can match.
                    guard names[start..<(start + length)].contains(where: { $0 >= 0x80 }) else { continue }
                    found = reader.name(id).range(of: query, options: .caseInsensitive) != nil
                }
                if found && reader.isInside(id) { hits.append(id) }
            }
            hits.sort { nodes[Int($0)].size > nodes[Int($1)].size }
            return Array(hits.prefix(limit))
        }
    }
}

/// Decimal units, matching how Finder reports sizes.
public func formatBytes(_ bytes: UInt64) -> String {
    let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
    var value = Double(bytes)
    var index = 0
    while value >= 1000 && index < units.count - 1 {
        value /= 1000
        index += 1
    }
    if index == 0 { return "\(bytes) bytes" }
    return String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[index])
}
