import AppKit

/// Shows one page, or two side by side with a draggable divider.
final class ContentAreaView: NSView {
    private(set) var leading: NSView?
    private(set) var trailing: NSView?
    private var fraction: CGFloat = 0.5
    private let divider = DividerView()
    var onFractionChange: ((Double) -> Void)?
    private var pendingFraction: Double?
    private var lastPublished: TimeInterval = 0

    private func publishFraction() {
        guard let value = pendingFraction else { return }
        pendingFraction = nil
        lastPublished = ProcessInfo.processInfo.systemUptime
        onFractionChange?(value)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        divider.isHidden = true
        divider.onDrag = { [weak self] x in
            guard let self, self.bounds.width > 0 else { return }
            let value = min(max(x / self.bounds.width, 0.2), 0.8)
            self.fraction = value
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
            // The store (and everything observing it) hears about it at most ~10 times a second
            // while dragging, and always about the final position.
            self.pendingFraction = Double(value)
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastPublished >= 0.1 { self.publishFraction() }
        }
        divider.onDragEnd = { [weak self] in self?.publishFraction() }
        addSubview(divider)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(leading newLeading: NSView?, trailing newTrailing: NSView?, fraction newFraction: Double) {
        for old in [leading, trailing] {
            if let old, old !== newLeading, old !== newTrailing, old.superview === self { old.removeFromSuperview() }
        }
        leading = newLeading
        trailing = newTrailing
        fraction = CGFloat(newFraction)
        for view in [newLeading, newTrailing] {
            if let view, view.superview !== self {
                view.removeFromSuperview()
                view.autoresizingMask = []
                addSubview(view, positioned: .below, relativeTo: divider)
            }
        }
        divider.isHidden = newTrailing == nil
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        guard let leading else { return }
        guard let trailing else { leading.frame = bounds; return }
        let gap: CGFloat = 1
        let split = (bounds.width * fraction).rounded()
        leading.frame = NSRect(x: 0, y: 0, width: split, height: bounds.height)
        trailing.frame = NSRect(x: split + gap, y: 0, width: bounds.width - split - gap, height: bounds.height)
        divider.frame = NSRect(x: split - 3, y: 0, width: 7, height: bounds.height)
    }
}

private final class DividerView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 3, y: 0, width: 1, height: bounds.height).fill()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil).x)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) { onDragEnd?() }
}
