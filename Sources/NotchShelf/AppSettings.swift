import Foundation
import ServiceManagement

/// Куда macOS сохраняет скриншоты.
enum ScreenshotFolder: String, CaseIterable, Identifiable {
    case downloads, desktop, dedicated
    var id: String { rawValue }

    var title: String {
        switch self {
        case .downloads: return "Загрузки"
        case .desktop: return "Рабочий стол"
        case .dedicated: return "Изображения → NotchShelf"
        }
    }

    var url: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .downloads: return home.appendingPathComponent("Downloads", isDirectory: true)
        case .desktop: return home.appendingPathComponent("Desktop", isDirectory: true)
        case .dedicated: return home.appendingPathComponent("Pictures/NotchShelf", isDirectory: true)
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    // Скриншоты
    @Published var screenshotFolder: ScreenshotFolder { didSet { d.set(screenshotFolder.rawValue, forKey: "screenshotFolder") } }
    /// Минуты до автоудаления незакреплённого скриншота. 0 = никогда.
    @Published var lifetimeMinutes: Int { didSet { d.set(lifetimeMinutes, forKey: "lifetimeMinutes") } }
    @Published var deleteAfterDrag: Bool { didSet { d.set(deleteAfterDrag, forKey: "deleteAfterDrag") } }
    @Published var hideSystemThumbnail: Bool { didSet { d.set(hideSystemThumbnail, forKey: "hideSystemThumbnail") } }

    // Загрузки
    @Published var trackDownloads: Bool { didSet { d.set(trackDownloads, forKey: "trackDownloads") } }
    /// Минуты, после которых загрузка уходит с полки. 0 = никогда.
    @Published var downloadShelfMinutes: Int { didSet { d.set(downloadShelfMinutes, forKey: "downloadShelfMinutes") } }
    @Published var trashDownloadsOnExpire: Bool { didSet { d.set(trashDownloadsOnExpire, forKey: "trashDownloadsOnExpire") } }
    @Published var trashDownloadsAfterDrag: Bool { didSet { d.set(trashDownloadsAfterDrag, forKey: "trashDownloadsAfterDrag") } }

    // Лоток, буфер обмена, музыка
    @Published var trayRemoveAfterDrag: Bool { didSet { d.set(trayRemoveAfterDrag, forKey: "trayRemoveAfterDrag") } }
    @Published var clipboardEnabled: Bool { didSet { d.set(clipboardEnabled, forKey: "clipboardEnabled") } }
    @Published var clipboardLimit: Int { didSet { d.set(clipboardLimit, forKey: "clipboardLimit") } }
    @Published var showNowPlaying: Bool { didSet { d.set(showNowPlaying, forKey: "showNowPlaying") } }

    // ИИ-помощник
    @Published var defaultAIProvider: AIProvider { didSet { d.set(defaultAIProvider.rawValue, forKey: "defaultAIProvider") } }
    @Published var claudeModel: String { didSet { d.set(claudeModel, forKey: "claudeModel") } }
    @Published var openAIModel: String { didSet { d.set(openAIModel, forKey: "openAIModel") } }
    /// Показывать островок при выделении текста в любом приложении.
    @Published var showOnSelection: Bool { didSet { d.set(showOnSelection, forKey: "showOnSelection") } }
    /// Для каких ИИ сохранён ключ.
    @Published private(set) var connectedProviders: Set<AIProvider> = []

    // Общие
    @Published var peekOnCapture: Bool { didSet { d.set(peekOnCapture, forKey: "peekOnCapture") } }
    @Published var pinnedPaths: Set<String> { didSet { d.set(Array(pinnedPaths), forKey: "pinnedPaths") } }

    var didOnboard: Bool {
        get { d.bool(forKey: "didOnboard") }
        set { d.set(newValue, forKey: "didOnboard") }
    }

    /// Миграция на версию 2 (скриншоты по умолчанию — в Загрузки).
    var didMigrateV2: Bool {
        get { d.bool(forKey: "didMigrateV2") }
        set { d.set(newValue, forKey: "didMigrateV2") }
    }

    private init() {
        d.register(defaults: [
            "screenshotFolder": ScreenshotFolder.downloads.rawValue,
            "lifetimeMinutes": 60,
            "deleteAfterDrag": true,
            "hideSystemThumbnail": true,
            "trackDownloads": true,
            "downloadShelfMinutes": 1440,
            "trashDownloadsOnExpire": false,
            "trashDownloadsAfterDrag": false,
            "peekOnCapture": true,
            "trayRemoveAfterDrag": true,
            "clipboardEnabled": true,
            "clipboardLimit": 50,
            "showNowPlaying": true,
            "defaultAIProvider": AIProvider.claude.rawValue,
            "claudeModel": AIProvider.claude.defaultModel,
            "openAIModel": AIProvider.chatgpt.defaultModel,
            "showOnSelection": false,
        ])
        screenshotFolder = ScreenshotFolder(rawValue: d.string(forKey: "screenshotFolder") ?? "") ?? .downloads
        lifetimeMinutes = d.integer(forKey: "lifetimeMinutes")
        deleteAfterDrag = d.bool(forKey: "deleteAfterDrag")
        hideSystemThumbnail = d.bool(forKey: "hideSystemThumbnail")
        trackDownloads = d.bool(forKey: "trackDownloads")
        downloadShelfMinutes = d.integer(forKey: "downloadShelfMinutes")
        trashDownloadsOnExpire = d.bool(forKey: "trashDownloadsOnExpire")
        trashDownloadsAfterDrag = d.bool(forKey: "trashDownloadsAfterDrag")
        peekOnCapture = d.bool(forKey: "peekOnCapture")
        trayRemoveAfterDrag = d.bool(forKey: "trayRemoveAfterDrag")
        clipboardEnabled = d.bool(forKey: "clipboardEnabled")
        clipboardLimit = d.integer(forKey: "clipboardLimit")
        showNowPlaying = d.bool(forKey: "showNowPlaying")
        defaultAIProvider = AIProvider(rawValue: d.string(forKey: "defaultAIProvider") ?? "") ?? .claude
        claudeModel = d.string(forKey: "claudeModel") ?? AIProvider.claude.defaultModel
        openAIModel = d.string(forKey: "openAIModel") ?? AIProvider.chatgpt.defaultModel
        showOnSelection = d.bool(forKey: "showOnSelection")
        pinnedPaths = Set(d.stringArray(forKey: "pinnedPaths") ?? [])
        refreshAIKeys()
    }

    /// Перечитать ключи из Связки ключей (после сохранения или удаления).
    func refreshAIKeys() {
        let connected = Set(AIProvider.allCases.filter { Keychain.get($0.keychainAccount) != nil })
        if connected != connectedProviders { connectedProviders = connected }
        ServicesMenuSync.apply(connected)
    }

    /// Подключённые ИИ в постоянном порядке: Claude, ChatGPT.
    var availableProviders: [AIProvider] {
        AIProvider.allCases.filter { connectedProviders.contains($0) }
    }

    /// ИИ по умолчанию, если у него есть ключ, иначе — первый подключённый.
    var preferredProvider: AIProvider? {
        connectedProviders.contains(defaultAIProvider) ? defaultAIProvider : availableProviders.first
    }

    func model(for provider: AIProvider) -> String {
        provider == .claude ? claudeModel : openAIModel
    }

    func setModel(_ model: String, for provider: AIProvider) {
        if provider == .claude { claudeModel = model } else { openAIModel = model }
    }

    func lifetime(for kind: ShelfKind) -> TimeInterval? {
        if kind == .tray { return nil }   // лоток не очищается сам
        let minutes = kind == .screenshot ? lifetimeMinutes : downloadShelfMinutes
        return minutes > 0 ? TimeInterval(minutes * 60) : nil
    }

    // MARK: Запуск при входе

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("NotchShelf: launch at login error: \(error)")
            }
            objectWillChange.send()
        }
    }
}
