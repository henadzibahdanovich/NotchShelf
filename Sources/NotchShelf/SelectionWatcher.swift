import AppKit
import ApplicationServices

/// Замечает выделение текста в других приложениях через Универсальный доступ (Accessibility).
/// Нужно разрешение: Системные настройки → Конфиденциальность и безопасность → Универсальный доступ.
@MainActor
final class SelectionWatcher {
    var onSelection: ((String) -> Void)?
    var onMouseDown: (() -> Void)?

    private var monitors: [Any] = []
    private var pending: DispatchWorkItem?
    private var lastText = ""
    private var enhancedPIDs = Set<pid_t>()
    private var trustPoll: Timer?

    /// Браузеры на Chromium отдают выделенный текст только после такого «включения».
    private static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium",
    ]

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Показывает системный запрос на доступ (если доступа ещё нет).
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func setEnabled(_ on: Bool) {
        stop()
        guard on else { return }
        if !Self.isTrusted {
            Self.requestTrust()
            // Когда пользователь выдаст доступ — переустановим слежение (клавиатура требует доступа заранее)
            trustPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard Self.isTrusted else { return }
                    self?.setEnabled(true)
                }
            }
        }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleCheck() }
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastText = ""
                self?.onMouseDown?()
            }
        }) { monitors.append(m) }

        // Выделение с клавиатуры: Shift + стрелки, ⌘A
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyUp, handler: { [weak self] event in
            let flags = event.modifierFlags
            let isSelectAll = flags.contains(.command) && event.keyCode == 0
            guard flags.contains(.shift) || isSelectAll else { return }
            MainActor.assumeIsolated { self?.scheduleCheck() }
        }) { monitors.append(m) }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        pending?.cancel()
        trustPoll?.invalidate()
        trustPoll = nil
    }

    private func scheduleCheck() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func check() {
        guard Self.isTrusted, let raw = selectedText() else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Не реагируем на одиночные слова (двойной клик) и пустые выделения
        let qualifies = (text.contains(" ") && text.count >= 6) || text.count >= 25
        guard qualifies, text != lastText else { return }
        lastText = text
        onSelection?(text)
    }

    private func selectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)

        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
              let appRef, CFGetTypeID(appRef) == AXUIElementGetTypeID() else { return nil }
        let app = appRef as! AXUIElement

        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        guard pid != getpid() else { return nil }
        enableAccessibilityIfNeeded(app: app, pid: pid)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let element = focusedRef as! AXUIElement

        // Поля паролей не трогаем
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        if (subroleRef as? String) == "AXSecureTextField" || (roleRef as? String) == "AXSecureTextField" { return nil }

        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedRef) == .success
        else { return nil }
        return selectedRef as? String
    }

    private func enableAccessibilityIfNeeded(app: AXUIElement, pid: pid_t) {
        guard !enhancedPIDs.contains(pid) else { return }
        enhancedPIDs.insert(pid)
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        if Self.chromiumBundleIDs.contains(bundleID) {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        } else {
            // Приложения на Electron (Slack, Notion, VS Code…)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
    }
}

/// Прячет пункты «Спросить …» в меню «Службы», если ключ не подключён.
/// Работает через те же настройки, что и переключатели в «Клавиатура → Сочетания клавиш → Службы».
enum ServicesMenuSync {
    static func apply(_ connected: Set<AIProvider>) {
        let signature = AIProvider.allCases.map { connected.contains($0) ? "1" : "0" }.joined()
        let d = UserDefaults.standard
        guard d.string(forKey: "servicesMenuSignature") != signature else { return }
        d.set(signature, forKey: "servicesMenuSignature")

        let domain = "pbs" as CFString
        var status = (CFPreferencesCopyAppValue("NSServicesStatus" as CFString, domain) as? [String: Any]) ?? [:]
        let bundleID = Bundle.main.bundleIdentifier ?? Keychain.service
        for provider in AIProvider.allCases {
            let title = provider == .claude ? "Спросить Claude" : "Спросить ChatGPT"
            let message = provider == .claude ? "askClaude" : "askChatGPT"
            let on = connected.contains(provider) ? 1 : 0
            status["\(bundleID) - \(title) - \(message)"] = [
                "enabled_context_menu": on,
                "enabled_services_menu": on,
                "presentation_modes": ["ContextMenu": on, "ServicesMenu": on, "TouchBar": 0],
            ] as [String: Any]
        }
        CFPreferencesSetAppValue("NSServicesStatus" as CFString, status as CFDictionary, domain)
        CFPreferencesAppSynchronize(domain)

        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
            p.arguments = ["-update"]
            try? p.run()
            p.waitUntilExit()
        }
    }
}
