import Darwin
import Foundation

/// Scans a folder in parallel using `getattrlistbulk`, which returns metadata for
/// a whole directory in batches instead of needing one `stat` call per file.
public final class DiskScanner: @unchecked Sendable {
    public let tree: FileTree
    private let path: String
    private let workerCount: Int

    private let condition = NSCondition()
    private var stack: [Work] = []
    private var active = 0
    private var cancelled = false

    private let classifier = CategoryClassifier()
    private var allowedDevices: Set<Int32> = []
    private var excludedPaths: Set<String> = []

    private struct Work {
        let node: NodeID
        let path: String
        let inherited: FileCategory?
        let insideCandidate: Bool
    }

    public init(path: String, workers: Int? = nil) {
        let standardized = (path as NSString).standardizingPath
        self.path = standardized
        self.tree = FileTree(rootPath: standardized)
        self.workerCount = workers ?? Self.defaultWorkerCount()
    }

    /// One worker per performance core: more than that measured slower on a 4+6 core Mac.
    private static func defaultWorkerCount() -> Int {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &cores, &size, nil, 0) != 0 || cores <= 0 {
            cores = Int32(ProcessInfo.processInfo.activeProcessorCount)
        }
        return min(max(Int(cores), 2), 8)
    }

    public func cancel() {
        condition.lock()
        cancelled = true
        stack.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    /// Scans until finished or cancelled. Blocks the calling thread.
    public func run() {
        configureVolumes()
        condition.lock()
        stack.append(Work(node: FileTree.root, path: path, inherited: nil, insideCandidate: false))
        condition.unlock()
        let count = workerCount
        DispatchQueue.concurrentPerform(iterations: count) { _ in self.workerLoop() }
        tree.markFinished()
    }

    /// Stays on the starting volume. `/` is two volumes on modern macOS, system and
    /// data, joined by firmlinks. Both are allowed, and the data volume's second
    /// location is skipped so its contents are not counted twice.
    private func configureVolumes() {
        var info = stat()
        if lstat(path, &info) == 0 { allowedDevices.insert(info.st_dev) }
        if path == "/" {
            let dataVolume = "/System/Volumes/Data"
            if lstat(dataVolume, &info) == 0 { allowedDevices.insert(info.st_dev) }
            excludedPaths.insert(dataVolume)
        }
    }

    private func workerLoop() {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 * 1024, alignment: 16)
        defer { buffer.deallocate() }
        var entries: [FileTree.PendingEntry] = []
        var nameBytes: [UInt8] = []

        while true {
            condition.lock()
            while stack.isEmpty && active > 0 && !cancelled { condition.wait() }
            guard !cancelled, let work = stack.popLast() else {
                condition.broadcast()
                condition.unlock()
                return
            }
            active += 1
            condition.unlock()

            let children = scan(work, buffer: buffer, entries: &entries, nameBytes: &nameBytes)

            condition.lock()
            active -= 1
            stack.append(contentsOf: children)
            condition.broadcast()
            condition.unlock()
        }
    }

    private struct Subfolder {
        let entryIndex: Int
        let path: String
        let inherited: FileCategory?
        let candidateReason: String?
        let insideCandidate: Bool
    }

    private func scan(
        _ work: Work, buffer: UnsafeMutableRawBufferPointer,
        entries: inout [FileTree.PendingEntry], nameBytes: inout [UInt8]
    ) -> [Work] {
        let fd = open(work.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            tree.noteUnreadableDirectory()
            return []
        }
        defer { close(fd) }

        entries.removeAll(keepingCapacity: true)
        nameBytes.removeAll(keepingCapacity: true)
        var subfolders: [Subfolder] = []

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FILEID)
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)

        readLoop: while true {
            let count = getattrlistbulk(fd, &request, buffer.baseAddress!, buffer.count, 0)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                tree.noteUnreadableDirectory()
                break readLoop
            }
            var entry = UnsafeRawPointer(buffer.baseAddress!)
            for _ in 0..<count {
                let length = entry.loadUnaligned(as: UInt32.self)
                parse(entry, work: work, entries: &entries, nameBytes: &nameBytes, subfolders: &subfolders)
                entry += Int(length)
            }
        }

        guard !entries.isEmpty else { return [] }
        let base = tree.commit(parent: work.node, entries: entries, nameBytes: nameBytes)

        return subfolders.map { folder in
            let id = base + NodeID(folder.entryIndex)
            if let reason = folder.candidateReason { tree.addCandidate(id, reason: reason) }
            return Work(node: id, path: folder.path, inherited: folder.inherited, insideCandidate: folder.insideCandidate)
        }
    }

    // Attributes arrive in a fixed order: length, returned set, error, name, device,
    // type, modification time, file ID, then file-only attributes.
    private func parse(
        _ entry: UnsafeRawPointer, work: Work,
        entries: inout [FileTree.PendingEntry], nameBytes: inout [UInt8], subfolders: inout [Subfolder]
    ) {
        var cursor = entry + MemoryLayout<UInt32>.size
        let returned = cursor.loadUnaligned(as: attribute_set_t.self)
        cursor += MemoryLayout<attribute_set_t>.size

        if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            let code = cursor.loadUnaligned(as: UInt32.self)
            cursor += 4
            if code != 0 { return }
        }
        guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else { return }
        let reference = cursor.loadUnaligned(as: attrreference_t.self)
        let namePointer = (cursor + Int(reference.attr_dataoffset)).assumingMemoryBound(to: UInt8.self)
        let nameLength = max(Int(reference.attr_length) - 1, 0)
        let name = UnsafeBufferPointer(start: namePointer, count: nameLength)
        cursor += MemoryLayout<attrreference_t>.size

        var device: Int32 = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_DEVID) != 0 {
            device = cursor.loadUnaligned(as: Int32.self)
            cursor += 4
        }
        var objectType: UInt32 = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            objectType = cursor.loadUnaligned(as: UInt32.self)
            cursor += 4
        }
        var modTime: UInt32 = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
            modTime = UInt32(clamping: cursor.loadUnaligned(as: Int.self))
            cursor += MemoryLayout<timespec>.size
        }
        var fileID: UInt64 = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 {
            fileID = cursor.loadUnaligned(as: UInt64.self)
            cursor += 8
        }

        let nameStart = nameBytes.count

        if objectType == UInt32(VDIR.rawValue) {
            guard allowedDevices.contains(device) else { return }
            let nameString = String(decoding: name, as: UTF8.self)
            let childPath = work.path.hasSuffix("/") ? work.path + nameString : work.path + "/" + nameString
            if !excludedPaths.isEmpty && excludedPaths.contains(childPath) { return }

            let inherited = work.inherited ?? Self.category(forFolder: nameString, path: childPath, rootIsVolume: path == "/")
            let reason = work.insideCandidate ? nil : Self.cleanupReason(folder: nameString, parentPath: work.path)
            nameBytes.append(contentsOf: name)
            subfolders.append(Subfolder(
                entryIndex: entries.count, path: childPath, inherited: inherited,
                candidateReason: reason, insideCandidate: work.insideCandidate || reason != nil))
            entries.append(FileTree.PendingEntry(
                nameStart: nameStart, nameLength: nameLength, kind: .directory,
                category: inherited ?? .other, modTime: modTime, size: 0, hardLink: nil))
            return
        }

        // Files and symlinks: symlinks are recorded, never followed.
        var linkCount: UInt32 = 1
        if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
            linkCount = cursor.loadUnaligned(as: UInt32.self)
            cursor += 4
        }
        var allocated: Int64 = 0
        if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
            allocated = cursor.loadUnaligned(as: Int64.self)
        }

        nameBytes.append(contentsOf: name)
        let kind: NodeKind = objectType == UInt32(VREG.rawValue) ? .file : (objectType == UInt32(VLNK.rawValue) ? .symlink : .other)
        entries.append(FileTree.PendingEntry(
            nameStart: nameStart, nameLength: nameLength, kind: kind,
            category: work.inherited ?? classifier.classify(name), modTime: modTime,
            size: UInt64(max(allocated, 0)),
            hardLink: linkCount > 1 ? .init(device: device, fileID: fileID) : nil))
    }

    private static func category(forFolder name: String, path: String, rootIsVolume: Bool) -> FileCategory? {
        switch name {
        case "Caches": return .cache
        case "node_modules", "DerivedData", ".git", "Pods", ".venv", "venv", "__pycache__", "CoreSimulator": return .developer
        default: break
        }
        if name.hasSuffix(".app") { return .apps }
        if name.hasSuffix(".photoslibrary") { return .images }
        if name.hasSuffix(".fcpbundle") { return .video }
        if rootIsVolume, ["/System", "/usr", "/bin", "/sbin", "/private", "/opt/local"].contains(path) { return .system }
        return nil
    }

    private static func cleanupReason(folder name: String, parentPath: String) -> String? {
        switch name {
        case "node_modules": return "Restore with your package manager."
        case "DerivedData": return "Xcode rebuilds this on the next build."
        case "Pods": return "Restore with pod install."
        case ".venv", "venv": return "Recreate from your Python requirements."
        case "__pycache__": return "Python recreates this automatically."
        case ".Trash": return "Already in the Trash. Empty it to free the space."
        case "Caches": return parentPath.hasSuffix("/Library") ? "Apps recreate these as needed." : nil
        default: return nil
        }
    }
}
