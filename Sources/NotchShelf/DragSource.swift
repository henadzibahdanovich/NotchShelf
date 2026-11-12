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
        context == .outsideApplication ? [.copy, .generic] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Брошено внутрь самой полки (например, в лоток) — это не «использование» файла
        let droppedInside = window?.frame.contains(screenPoint) ?? false
        onDragEnd?(operation != [] && !droppedInside)
    }

    private func fittedSize(_ s: NSSize, max m: CGFloat) -> NSSize {
        guard s.width > 0, s.height > 0 else { return NSSize(width: m, height: m) }
        let k = min(m / s.width, m / s.height)
        return NSSize(width: s.width * k, height: s.height * k)
    }
}

// MARK: - Приём файлов, перетащенных на панель вопроса

/// Прозрачная AppKit-подложка, принимающая файлы и картинки. Надёжнее, чем .onDrop в SwiftUI
/// внутри плавающей панели, и умеет «обещанные» файлы (например, из приложения Фото).
struct FileDropCatcher: NSViewRepresentable {
    var onTargetChange: (Bool) -> Void
    var onDropFiles: ([URL]) -> Void
    var onDropImageData: ([Data]) -> Void

    func makeNSView(context: Context) -> DropCatcherView {
        let v = DropCatcherView()
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff,
                                                    NSPasteboard.PasteboardType("public.jpeg"),
                                                    NSPasteboard.PasteboardType("public.heic")]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        v.registerForDraggedTypes(types)
        update(v)
        return v
    }

    func updateNSView(_ nsView: DropCatcherView, context: Context) { update(nsView) }

    private func update(_ v: DropCatcherView) {
        v.onTargetChange = onTargetChange
        v.onDropFiles = onDropFiles
        v.onDropImageData = onDropImageData
    }
}

final class DropCatcherView: NSView {
    var onTargetChange: ((Bool) -> Void)?
    var onDropFiles: (([URL]) -> Void)?
    var onDropImageData: (([Data]) -> Void)?

    private static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
    ]

    private func canAccept(_ info: NSDraggingInfo) -> Bool {
        let pb = info.draggingPasteboard
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        if pb.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) { return true }
        return pb.availableType(from: Self.imageTypes) != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAccept(sender) else { return [] }
        onTargetChange?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAccept(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetChange?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargetChange?(false)
        let pb = sender.draggingPasteboard

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            onDropFiles?(urls)
            return true
        }

        // «Обещанные» файлы: приложение Фото, некоторые браузеры
        if let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("NotchShelfDrops/\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let queue = OperationQueue()
            for receiver in receivers {
                receiver.receivePromisedFiles(atDestination: dest, options: [:], operationQueue: queue) { [weak self] url, error in
                    guard error == nil else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.onDropFiles?([url]) }
                    }
                }
            }
            return true
        }

        if let type = pb.availableType(from: Self.imageTypes), let data = pb.data(forType: type) {
            onDropImageData?([data])
            return true
        }
        return false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onTargetChange?(false)
    }
}
