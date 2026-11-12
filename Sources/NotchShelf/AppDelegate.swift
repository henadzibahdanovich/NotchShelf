import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings.shared
    lazy var store = ShelfStore(settings: settings)
    lazy var clipboard = ClipboardHistory(settings: settings)
    lazy var player = NowPlaying(settings: settings)
    let timer = FocusTimer()
    let downloads = DownloadProgressMonitor()
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
                                 timer: timer, downloads: downloads)
        shelf = ShelfController(models: models, settings: settings) { [weak self] in
            self?.openSettings()
        }
        store.restore()
        startWatchers()
        setupStatusItem()

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
        menu.addItem(withTitle: "Показать полку", action: #selector(showShelf), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Открыть папку со скриншотами", action: #selector(openFolder), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Очистить полку", action: #selector(clearShelf), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Настройки…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Выйти из NotchShelf", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc func showShelf() { shelf?.showFromMenu() }
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
            window.title = "Настройки NotchShelf"
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
