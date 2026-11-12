import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let settings = AppSettings.shared
    lazy var store = ShelfStore(settings: settings)
    lazy var clipboard = ClipboardHistory(settings: settings)
    lazy var player = NowPlaying(settings: settings)
    let timer = FocusTimer()
    let downloads = DownloadProgressMonitor()
    lazy var ask = AskModel(settings: settings)
    let services = ServiceProvider()
    let selectionWatcher = SelectionWatcher()
    private var askClaudeItem: NSMenuItem?
    private var askChatGPTItem: NSMenuItem?
    private var cancellables = Set<AnyCancellable>()
    var watchers: [FolderWatcher] = []
    var shelf: ShelfController?
    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let firstLaunch = !settings.didOnboard
        if firstLaunch {
            // Без миниатюры в углу скриншот появляется на полке мгновенно
            ScreenCaptureConfig.setFloatingThumbnail(enabled: false)
            settings.hideSystemThumbnail = true
            settings.didOnboard = true
        }
        if !settings.didMigrateV2 {
            // Версия 2: скриншоты и загрузки живут в одной папке — «Загрузки»
            settings.screenshotFolder = .downloads
            ScreenCaptureConfig.setLocation(.downloads)
            settings.didMigrateV2 = true
        }

        let models = ShelfModels(store: store, clipboard: clipboard, player: player,
                                 timer: timer, downloads: downloads, ask: ask, settings: settings)
        shelf = ShelfController(models: models, settings: settings) { [weak self] in
            self?.openSettings()
        }
        store.restore()
        startWatchers()
        setupStatusItem()

        // «Спросить Claude / ChatGPT» в меню Службы (правый клик по выделенному тексту)
        services.onAsk = { [weak self] provider, text in
            guard let self else { return }
            // Ключ не подключён — открываем настройки вместо пустой панели
            if self.settings.availableProviders.isEmpty { self.openSettings(); return }
            self.shelf?.openAsk(provider: provider, context: text)
        }
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()

        // Островок при выделении текста
        selectionWatcher.onSelection = { [weak self] text in self?.shelf?.showSelectionBar(text: text) }
        selectionWatcher.onMouseDown = { [weak self] in self?.shelf?.selectionMouseDown() }
        settings.$showOnSelection
            .removeDuplicates()
            .sink { [weak self] on in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.selectionWatcher.setEnabled(on) }
                }
            }
            .store(in: &cancellables)

        if firstLaunch { openSettings() }
    }

    /// Следим за папкой скриншотов и (если включено) за «Загрузками». Если это одна папка — один наблюдатель.
    func startWatchers() {
        watchers.forEach { $0.stop() }
        watchers.removeAll()
        downloads.stop()

        let screenshotsURL = settings.screenshotFolder.url.standardizedFileURL
        let downloadsURL = ScreenCaptureConfig.downloadsFolder.standardizedFileURL
        var folders = [screenshotsURL]
        if settings.trackDownloads && downloadsURL.path != screenshotsURL.path {
            folders.append(downloadsURL)
        }

        for folder in folders {
            let isDownloads = folder.path == downloadsURL.path
            let w = FolderWatcher(folder: folder) { [weak self] url, isScreenshot in
                guard let self else { return }
                if isScreenshot {
                    self.store.add(url: url, kind: .screenshot)
                } else if isDownloads && self.settings.trackDownloads {
                    self.store.add(url: url, kind: .download)
                }
            }
            if isDownloads && settings.trackDownloads {
                w.onPartials = { [weak self] urls in self?.downloads.setPartials(urls) }
                downloads.start(folder: folder)
            }
            w.start()
            watchers.append(w)
        }
    }

    // MARK: - Строка меню

    func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "photo.stack", accessibilityDescription: "NotchShelf")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.addItem(withTitle: L("Show Shelf"), action: #selector(showShelf), keyEquivalent: "").target = self
        let claudeItem = menu.addItem(withTitle: L("Ask Claude…"), action: #selector(askClaude), keyEquivalent: "")
        claudeItem.target = self
        let chatGPTItem = menu.addItem(withTitle: L("Ask ChatGPT…"), action: #selector(askChatGPT), keyEquivalent: "")
        chatGPTItem.target = self
        askClaudeItem = claudeItem
        askChatGPTItem = chatGPTItem
        menu.delegate = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Open Screenshots Folder"), action: #selector(openFolder), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Clear Shelf"), action: #selector(clearShelf), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Settings…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: L("Quit NotchShelf"), action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    /// Перед открытием меню прячем «Спросить …» для ИИ без ключа.
    func menuNeedsUpdate(_ menu: NSMenu) {
        askClaudeItem?.isHidden = !settings.connectedProviders.contains(.claude)
        askChatGPTItem?.isHidden = !settings.connectedProviders.contains(.chatgpt)
    }

    @objc func showShelf() { shelf?.showFromMenu() }
    @objc func askClaude() { shelf?.openAsk(provider: .claude, context: "") }
    @objc func askChatGPT() { shelf?.openAsk(provider: .chatgpt, context: "") }
    @objc func clearShelf() { store.clearUnpinned() }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func openFolder() {
        NSWorkspace.shared.open(settings.screenshotFolder.url)
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings) { [weak self] in
                self?.startWatchers()
            }
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = L("NotchShelf Settings")
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

/// Обработчик пунктов «Спросить Claude» и «Спросить ChatGPT» в меню Службы macOS.
final class ServiceProvider: NSObject {
    var onAsk: ((AIProvider, String) -> Void)?

    @objc func askClaude(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        handle(.claude, pboard)
    }

    @objc func askChatGPT(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        handle(.chatgpt, pboard)
    }

    private func handle(_ provider: AIProvider, _ pboard: NSPasteboard) {
        let text = pboard.string(forType: .string) ?? ""
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onAsk?(provider, text) }
        }
    }
}
