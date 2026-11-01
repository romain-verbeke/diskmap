// Scans a folder and prints totals and timing. Optionally renders the treemap to a PNG.
// Usage: diskmap-cli <path> [--png out.png] [--workers N]
import CoreGraphics
import DiskMapCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

var arguments = Array(CommandLine.arguments.dropFirst())
var pngPath: String?
var workers: Int?

if let index = arguments.firstIndex(of: "--png"), index + 1 < arguments.count {
    pngPath = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
}
if let index = arguments.firstIndex(of: "--workers"), index + 1 < arguments.count {
    workers = Int(arguments[index + 1])
    arguments.removeSubrange(index...(index + 1))
}
var cachePath: String?
if let index = arguments.firstIndex(of: "--cache"), index + 1 < arguments.count {
    cachePath = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
}
guard let path = arguments.first else {
    print("Usage: diskmap-cli <path> [--png out.png] [--workers N] [--cache file]")
    exit(2)
}

let start = Date()
let scanner = DiskScanner(path: path, workers: workers)
scanner.run()
let elapsed = Date().timeIntervalSince(start)

let stats = scanner.tree.currentStats
let (size, nodeCount) = scanner.tree.read { ($0.node(FileTree.root).size, $0.nodeCount) }
print("path:        \(scanner.tree.rootPath)")
print("allocated:   \(size) bytes (\(formatBytes(size)))")
print("files:       \(stats.files)")
print("folders:     \(stats.directories)")
print("unreadable:  \(stats.unreadableDirectories)")
print("nodes:       \(nodeCount)")
print(String(format: "scan time:   %.3f s", elapsed))
print(String(format: "throughput:  %.0f entries/s", Double(nodeCount) / max(elapsed, 0.001)))

let largest = scanner.tree.read { reader in
    reader.sortedChildren(of: FileTree.root).prefix(10).map { (reader.name($0), reader.node($0).size) }
}
for (name, bytes) in largest {
    print("  \(formatBytes(bytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(name)")
}

if let cachePath {
    let url = URL(fileURLWithPath: cachePath)
    let saveStart = Date()
    try ScanCache.save(scanner.tree, scanDate: Date(), to: url)
    let loadStart = Date()
    let loaded = try ScanCache.load(from: url)
    let loadEnd = Date()
    let bytes = (try? FileManager.default.attributesOfItem(atPath: cachePath)[.size] as? Int) ?? 0
    let restored = loaded.tree.read { ($0.node(FileTree.root).size, $0.nodeCount) }
    print(String(format: "cache save:  %.3f s", loadStart.timeIntervalSince(saveStart)))
    print(String(format: "cache load:  %.3f s", loadEnd.timeIntervalSince(loadStart)))
    print("cache file:  \(formatBytes(UInt64(bytes)))")
    print("restored:    \(restored.0) bytes, \(restored.1) nodes, matches: \(restored.0 == size && restored.1 == nodeCount)")
}

let canvas = CGSize(width: 1200, height: 760)
let layoutStart = Date()
let cells = Treemap.build(tree: scanner.tree, root: FileTree.root, size: canvas)
print(String(format: "layout:      %.1f ms, %d cells", Date().timeIntervalSince(layoutStart) * 1000, cells.count))

if let pngPath {
    guard let context = CGContext(
        data: nil, width: Int(canvas.width) * 2, height: Int(canvas.height) * 2, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("Could not create image context") }
    context.scaleBy(x: 2, y: 2)
    context.translateBy(x: 0, y: canvas.height)
    context.scaleBy(x: 1, y: -1)
    let drawStart = Date()
    TreemapRenderer.draw(cells, in: context, dirtyRect: CGRect(origin: .zero, size: canvas), style: .init())
    print(String(format: "draw:        %.1f ms", Date().timeIntervalSince(drawStart) * 1000))
    let url = URL(fileURLWithPath: pngPath) as CFURL
    guard let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("Could not create PNG") }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("png:         \(pngPath)")
}
