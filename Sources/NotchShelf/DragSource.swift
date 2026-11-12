import AppKit
import SwiftUI

/// Перетаскивание файла из полки наружу. Запускается жестом SwiftUI на карточке, а саму
/// сессию ведёт AppKit — так мы узнаём, приняло ли файл другое приложение.
/// (Отдельные AppKit-виды поверх каждой карточки не используются: внутри прокрутки и стеклянных
/// контейнеров их положение не совпадает с карточками на экране.)
@MainActor
final class FileDragController: NSObject, NSDraggingSource {
    static let shared = FileDragController()
    private var active = false
    private var onEnd: ((Bool) -> Void)?
    private weak var sourceWindow: NSWindow?

    /// Вызывать из DragGesture.onChanged — пока обрабатывается событие мыши.
    func begin(url: URL, image: NSImage?, onStart: () -> Void, onEnd: @escaping (Bool) -> Void) {
        guard !active,
              let event = NSApp.currentEvent,
              event.type == .leftMouseDragged || event.type == .leftMouseDown,
              let window = event.window,
              let view = window.contentView else { return }
        active = true
        self.onEnd = onEnd
        sourceWindow = window

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let preview = image ?? NSWorkspace.shared.icon(forFile: url.path)
        let size = Self.fittedSize(preview.size, max: 160)
        let p = view.convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: p.x - size.width / 2, y: p.y - size.height / 2,
                                     width: size.width, height: size.height),
                              contents: preview)
        onStart()
        let session = view.beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : .copy
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                                     operation: NSDragOperation) {
        let accepted = operation != []
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // Брошено внутрь самой полки (например, в лоток) — это не «использование» файла
                let droppedInside = self.sourceWindow?.frame.contains(screenPoint) ?? false
                let callback = self.onEnd
                self.onEnd = nil
                self.active = false
                callback?(accepted && !droppedInside)
            }
        }
    }

    private static func fittedSize(_ s: NSSize, max m: CGFloat) -> NSSize {
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
