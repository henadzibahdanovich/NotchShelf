import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

enum ShelfKind: String, Codable {
    case screenshot, download, tray
}

enum ShelfFilter: String, CaseIterable, Identifiable {
    case all, screenshots, downloads, tray, clipboard
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return L("All")
        case .screenshots: return L("Screenshots")
        case .downloads: return L("Downloads")
        case .tray: return L("Tray")
        case .clipboard: return L("Clipboard")
        }
    }
}

struct ShotItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let kind: ShelfKind
    let addedAt: Date
    var thumbnail: NSImage?
    var isPinned: Bool
    /// Файл создан самим NotchShelf (текст/ссылка/картинка, брошенные в лоток) — можно удалять.
    var owned = false

    var name: String { url.lastPathComponent }
    var isVideo: Bool { ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) }
    var isImage: Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false }

    static func == (a: ShotItem, b: ShotItem) -> Bool {
        a.id == b.id && a.isPinned == b.isPinned && a.thumbnail === b.thumbnail
    }
}

/// То, что сохраняем между запусками.
private struct SavedEntry: Codable {
    let path: String
    let kind: ShelfKind
    let addedAt: Date
    var owned: Bool?
}

@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShotItem] = [] { didSet { save() } }   // новые — первыми
    @Published var filter: ShelfFilter = .all
    @Published var toast: String?
    /// Срабатывает при появлении нового файла (для «выглядывания» полки).
    var onNewItem: (() -> Void)?

    let settings: AppSettings
    private var expiryTimer: Timer?
    private var toastWork: DispatchWorkItem?
    private var restoring = false

    init(settings: AppSettings) {
        self.settings = settings
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireOld() }
        }
    }

    nonisolated static var trayDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchShelf/Tray", isDirectory: true)
    }

    /// Карточки с учётом выбранного раздела.
    var visibleItems: [ShotItem] {
        switch filter {
        case .all: return items
        case .screenshots: return items.filter { $0.kind == .screenshot }
        case .downloads: return items.filter { $0.kind == .download }
        case .tray: return items.filter { $0.kind == .tray }
        case .clipboard: return []
        }
    }

    // MARK: Добавление и восстановление

    func add(url: URL, kind: ShelfKind, addedAt: Date = Date(), announce: Bool = true, owned: Bool = false) {
        guard !items.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return }
        let item = ShotItem(url: url, kind: kind, addedAt: addedAt, thumbnail: nil,
                            isPinned: settings.pinnedPaths.contains(url.path), owned: owned)
        items.insert(item, at: 0)
        items.sort { $0.addedAt > $1.addedAt }
        loadThumbnail(for: item)
        if announce {
            // Новый файл — показываем раздел, где он точно виден
            if kind == .tray { filter = .tray }
            else if filter != .all { filter = .all }
            if kind != .tray { onNewItem?() }
        }
    }

    /// Возвращает полку после перезапуска приложения.
    func restore() {
        guard let data = UserDefaults.standard.data(forKey: "shelfEntries"),
              let saved = try? JSONDecoder().decode([SavedEntry].self, from: data) else { return }
        restoring = true
        for entry in saved where FileManager.default.fileExists(atPath: entry.path) {
            add(url: URL(fileURLWithPath: entry.path), kind: entry.kind, addedAt: entry.addedAt,
                announce: false, owned: entry.owned ?? false)
        }
        restoring = false
        save()
        expireOld()
    }

    private func save() {
        guard !restoring else { return }
        let entries = items.map { SavedEntry(path: $0.url.path, kind: $0.kind, addedAt: $0.addedAt, owned: $0.owned) }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: "shelfEntries")
        }
    }

    private func loadThumbnail(for item: ShotItem) {
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: 320, height: 220),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all   // для «неизображений» вернётся хотя бы иконка
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let idx = self.items.firstIndex(where: { $0.id == item.id }) else { return }
                    self.items[idx].thumbnail = rep?.nsImage ?? NSWorkspace.shared.icon(forFile: item.url.path)
                }
            }
        }
    }

    // MARK: Действия

    func togglePin(_ item: ShotItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].isPinned.toggle()
        if items[idx].isPinned { settings.pinnedPaths.insert(item.url.path) }
        else { settings.pinnedPaths.remove(item.url.path) }
        showToast(items[idx].isPinned ? L("Pinned — it won’t leave the shelf on its own") : L("Unpinned"))
    }

    /// В Корзину (явное действие пользователя).
    func delete(_ item: ShotItem) {
        remove(item)
        trashFile(item.url)
    }

    /// Убрать с полки. Чужой файл остаётся на месте, наш собственный (из лотка) удаляется.
    func dismiss(_ item: ShotItem) {
        remove(item)
        if item.owned { try? FileManager.default.removeItem(at: item.url) }
    }

    /// Вызывается после успешного перетаскивания в другое приложение.
    func handleDropped(_ item: ShotItem) {
        guard !item.isPinned else { return }
        if item.kind == .tray {
            guard settings.trayRemoveAfterDrag else { return }
            remove(item)
            if item.owned {
                let url = item.url
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            return
        }
        let shouldTrash = item.kind == .screenshot ? settings.deleteAfterDrag : settings.trashDownloadsAfterDrag
        if item.kind == .screenshot && !shouldTrash { return }  // скриншот остаётся, если автоудаление выключено
        remove(item)
        guard shouldTrash else { return }
        // Даём принимающему приложению время прочитать файл, потом — в Корзину
        let url = item.url
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            MainActor.assumeIsolated { self.trashFile(url) }
        }
    }

    func copy(_ item: ShotItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        // Текст и ссылки из лотка копируем как текст
        if item.owned, let text = Self.textContent(of: item.url) {
            pb.setString(text, forType: .string)
            showToast(L("Copied to clipboard"))
            return
        }
        let entry = NSPasteboardItem()
        if item.isImage, let image = NSImage(contentsOf: item.url), let tiff = image.tiffRepresentation {
            if let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                entry.setData(png, forType: .png)
            }
            entry.setData(tiff, forType: .tiff)
        }
        entry.setString(item.url.absoluteString, forType: .fileURL)
        pb.writeObjects([entry])
        showToast(L("Copied to clipboard"))
    }

    func copyText(_ item: ShotItem) {
        showToast(L("Recognizing text…"), sticky: true)
        TextRecognizer.recognize(url: item.url) { [weak self] text in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let text, !text.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    self.showToast(L("Text copied"))
                } else {
                    self.showToast(L("No text found"))
                }
            }
        }
    }

    func open(_ item: ShotItem) {
        NSWorkspace.shared.open(item.url)
    }

    func revealInFinder(_ item: ShotItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// Кнопка «очистить» в шапке: скриншоты — в Корзину, загрузки и лоток — просто с полки.
    func clearVisible() {
        let targets = visibleItems.filter { !$0.isPinned }
        guard !targets.isEmpty else { return }
        var trashed = 0
        for item in targets {
            if item.kind == .tray {
                dismiss(item)
            } else if item.kind == .screenshot || settings.trashDownloadsOnExpire {
                delete(item); trashed += 1
            } else {
                dismiss(item)
            }
        }
        showToast(trashed > 0 ? L("Shelf cleared · moved to Trash: %@", "\(trashed)") : L("Shelf cleared"))
    }

    func clearUnpinned() {
        filter = .all
        clearVisible()
    }

    func remainingTime(for item: ShotItem, now: Date = Date()) -> TimeInterval? {
        guard !item.isPinned, let life = settings.lifetime(for: item.kind) else { return nil }
        return max(0, life - now.timeIntervalSince(item.addedAt))
    }

    // MARK: Внутреннее

    private func expireOld() {
        // Убираем то, что удалили или переместили в Finder
        let missing = items.filter { !FileManager.default.fileExists(atPath: $0.url.path) }
        if !missing.isEmpty { items.removeAll { m in missing.contains { $0.id == m.id } } }

        let now = Date()
        for item in items where !item.isPinned {
            guard let life = settings.lifetime(for: item.kind), now.timeIntervalSince(item.addedAt) > life else { continue }
            if item.kind == .screenshot || settings.trashDownloadsOnExpire { delete(item) }
            else { dismiss(item) }
        }
    }

    // MARK: Лоток: приём перетаскиваемого

    /// Принимает файлы, картинки, ссылки и текст, брошенные на полку.
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self.add(url: url, kind: .tray) }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                accepted = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let png = NSImage(data: data)?.pngData else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self.saveToTray(data: png, name: L("Image"), ext: "png") }
                    }
                }
            } else if provider.canLoadObject(ofClass: URL.self) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self.saveLinkToTray(url) }
                    }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                accepted = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text, !text.isEmpty else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            let title = String(text.prefix(30)).components(separatedBy: .newlines).first ?? L("Text")
                            self.saveToTray(data: Data(text.utf8), name: title, ext: "txt")
                        }
                    }
                }
            }
        }
        return accepted
    }

    private func saveLinkToTray(_ url: URL) {
        if url.isFileURL { add(url: url, kind: .tray); return }
        let plist: [String: String] = ["URL": url.absoluteString]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        saveToTray(data: data, name: url.host ?? L("Link"), ext: "webloc")
    }

    private func saveToTray(data: Data, name: String, ext: String) {
        let dir = Self.trayDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        var url = dir.appendingPathComponent((safe.isEmpty ? L("File") : safe) + "." + ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(safe) \(n).\(ext)")
            n += 1
        }
        do {
            try data.write(to: url)
            add(url: url, kind: .tray, owned: true)
        } catch {
            NSLog("NotchShelf: tray save failed \(error)")
        }
    }

    /// Текст из .txt или адрес из .webloc.
    nonisolated static func textContent(of url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "txt":
            return try? String(contentsOf: url, encoding: .utf8)
        case "webloc":
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return nil }
            return plist["URL"] as? String
        default:
            return nil
        }
    }

    private func remove(_ item: ShotItem) {
        items.removeAll { $0.id == item.id }
        settings.pinnedPaths.remove(item.url.path)
    }

    private func trashFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        catch { NSLog("NotchShelf: trash failed \(error)") }
    }

    func showToast(_ text: String, sticky: Bool = false) {
        toastWork?.cancel()
        toast = text
        guard !sticky else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.toast = nil }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }
}
