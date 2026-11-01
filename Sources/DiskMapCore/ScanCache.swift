import Foundation

/// Saves a finished scan to one file and loads it back much faster than rescanning.
///
/// Layout: magic, header length, JSON header, raw nodes, name bytes. Everything read
/// back is validated, so a damaged or outdated file is rejected rather than trusted.
public enum ScanCache {
    public enum CacheError: Error {
        case invalidFile
    }

    public struct LoadedScan: Sendable {
        public let tree: FileTree
        public let scanDate: Date
    }

    private static let magic = Array("DISKMAP1".utf8)
    private static let formatVersion = 1

    private struct Header: Codable {
        struct Candidate: Codable {
            let node: UInt32
            let reason: String
        }
        let version: Int
        let nodeStride: Int
        let nodeCount: Int
        let nameByteCount: Int
        let scanDate: Date
        let rootPath: String
        let files: Int
        let directories: Int
        let unreadableDirectories: Int
        let candidates: [Candidate]
    }

    /// Default location, in the user's Caches folder.
    public static var defaultURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiskMap", isDirectory: true)
            .appendingPathComponent("last-scan.diskmapcache")
    }

    /// Writes to a temporary file first, so a crash or quit never leaves a partial cache.
    /// The file lists file names, so only the current user can read it.
    public static func save(_ tree: FileTree, scanDate: Date, to url: URL = defaultURL) throws {
        let snapshot = tree.snapshot()
        let header = Header(
            version: formatVersion, nodeStride: MemoryLayout<Node>.stride,
            nodeCount: snapshot.nodes.count, nameByteCount: snapshot.names.count,
            scanDate: scanDate, rootPath: tree.rootPath,
            files: snapshot.stats.files, directories: snapshot.stats.directories,
            unreadableDirectories: snapshot.stats.unreadableDirectories,
            candidates: snapshot.candidates.map { .init(node: $0.node, reason: $0.reason) })
        let headerData = try JSONEncoder().encode(header)

        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            var headerLength = UInt32(headerData.count).littleEndian
            try handle.write(contentsOf: magic)
            try handle.write(contentsOf: Data(bytes: &headerLength, count: 4))
            try handle.write(contentsOf: headerData)
            try snapshot.nodes.withUnsafeBytes { try handle.write(contentsOf: $0) }
            try snapshot.names.withUnsafeBytes { try handle.write(contentsOf: $0) }
            try handle.close()
            _ = try manager.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    public static func load(from url: URL = defaultURL) throws -> LoadedScan {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> LoadedScan in
            let prefix = magic.count + 4
            guard raw.count >= prefix, raw.prefix(magic.count).elementsEqual(magic) else { throw CacheError.invalidFile }
            let headerLength = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: magic.count, as: UInt32.self)))
            guard raw.count - prefix >= headerLength else { throw CacheError.invalidFile }
            let header = try JSONDecoder().decode(
                Header.self, from: Data(raw[prefix..<(prefix + headerLength)]))

            let stride = MemoryLayout<Node>.stride
            guard header.version == formatVersion, header.nodeStride == stride,
                header.nodeCount >= 1, header.nameByteCount >= 0,
                header.nodeCount <= (raw.count - prefix - headerLength) / stride
            else { throw CacheError.invalidFile }
            let nodesStart = prefix + headerLength
            let nodesLength = header.nodeCount * stride
            guard raw.count == nodesStart + nodesLength + header.nameByteCount else { throw CacheError.invalidFile }

            let nodeBytes = UnsafeRawBufferPointer(rebasing: raw[nodesStart..<(nodesStart + nodesLength)])
            guard isValid(nodeBytes, count: header.nodeCount, nameByteCount: header.nameByteCount) else {
                throw CacheError.invalidFile
            }

            let nodes = ContiguousArray<Node>(unsafeUninitializedCapacity: header.nodeCount) { buffer, count in
                UnsafeMutableRawBufferPointer(buffer).copyMemory(from: nodeBytes)
                count = header.nodeCount
            }
            let names = ContiguousArray(raw[(nodesStart + nodesLength)...])

            guard header.candidates.allSatisfy({ Int($0.node) < header.nodeCount }) else { throw CacheError.invalidFile }
            var stats = ScanStats()
            stats.files = header.files
            stats.directories = header.directories
            stats.unreadableDirectories = header.unreadableDirectories
            stats.isFinished = true

            let tree = FileTree(
                rootPath: header.rootPath, nodes: nodes, names: names,
                candidates: header.candidates.map { CleanupCandidate(node: $0.node, reason: $0.reason) },
                stats: stats)
            return LoadedScan(tree: tree, scanDate: header.scanDate)
        }
    }

    /// Checks raw bytes before they become `Node` values, because an out-of-range
    /// enum or index from a damaged file would otherwise be undefined behavior or a crash.
    private static func isValid(_ bytes: UnsafeRawBufferPointer, count: Int, nameByteCount: Int) -> Bool {
        guard let parent = MemoryLayout<Node>.offset(of: \Node.parent),
            let firstChild = MemoryLayout<Node>.offset(of: \Node.firstChild),
            let childCount = MemoryLayout<Node>.offset(of: \Node.childCount),
            let nameOffset = MemoryLayout<Node>.offset(of: \Node.nameOffset),
            let nameLength = MemoryLayout<Node>.offset(of: \Node.nameLength),
            let kind = MemoryLayout<Node>.offset(of: \Node.kind),
            let category = MemoryLayout<Node>.offset(of: \Node.category),
            let isDeleted = MemoryLayout<Node>.offset(of: \Node.isDeleted)
        else { return false }

        let stride = MemoryLayout<Node>.stride
        let maxKind = NodeKind.other.rawValue
        let maxCategory = FileCategory.allCases.last!.rawValue
        for index in 0..<count {
            let base = index * stride
            guard bytes[base + kind] <= maxKind,
                bytes[base + category] <= maxCategory,
                bytes[base + isDeleted] <= 1,
                Int(bytes.loadUnaligned(fromByteOffset: base + parent, as: UInt32.self)) < count
            else { return false }
            let first = Int(bytes.loadUnaligned(fromByteOffset: base + firstChild, as: UInt32.self))
            let children = Int(bytes.loadUnaligned(fromByteOffset: base + childCount, as: UInt32.self))
            guard first + children <= count else { return false }
            let start = Int(bytes.loadUnaligned(fromByteOffset: base + nameOffset, as: UInt32.self))
            let length = Int(bytes.loadUnaligned(fromByteOffset: base + nameLength, as: UInt16.self))
            guard start + length <= nameByteCount else { return false }
        }
        return true
    }
}
