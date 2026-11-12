import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    var onFoldersChanged: () -> Void

    private let screenshotLifetimes: [(String, Int)] = [
        (L("After 15 minutes"), 15), (L("After 1 hour"), 60), (L("After 3 hours"), 180),
        (L("After 24 hours"), 1440), (L("Never"), 0),
    ]
    private let downloadLifetimes: [(String, Int)] = [
        (L("After 1 hour"), 60), (L("After 3 hours"), 180), (L("After 24 hours"), 1440),
        (L("After 3 days"), 4320), (L("Never"), 0),
    ]

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 52, height: 52)
                        .glassBackground(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("NotchShelf").font(.title3.weight(.semibold))
                        Text(L("New screenshots and downloads appear at the notch. Drag a file where you need it — the shelf cleans up after itself."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                // Выбор по умолчанию имеет смысл, только когда подключены оба
                if settings.availableProviders.count > 1 {
                    Picker(L("Default"), selection: $settings.defaultAIProvider) {
                        ForEach(settings.availableProviders) { Text($0.title).tag($0) }
                    }
                }
                AIKeyRow(provider: .claude, settings: settings)
                AIKeyRow(provider: .chatgpt, settings: settings)
                SelectionToggleRow(settings: settings)
            } header: {
                Text(L("Ask Claude and ChatGPT"))
            } footer: {
                Text(L("“Ask …” items appear only for AIs with a connected key. Select text → right-click → Services, or turn on the island on selection. Keys are stored in the Keychain."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("Screenshots")) {
                Picker(L("Save to"), selection: $settings.screenshotFolder) {
                    ForEach(ScreenshotFolder.allCases) { Text($0.title).tag($0) }
                }
                Picker(L("Delete automatically"), selection: $settings.lifetimeMinutes) {
                    ForEach(screenshotLifetimes, id: \.1) { Text($0.0).tag($0.1) }
                }
                Toggle(isOn: $settings.deleteAfterDrag) {
                    Text(L("Delete after dragging out"))
                    Text(L("A screenshot moves to the Trash once you drag it into another app."))
                }
                Toggle(isOn: $settings.hideSystemThumbnail) {
                    Text(L("Hide the corner thumbnail"))
                    Text(L("Without it, screenshots appear on the shelf instantly."))
                }
            }

            Section(L("Downloads")) {
                Toggle(isOn: $settings.trackDownloads) {
                    Text(L("Show new downloads"))
                    Text(L("Anything that appears in your Downloads folder lands on the shelf."))
                }
                Group {
                    Picker(L("Remove from shelf"), selection: $settings.downloadShelfMinutes) {
                        ForEach(downloadLifetimes, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    Toggle(isOn: $settings.trashDownloadsOnExpire) {
                        Text(L("Also delete the file"))
                        Text(L("When off, the file stays in Downloads and only leaves the shelf."))
                    }
                    Toggle(isOn: $settings.trashDownloadsAfterDrag) {
                        Text(L("Delete file after dragging out"))
                        Text(L("Handy for one-off files: drag it out and forget it."))
                    }
                }
                .disabled(!settings.trackDownloads)
            }

            Section(L("Tray")) {
                Toggle(isOn: $settings.trayRemoveAfterDrag) {
                    Text(L("Remove from tray after dragging out"))
                    Text(L("Drop a file in the tray, drag it where you need it, and it leaves the tray. The file itself isn’t deleted."))
                }
            }

            Section(L("Clipboard history")) {
                Toggle(isOn: $settings.clipboardEnabled) {
                    Text(L("Keep clipboard history"))
                    Text(L("Text and images. Content marked as confidential is skipped; secrets without that marker may still be saved."))
                }
                Picker(L("Keep last"), selection: $settings.clipboardLimit) {
                    ForEach([20, 50, 100, 200], id: \.self) { Text("\($0)").tag($0) }
                }
                .disabled(!settings.clipboardEnabled)
            }

            Section(L("Music")) {
                Toggle(isOn: $settings.showNowPlaying) {
                    Text(L("Show Now Playing"))
                    Text(L("Music and Spotify. On first use, macOS will ask for permission to control the player."))
                }
            }

            Section(L("General")) {
                Toggle(L("Reveal the shelf for new files"), isOn: $settings.peekOnCapture)
                Toggle(L("Open at login"), isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))
                LabeledContent(L("Screenshots folder")) {
                    Button(L("Show in Finder")) {
                        NSWorkspace.shared.open(settings.screenshotFolder.url)
                    }
                }
            }

            Section(L("macOS shortcuts")) {
                LabeledContent(L("Entire screen"), value: "⇧⌘3")
                LabeledContent(L("Selection"), value: "⇧⌘4")
                LabeledContent(L("Window"), value: L("⇧⌘4, then Space"))
                LabeledContent(L("Screen recording and options"), value: "⇧⌘5")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 760)
        .onChange(of: settings.screenshotFolder) { _, folder in
            ScreenCaptureConfig.setLocation(folder)
            onFoldersChanged()
        }
        .onChange(of: settings.trackDownloads) { _, _ in
            onFoldersChanged()
        }
        .onChange(of: settings.hideSystemThumbnail) { _, hide in
            ScreenCaptureConfig.setFloatingThumbnail(enabled: !hide)
        }
    }
}

/// Ввод и проверка API-ключа + выбор модели.
private struct AIKeyRow: View {
    let provider: AIProvider
    @ObservedObject var settings: AppSettings
    @State private var draft = ""
    @State private var hasKey = false
    @State private var models: [String] = []
    @State private var status: String?
    @State private var checking = false

    var body: some View {
        Group { content }
            .task {
                hasKey = Keychain.get(provider.keychainAccount) != nil
                if hasKey { await loadModels() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if hasKey {
            LabeledContent(L("%@ key", "\(provider.title)")) {
                HStack(spacing: 8) {
                    if checking {
                        ProgressView().controlSize(.small)
                    } else if status == nil {
                        Label(L("Working"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Button(L("Delete")) {
                        Keychain.delete(provider.keychainAccount)
                        settings.refreshAIKeys()
                        hasKey = false
                        models = []
                        status = nil
                    }
                }
            }
            Picker(L("%@ model", "\(provider.title)"), selection: modelBinding) {
                ForEach(modelOptions, id: \.self) { Text($0).tag($0) }
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.orange)
            }
        } else {
            LabeledContent(L("%@ key", "\(provider.title)")) {
                HStack(spacing: 8) {
                    SecureField(L("Paste your key"), text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .onSubmit(save)
                    Button(L("Save"), action: save)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Link(L("Get a %@ key →", "\(provider.title)"), destination: provider.keyPageURL)
                .font(.caption)
        }
    }

    private var modelBinding: Binding<String> {
        Binding(get: { settings.model(for: provider) },
                set: { settings.setModel($0, for: provider) })
    }

    private var modelOptions: [String] {
        let current = settings.model(for: provider)
        return models.contains(current) ? models : [current] + models
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Keychain.set(key, for: provider.keychainAccount)
        settings.refreshAIKeys()
        draft = ""
        hasKey = true
        Task { await loadModels() }
    }

    private func loadModels() async {
        guard let key = Keychain.get(provider.keychainAccount) else { return }
        checking = true
        defer { checking = false }
        do {
            let list = try await AIClient.fetchModels(provider: provider, key: key)
            models = list
            status = nil
            // Если сохранённой модели нет в списке — выбираем подходящую по умолчанию
            if !list.contains(settings.model(for: provider)), let best = preferred(from: list) {
                settings.setModel(best, for: provider)
            }
        } catch {
            status = L("Couldn’t verify the key: %@", (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func preferred(from list: [String]) -> String? {
        switch provider {
        case .claude: return list.first { $0.contains("sonnet") } ?? list.first
        case .chatgpt: return list.first { $0 == "gpt-5" } ?? list.first { !$0.contains("mini") && !$0.contains("nano") } ?? list.first
        }
    }
}

/// Переключатель «Показывать островок при выделении текста» + статус доступа.
private struct SelectionToggleRow: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Toggle(isOn: $settings.showOnSelection) {
            Text(L("Show the island when text is selected"))
            Text(L("Select text in any app and “Ask” buttons with quick actions appear at the notch."))
        }
        .disabled(settings.availableProviders.isEmpty)

        if settings.showOnSelection {
            // Статус доступа обновляется раз в секунду, пока открыты настройки
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if SelectionWatcher.isTrusted {
                    Label(L("Accessibility access granted"), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    HStack {
                        Label(L("NotchShelf needs Accessibility permission"), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button(L("Open")) { SelectionWatcher.openAccessibilitySettings() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}
