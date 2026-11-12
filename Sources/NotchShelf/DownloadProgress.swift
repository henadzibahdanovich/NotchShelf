import Foundation

struct ActiveDownload: Identifiable, Equatable {
    let id: String          // путь к временному файлу
    var name: String
    var fraction: Double?   // nil — прогресс неизвестен
}

/// Прогресс загрузок. Браузеры публикуют его системно (так Finder рисует полоску на файле),
/// а если не публикуют — показываем хотя бы «качается…» по временному файлу.
@MainActor
final class DownloadProgressMonitor: ObservableObject {
    @Published private(set) var active: [ActiveDownload] = []

    private var subscriber: Any?
    private var observations: [String: NSKeyValueObservation] = [:]
    private var published: [String: ActiveDownload] = [:]
    private var partials: [String: ActiveDownload] = [:]

    func start(folder: URL) {
        stop()
        subscriber = Progress.addSubscriber(forFileURL: folder) { [weak self] progress in
            let url = progress.fileURL
            let key = url?.path ?? UUID().uuidString
            let name = Self.displayName(for: url)
            let observation = progress.observe(\.fractionCompleted, options: [.initial, .new]) { p, _ in
                let fraction: Double? = p.isIndeterminate ? nil : p.fractionCompleted
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.update(key: key, name: name, fraction: fraction) }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.observations[key] = observation }
            }
            return {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.finish(key: key) }
                }
            }
        }
    }

    func stop() {
        if let subscriber { Progress.removeSubscriber(subscriber) }
        subscriber = nil
        observations.removeAll()
        published.removeAll()
        partials.removeAll()
        rebuild()
    }

    /// Незавершённые файлы, которые видит FolderWatcher (.crdownload, .part, .download…).
    func setPartials(_ urls: [URL]) {
        var next: [String: ActiveDownload] = [:]
        for url in urls {
            next[url.path] = partials[url.path] ?? ActiveDownload(id: url.path, name: Self.displayName(for: url), fraction: nil)
        }
        partials = next
        // Если временного файла больше нет — системный прогресс тоже закончился
        for key in published.keys where !next.keys.contains(key) && !FileManager.default.fileExists(atPath: key) {
            published[key] = nil
            observations[key] = nil
        }
        rebuild()
    }

    private func update(key: String, name: String, fraction: Double?) {
        if let old = published[key], let a = old.fraction, let b = fraction, abs(a - b) < 0.01 { return }
        published[key] = ActiveDownload(id: key, name: name, fraction: fraction)
        rebuild()
    }

    private func finish(key: String) {
        published[key] = nil
        observations[key] = nil
        rebuild()
    }

    private func rebuild() {
        var merged = published
        for (key, item) in partials where merged[key] == nil && !merged.values.contains(where: { $0.name == item.name }) {
            merged[key] = item
        }
        let list = merged.values.sorted { $0.name < $1.name }
        if list != active { active = list }
    }

    /// Средний прогресс для «ушка» у чёлки.
    var overallFraction: Double? {
        let known = active.compactMap(\.fraction)
        guard !known.isEmpty, known.count == active.count else { return nil }
        return known.reduce(0, +) / Double(known.count)
    }

    nonisolated static func displayName(for url: URL?) -> String {
        guard var url else { return L("Download") }
        while FolderWatcher.partialExtensions.contains(url.pathExtension.lowercased()) {
            url.deletePathExtension()
        }
        let name = url.lastPathComponent
        return name.isEmpty ? L("Download") : name
    }
}
