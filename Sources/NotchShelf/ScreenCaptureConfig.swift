import Foundation

/// Работа с системными настройками скриншотов macOS (домен com.apple.screencapture).
enum ScreenCaptureConfig {
    static let domain = "com.apple.screencapture" as CFString

    static var downloadsFolder: URL { ScreenshotFolder.downloads.url }

    /// Папка, куда macOS сейчас сохраняет скриншоты.
    static func currentLocation() -> URL {
        CFPreferencesAppSynchronize(domain)
        if let raw = CFPreferencesCopyAppValue("location" as CFString, domain) as? String, !raw.isEmpty {
            let path = (raw as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return ScreenshotFolder.desktop.url
    }

    /// Направить скриншоты macOS в выбранную папку.
    static func setLocation(_ folder: ScreenshotFolder) {
        let d = UserDefaults.standard
        try? FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        // Запоминаем исходную папку пользователя один раз — для uninstall.sh
        if d.string(forKey: "previousScreenshotLocation") == nil {
            d.set(currentLocation().path, forKey: "previousScreenshotLocation")
        }
        guard currentLocation().standardizedFileURL.path != folder.url.standardizedFileURL.path else { return }
        runDefaults(["write", "com.apple.screencapture", "location", "-string", folder.url.path])
        restartSystemUI()
    }

    /// Плавающая миниатюра в правом нижнем углу задерживает сохранение файла на ~5 секунд.
    static func setFloatingThumbnail(enabled: Bool) {
        runDefaults(["write", "com.apple.screencapture", "show-thumbnail", "-bool", enabled ? "true" : "false"])
        restartSystemUI()
    }

    private static func runDefaults(_ args: [String]) {
        run("/usr/bin/defaults", args)
        CFPreferencesAppSynchronize(domain)
    }

    private static func restartSystemUI() {
        run("/usr/bin/killall", ["SystemUIServer"])
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }
}
