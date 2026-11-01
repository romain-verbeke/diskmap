import CoreGraphics

public struct TreemapCell: Sendable {
    public enum Kind: Sendable {
        /// A file, or a folder too small to open up.
        case tile
        /// Background of an opened folder.
        case frame
        /// Title strip of an opened folder.
        case header
        /// Many small items in `node` drawn together.
        case aggregate
    }

    public let kind: Kind
    public let node: NodeID
    public let rect: CGRect
    public let name: String
    public let size: UInt64
    public let category: FileCategory
    public let modTime: UInt32
}

public enum Treemap {
    public struct Options: Sendable {
        public var headerHeight: CGFloat = 18
        public var padding: CGFloat = 2
        public var minimumFolderSize = CGSize(width: 56, height: 46)
        /// Items smaller than this many square points are drawn together.
        public var minimumArea: CGFloat = 36
        /// Upper bound on cells, so drawing stays fast in any folder.
        public var maximumCells = 30_000

        public init() {}
    }

    /// Squarified layout (Bruls, Huizing, van Wijk). `values` must be sorted largest
    /// first. Returns one rectangle per value, in the same order, filling `rect`.
    public static func squarify(values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else {
            return values.map { _ in .zero }
        }
        let scale = Double(rect.width * rect.height) / total
        var result: [CGRect] = []
        result.reserveCapacity(values.count)

        var x = Double(rect.minX), y = Double(rect.minY)
        var width = Double(rect.width), height = Double(rect.height)
        var index = 0

        while index < values.count {
            let side = min(width, height)
            let rowStart = index
            var sum = 0.0
            var best = Double.infinity
            let largest = values[index] * scale

            while index < values.count {
                let area = values[index] * scale
                let next = sum + area
                let worst = max((side * side * largest) / (next * next), (next * next) / (side * side * area))
                if index > rowStart && worst > best { break }
                sum = next
                best = worst
                index += 1
            }

            let thickness = side > 0 ? sum / side : 0
            var offset = 0.0
            let isColumn = width >= height
            for item in rowStart..<index {
                let length = thickness > 0 ? (values[item] * scale) / thickness : 0
                if isColumn {
                    result.append(CGRect(x: x, y: y + offset, width: thickness, height: length))
                } else {
                    result.append(CGRect(x: x + offset, y: y, width: length, height: thickness))
                }
                offset += length
            }
            if isColumn {
                x += thickness
                width = max(width - thickness, 0)
            } else {
                y += thickness
                height = max(height - thickness, 0)
            }
        }
        return result
    }

    /// Lays out `root` to fit `size`, opening folders while they have room.
    public static func build(tree: FileTree, root: NodeID, size: CGSize, options: Options = Options()) -> [TreemapCell] {
        guard size.width > 0, size.height > 0 else { return [] }
        return tree.read { reader in
            var cells: [TreemapCell] = []
            layoutFolder(root, in: CGRect(origin: .zero, size: size), isRoot: true, reader: reader, options: options, cells: &cells)
            return cells
        }
    }

    private static func layoutFolder(
        _ id: NodeID, in rect: CGRect, isRoot: Bool,
        reader: FileTree.Reader, options: Options, cells: inout [TreemapCell]
    ) {
        let children = reader.sortedChildren(of: id)
        let node = reader.node(id)
        let total = children.reduce(0.0) { $0 + Double(reader.node($1).size) }
        guard total > 0 else { return }

        let inner = rect
        let scale = Double(inner.width * inner.height) / total
        var shown = children.count
        while shown > 1 && Double(reader.node(children[shown - 1]).size) * scale < Double(options.minimumArea) {
            shown -= 1
        }
        // Keep the group's area accurate when small items are combined.
        var values = children[..<shown].map { Double(reader.node($0).size) }
        var remainder: UInt64 = 0
        if shown < children.count {
            for child in children[shown...] { remainder += reader.node(child).size }
            values.append(Double(remainder))
        }
        // The group can be larger than the last item, so restore largest-first order.
        let order = values.indices.sorted { values[$0] > values[$1] }
        let rects = squarify(values: order.map { values[$0] }, in: inner)

        for (position, original) in order.enumerated() {
            let cellRect = rects[position]
            if original < shown {
                layoutItem(children[original], in: cellRect, reader: reader, options: options, cells: &cells)
            } else {
                cells.append(TreemapCell(
                    kind: .aggregate, node: id, rect: cellRect.insetBy(dx: 0.5, dy: 0.5),
                    name: "\(children.count - shown) smaller items", size: remainder,
                    category: .other, modTime: node.modTime))
            }
        }
    }

    private static func layoutItem(
        _ id: NodeID, in rect: CGRect,
        reader: FileTree.Reader, options: Options, cells: inout [TreemapCell]
    ) {
        let node = reader.node(id)
        let canOpen = node.kind == .directory && node.childCount > 0
            && rect.width >= options.minimumFolderSize.width
            && rect.height >= options.minimumFolderSize.height
            && cells.count < options.maximumCells

        if canOpen {
            // A folder holding only one folder shares a heading with it, like "Contents/UE/Paks".
            var opened = id
            var name = reader.name(id)
            while true {
                let children = reader.sortedChildren(of: opened)
                guard children.count == 1, reader.node(children[0]).kind == .directory,
                    reader.node(children[0]).childCount > 0
                else { break }
                opened = children[0]
                name += "/" + reader.name(opened)
            }
            let frame = rect.insetBy(dx: 0.5, dy: 0.5)
            cells.append(TreemapCell(kind: .frame, node: opened, rect: frame, name: "", size: node.size, category: node.category, modTime: node.modTime))
            cells.append(TreemapCell(
                kind: .header, node: opened,
                rect: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: options.headerHeight),
                name: name, size: node.size, category: node.category, modTime: node.modTime))
            let inner = CGRect(
                x: rect.minX + options.padding, y: rect.minY + options.headerHeight,
                width: rect.width - options.padding * 2,
                height: rect.height - options.headerHeight - options.padding)
            layoutFolder(opened, in: inner, isRoot: false, reader: reader, options: options, cells: &cells)
        } else {
            let hasLabel = rect.width >= 40 && rect.height >= 16
            cells.append(TreemapCell(
                kind: .tile, node: id, rect: rect.insetBy(dx: 0.5, dy: 0.5),
                name: hasLabel ? reader.name(id) : "", size: node.size,
                category: reader.dominantCategory(of: id), modTime: node.modTime))
        }
    }
}
