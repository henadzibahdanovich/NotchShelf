import Foundation

/// Следит за папкой и сообщает о новых готовых файлах.
/// Незавершённые загрузки (.crdownload, .part, .download…) пропускает, пока они не докачаются.
@MainActor
final class FolderWatcher {
    let folder: URL
    /// (файл, это скриншот?)
    private let onNew: (URL, Bool) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var known = Set<String>()
    private var pendingSizes: [String: Int] = [:]   // файлы, ждущие стабилизации размера
    private var pendingScan: DispatchWorkItem?
    /// Список незавершённых загрузок в папке (для индикатора прогресса).
    var onPartials: (([URL]) -> Void)?

    nonisolated static let partialExtensions: Set<String> = [
        "crdownload", "part", "partial", "download", "opdownload", "tmp", "temp", "dtapart", "!ut",
    ]

    init(folder: URL, onNew: @escaping (URL, Bool) -> Void) {
        self.folder = folder
        self.onNew = onNew
        // Всё, что уже лежит в папке, считаем «увиденным»
        for url in listEntries() { known.insert(url.path) }
    }

    func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("NotchShelf: cannot watch \(folder.path)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleScan(after: 0.15) }
        }
        let descriptor = fd
        src.setCancelHandler { close(descriptor) }
        src.resume()
        source = src
        scheduleScan(after: 0.1)   // сразу узнаём о загрузках, которые уже идут
    }

    func stop() {
        source?.cancel()
        source = nil
        fd = -1
        pendingScan?.cancel()
    }

    private func scheduleScan(after delay: TimeInterval) {
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
        pendingScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scan() {
        let entries = listEntries()
        let present = Set(entries.map(\.path))
        known.formIntersection(present)                       // забываем удалённые
        pendingSizes = pendingSizes.filter { present.contains($0.key) }

        onPartials?(entries.filter { Self.partialExtensions.contains($0.pathExtension.lowercased()) })

        var needsRecheck = false
        for url in entries where !known.contains(url.path) {
            if Self.partialExtensions.contains(url.pathExtension.lowercased()) { continue }

            // Скриншоты macOS появляются уже готовыми — показываем сразу
            if Self.isScreenshot(url) {
                known.insert(url.path)
                pendingSizes[url.path] = nil
                onNew(url, true)
                continue
            }

            // Обычный файл: ждём, пока докачается и размер перестанет меняться
            let size = Self.size(of: url)
            if size > 0, !hasPartialSibling(url), pendingSizes[url.path] == size {
                known.insert(url.path)
                pendingSizes[url.path] = nil
                onNew(url, false)
            } else {
                pendingSizes[url.path] = size
                needsRecheck = true
            }
        }
        if needsRecheck { scheduleScan(after: 1.0) }
    }

    private func listEntries() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
    }

    /// Firefox и др. создают пустой итоговый файл рядом с .part — ждём, пока .part исчезнет.
    private func hasPartialSibling(_ url: URL) -> Bool {
        let fm = FileManager.default
        return ["part", "crdownload", "download"].contains { fm.fileExists(atPath: url.path + "." + $0) }
    }

    static func size(of url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true { return 1 }   // папка (например, распакованный архив)
        return values?.fileSize ?? 0
    }

    /// macOS помечает скриншоты и записи экрана атрибутом kMDItemIsScreenCapture.
    static func isScreenshot(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
    }
}
