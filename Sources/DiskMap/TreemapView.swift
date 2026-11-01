import AppKit
import DiskMapCore
import SwiftUI

struct TreemapView: NSViewRepresentable {
    let tree: FileTree?
    let root: NodeID
    let selected: NodeID?
    let colorMode: ColorMode
    let revision: Int
    let onClick: @MainActor (TreemapCell) -> Void
    let onDoubleClick: @MainActor (TreemapCell) -> Void
    let onHover: @MainActor (TreemapCell?) -> Void
    let onOpenInFinder: @MainActor (NodeID) -> Void
    let onAskGoogle: @MainActor (NodeID) -> Void

    func makeNSView(context: Context) -> TreemapNSView { TreemapNSView() }

    func updateNSView(_ view: TreemapNSView, context: Context) {
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onHover = onHover
        view.onOpenInFinder = onOpenInFinder
        view.onAskGoogle = onAskGoogle
        view.update(tree: tree, root: root, selected: selected, colorMode: colorMode, revision: revision)
    }
}

/// Draws the map with Core Graphics and rebuilds the layout off the main thread.
final class TreemapNSView: NSView {
    var onClick: (@MainActor (TreemapCell) -> Void)?
    var onDoubleClick: (@MainActor (TreemapCell) -> Void)?
    var onHover: (@MainActor (TreemapCell?) -> Void)?
    var onOpenInFinder: (@MainActor (NodeID) -> Void)?
    var onAskGoogle: (@MainActor (NodeID) -> Void)?

    private var menuNode: NodeID?
    private var tree: FileTree?
    private var root: NodeID = FileTree.root
    private var selected: NodeID?
    private var colorMode: ColorMode = .fileType
    private var revision = -1

    private var cells: [TreemapCell] = []
    private var cellsSize: CGSize = .zero
    private var hovered: Int?
    private var trackingArea: NSTrackingArea?

    private var latestRequest = 0
    private var isBuilding = false
    private static let layoutQueue = DispatchQueue(label: "DiskMap.layout", qos: .userInteractive)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(tree: FileTree?, root: NodeID, selected: NodeID?, colorMode: ColorMode, revision: Int) {
        let needsLayout = tree !== self.tree || root != self.root || revision != self.revision
        let needsDraw = selected != self.selected || colorMode != self.colorMode
        self.tree = tree
        self.root = root
        self.selected = selected
        self.colorMode = colorMode
        self.revision = revision
        if needsLayout { rebuild() }
        if needsDraw { needsDisplay = true }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuild()
    }

    private func rebuild() {
        latestRequest += 1
        guard !isBuilding else { return }  // the finishing build starts the latest request
        guard let tree, bounds.width > 0, bounds.height > 0 else {
            cells = []
            needsDisplay = true
            return
        }
        isBuilding = true
        let request = latestRequest
        let root = self.root
        let size = bounds.size
        Self.layoutQueue.async { [weak self] in
            let result = Treemap.build(tree: tree, root: root, size: size)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBuilding = false
                self.cells = result
                self.cellsSize = size
                self.hovered = nil
                self.needsDisplay = true
                if request != self.latestRequest { self.rebuild() }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(dirtyRect)

        var style = TreemapRenderer.Style()
        style.colorMode = colorMode
        style.isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        style.selected = selected
        style.hovered = hovered
        if cellsSize.width > 0 && cellsSize.height > 0 {
            style.scaleX = bounds.width / cellsSize.width
            style.scaleY = bounds.height / cellsSize.height
        }
        TreemapRenderer.draw(cells, in: context, dirtyRect: dirtyRect, style: style)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func cellIndex(at point: CGPoint) -> Int? {
        guard cellsSize.width > 0, cellsSize.height > 0 else { return nil }
        let mapped = CGPoint(
            x: point.x * cellsSize.width / bounds.width,
            y: point.y * cellsSize.height / bounds.height)
        return cells.indices.reversed().first { cells[$0].rect.contains(mapped) }
    }

    private func displayRect(_ index: Int) -> CGRect {
        let rect = cells[index].rect
        let scaleX = bounds.width / cellsSize.width
        let scaleY = bounds.height / cellsSize.height
        return CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY, width: rect.width * scaleX, height: rect.height * scaleY)
            .insetBy(dx: -2, dy: -2)
    }

    override func mouseMoved(with event: NSEvent) {
        let index = cellIndex(at: convert(event.locationInWindow, from: nil))
        guard index != hovered else { return }
        if let hovered, hovered < cells.count { setNeedsDisplay(displayRect(hovered)) }
        hovered = index
        if let index {
            setNeedsDisplay(displayRect(index))
            onHover?(cells[index])
        } else {
            onHover?(nil)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if let hovered, hovered < cells.count { setNeedsDisplay(displayRect(hovered)) }
        hovered = nil
        onHover?(nil)
    }

    // Right-click or Control-click. A "smaller items" block acts on the folder holding them.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = cellIndex(at: convert(event.locationInWindow, from: nil)) else { return nil }
        menuNode = cells[index].node
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open in Finder", action: #selector(openInFinderChosen), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Ask Google", action: #selector(askGoogleChosen), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        return menu
    }

    @objc private func openInFinderChosen() {
        if let menuNode { onOpenInFinder?(menuNode) }
    }

    @objc private func askGoogleChosen() {
        if let menuNode { onAskGoogle?(menuNode) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let index = cellIndex(at: convert(event.locationInWindow, from: nil)) else { return }
        switch event.clickCount {
        case 1: onClick?(cells[index])
        case 2: onDoubleClick?(cells[index])
        default: break
        }
    }
}
