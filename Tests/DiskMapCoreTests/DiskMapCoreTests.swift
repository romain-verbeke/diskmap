import CoreGraphics
import Foundation
import Testing

@testable import DiskMapCore

@Suite struct SquarifyTests {
    @Test func fillsTheRectangleProportionally() {
        let rect = CGRect(x: 10, y: 20, width: 600, height: 400)
        let values: [Double] = [60, 25, 10, 3, 1, 1]
        let rects = Treemap.squarify(values: values, in: rect)
        #expect(rects.count == values.count)

        let area = rect.width * rect.height
        for (value, cell) in zip(values, rects) {
            #expect(abs(cell.width * cell.height - area * value / 100) < 0.01)
            #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(cell))
        }
    }

    @Test func cellsDoNotOverlap() {
        let rects = Treemap.squarify(values: [9, 8, 7, 6, 5, 4, 3, 2, 1], in: CGRect(x: 0, y: 0, width: 300, height: 700))
        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] {
                let overlap = a.intersection(b)
                #expect(overlap.isNull || overlap.width * overlap.height < 0.01)
            }
        }
    }

    @Test func handlesEmptyAndZeroInput() {
        #expect(Treemap.squarify(values: [], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
        #expect(Treemap.squarify(values: [0, 0], in: CGRect(x: 0, y: 0, width: 10, height: 10)) == [.zero, .zero])
    }
}

@Suite struct ScannerTests {
    /// Creates a temporary folder, resolved so paths match what the scanner reports.
    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diskmap-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
    }

    private func allocated(_ url: URL) throws -> UInt64 {
        UInt64(try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0)
    }

    @Test func totalsMatchAllocatedSizesAcrossFolders() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = ["a.bin", "sub/b.mov", "sub/deep/c.zip"].map { folder.appendingPathComponent($0) }
        for (index, file) in files.enumerated() { try write(file, bytes: 50_000 * (index + 1)) }
        let expected = try files.reduce(UInt64(0)) { $0 + (try allocated($1)) }

        let scanner = DiskScanner(path: folder.path)
        scanner.run()

        let stats = scanner.tree.currentStats
        #expect(stats.isFinished)
        #expect(stats.files == 3)
        #expect(stats.directories == 2)
        #expect(stats.unreadableDirectories == 0)
        #expect(scanner.tree.read { $0.node(FileTree.root).size } == expected)
    }

    @Test func hardLinksCountOnce() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("original.bin")
        try write(original, bytes: 200_000)
        try FileManager.default.linkItem(at: original, to: folder.appendingPathComponent("link.bin"))

        let scanner = DiskScanner(path: folder.path)
        scanner.run()

        #expect(scanner.tree.read { $0.node(FileTree.root).size } == (try allocated(original)))
    }

    @Test func symlinksAreNotFollowed() throws {
        let folder = try makeFolder()
        let outside = try makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: outside)
        }
        try write(outside.appendingPathComponent("big.bin"), bytes: 500_000)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("link"), withDestinationURL: outside)

        let scanner = DiskScanner(path: folder.path)
        scanner.run()

        #expect(scanner.tree.read { $0.node(FileTree.root).size } < 500_000)
        #expect(scanner.tree.currentStats.directories == 0)
    }

    @Test func removeUpdatesEveryAncestor() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(folder.appendingPathComponent("keep.bin"), bytes: 100_000)
        try write(folder.appendingPathComponent("sub/deep/remove.bin"), bytes: 300_000)
        let kept = try allocated(folder.appendingPathComponent("keep.bin"))

        let scanner = DiskScanner(path: folder.path)
        scanner.run()

        let tree = scanner.tree
        let sub = tree.read { reader in reader.sortedChildren(of: FileTree.root).first { reader.name($0) == "sub" } }
        let id = try #require(sub)
        tree.remove(id)

        #expect(tree.read { $0.node(FileTree.root).size } == kept)
        #expect(tree.read { $0.node(FileTree.root).fileCount } == 1)
        #expect(tree.read { $0.sortedChildren(of: FileTree.root).count } == 1)
    }

    @Test func classifiesAndFindsCleanupFolders() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(folder.appendingPathComponent("clip.MOV"), bytes: 10_000)
        try write(folder.appendingPathComponent("app/node_modules/pkg/index.mov"), bytes: 10_000)

        let scanner = DiskScanner(path: folder.path)
        scanner.run()

        let tree = scanner.tree
        let clip = tree.read { reader in reader.sortedChildren(of: FileTree.root).first { reader.name($0) == "clip.MOV" } }
        #expect(tree.read { $0.node(try! #require(clip)).category } == .video)

        // Only the outer folder is listed, and contents inherit its category.
        let candidates = tree.cleanupCandidates()
        #expect(candidates.count == 1)
        #expect(tree.read { $0.name(candidates[0].node) } == "node_modules")
        #expect(tree.read { $0.dominantCategory(of: candidates[0].node) } == .developer)
    }

    @Test func searchIsCaseInsensitive() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(folder.appendingPathComponent("sub/Holiday-Video.mp4"), bytes: 10_000)
        try write(folder.appendingPathComponent("other.txt"), bytes: 10_000)

        let scanner = DiskScanner(path: folder.path)
        scanner.run()

        let hits = scanner.tree.search("holiday")
        #expect(hits.count == 1)
        #expect(scanner.tree.read { $0.path(hits[0]) } == folder.appendingPathComponent("sub/Holiday-Video.mp4").path)
    }
}

@Suite struct ScanCacheTests {
    private func scannedFolder() throws -> (folder: URL, tree: FileTree) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("diskmap-tests-\(UUID().uuidString)").resolvingSymlinksInPath()
        let deep = folder.appendingPathComponent("app/node_modules/pkg")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 80_000).write(to: deep.appendingPathComponent("índex.js"))
        try Data(repeating: 1, count: 30_000).write(to: folder.appendingPathComponent("clip.mov"))
        let scanner = DiskScanner(path: folder.path)
        scanner.run()
        return (folder, scanner.tree)
    }

    @Test func roundTripRestoresTheWholeTree() throws {
        let (folder, tree) = try scannedFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("scan.cache")
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        try ScanCache.save(tree, scanDate: date, to: url)
        let loaded = try ScanCache.load(from: url)

        #expect(loaded.scanDate == date)
        #expect(loaded.tree.rootPath == tree.rootPath)
        #expect(loaded.tree.currentStats.files == 2)
        #expect(loaded.tree.currentStats.isFinished)
        #expect(loaded.tree.read { $0.node(FileTree.root).size } == tree.read { $0.node(FileTree.root).size })
        #expect(loaded.tree.cleanupCandidates().count == 1)
        #expect(loaded.tree.search("ÍNDEX").count == 1)
        #expect(loaded.tree.search("i\u{301}ndex").count == 1)
        let hit = try #require(loaded.tree.search("índex").first)
        #expect(loaded.tree.read { $0.path(hit) } == folder.appendingPathComponent("app/node_modules/pkg/índex.js").path)

        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func keepsRemovalsAndReplacesAnEarlierSave() throws {
        let (folder, tree) = try scannedFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("scan.cache")
        try ScanCache.save(tree, scanDate: Date(), to: url)

        let clip = try #require(tree.search("clip.mov").first)
        let remaining = tree.read { $0.node(FileTree.root).size - $0.node(clip).size }
        tree.remove(clip)
        try ScanCache.save(tree, scanDate: Date(), to: url)

        let loaded = try ScanCache.load(from: url)
        #expect(loaded.tree.read { $0.node(FileTree.root).size } == remaining)
        #expect(loaded.tree.search("clip.mov").isEmpty)
    }

    @Test func rejectsDamagedFiles() throws {
        let (folder, tree) = try scannedFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("scan.cache")
        try ScanCache.save(tree, scanDate: Date(), to: url)
        let good = try Data(contentsOf: url)

        // Cut short.
        try good.prefix(good.count - 10).write(to: url)
        #expect(throws: (any Error).self) { try ScanCache.load(from: url) }

        // Wrong magic.
        var wrongMagic = good
        wrongMagic[0] = 0
        try wrongMagic.write(to: url)
        #expect(throws: (any Error).self) { try ScanCache.load(from: url) }

        // Every byte of the node data set to an invalid value.
        let headerLength = Int(good.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) })
        let nodesStart = 12 + headerLength
        var badNodes = good
        for index in nodesStart..<(nodesStart + MemoryLayout<Node>.stride) { badNodes[index] = 0xFF }
        try badNodes.write(to: url)
        #expect(throws: (any Error).self) { try ScanCache.load(from: url) }
    }
}

@Suite struct GoogleSearchTests {
    private func question(_ url: URL?) throws -> String {
        let components = URLComponents(url: try #require(url), resolvingAgainstBaseURL: false)
        return try #require(components?.queryItems?.first { $0.name == "q" }?.value)
    }

    @Test func asksAboutTheFolderAndItsParent() throws {
        let url = GoogleSearch.removalQuestionURL(name: "DerivedData", parentName: "Developer", isFolder: true)
        #expect(url?.host == "www.google.com")
        #expect(try question(url) == "Can I safely delete the \"DerivedData\" folder in \"Developer\" on a Mac?")
    }

    @Test func keepsSpecialCharactersInNames() throws {
        let url = GoogleSearch.removalQuestionURL(name: "a+b & c#d?.zip", parentName: nil, isFolder: false)
        #expect(url?.absoluteString.contains("%2B") == true)
        #expect(try question(url) == "Can I safely delete the \"a+b & c#d?.zip\" file on a Mac?")
    }
}

@Suite struct TreemapBuildTests {
    @Test func combinesTinyItemsAndRespectsBounds() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("diskmap-tests-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(repeating: 1, count: 20_000_000).write(to: folder.appendingPathComponent("huge.bin"))
        for index in 0..<200 {
            try Data(repeating: 1, count: 4096).write(to: folder.appendingPathComponent("small-\(index).bin"))
        }

        let scanner = DiskScanner(path: folder.path)
        scanner.run()

        let size = CGSize(width: 400, height: 300)
        let cells = Treemap.build(tree: scanner.tree, root: FileTree.root, size: size)
        #expect(cells.count < 50)
        #expect(cells.contains { $0.kind == .aggregate })
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -1, dy: -1)
        for cell in cells { #expect(bounds.contains(cell.rect)) }
    }
}
