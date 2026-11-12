import AppKit
import SwiftUI

/// Прозрачный слой поверх превью: тянет файл наружу и знает, приняли ли его.
struct DragSource: NSViewRepresentable {
    let url: URL
    let image: NSImage?
    var onDragStart: () -> Void
    var onDragEnd: (_ accepted: Bool) -> Void
    var onClick: () -> Void
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> DragSourceNSView {
        let v = DragSourceNSView()
        update(v)
        return v
    }

    func updateNSView(_ nsView: DragSourceNSView, context: Context) {
        update(nsView)
    }

    private func update(_ v: DragSourceNSView) {
        v.url = url
        v.image = image
        v.onDragStart = onDragStart
        v.onDragEnd = onDragEnd
        v.onClick = onClick
        v.onDoubleClick = onDoubleClick
    }
}

final class DragSourceNSView: NSView, NSDraggingSource {
    var url: URL?
    var image: NSImage?
    var onDragStart: (() -> Void)?
    var onDragEnd: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var mouseDownEvent: NSEvent?
    private var didDrag = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        didDrag = false
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag && event.clickCount == 1 { onClick?() }
        mouseDownEvent = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didDrag, let url, let down = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard dx * dx + dy * dy > 9 else { return }
        didDrag = true

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let preview = image ?? NSWorkspace.shared.icon(forFile: url.path)
        let size = fittedSize(preview.size, max: 160)
        let local = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: local.x - size.width / 2, y: local.y - size.height / 2,
                                     width: size.width, height: size.height),
                              contents: preview)
        onDragStart?()
        let session = beginDraggingSession(with: [item], event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragEnd?(operation != [])
    }

    private func fittedSize(_ s: NSSize, max m: CGFloat) -> NSSize {
        guard s.width > 0, s.height > 0 else { return NSSize(width: m, height: m) }
        let k = min(m / s.width, m / s.height)
        return NSSize(width: s.width * k, height: s.height * k)
    }
}
