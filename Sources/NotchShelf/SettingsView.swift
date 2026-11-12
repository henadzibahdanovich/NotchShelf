import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    var onFoldersChanged: () -> Void

    private let screenshotLifetimes: [(String, Int)] = [
        ("Через 15 минут", 15), ("Через 1 час", 60), ("Через 3 часа", 180),
        ("Через 24 часа", 1440), ("Никогда", 0),
    ]
    private let downloadLifetimes: [(String, Int)] = [
        ("Через 1 час", 60), ("Через 3 часа", 180), ("Через 24 часа", 1440),
        ("Через 3 дня", 4320), ("Никогда", 0),
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
                        Text("Новые скриншоты и загрузки появляются у чёлки. Перетащите файл куда нужно — полка уберёт его сама.")
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
                    Picker("По умолчанию", selection: $settings.defaultAIProvider) {
                        ForEach(settings.availableProviders) { Text($0.title).tag($0) }
                    }
                }
                AIKeyRow(provider: .claude, settings: settings)
                AIKeyRow(provider: .chatgpt, settings: settings)
                SelectionToggleRow(settings: settings)
            } header: {
                Text("Спросить Claude и ChatGPT")
            } footer: {
                Text("Пункты «Спросить …» появляются только для ИИ с подключённым ключом. Выделите текст → правый клик → Службы, или включите островок при выделении. Ключи хранятся в Связке ключей.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Скриншоты") {
                Picker("Сохранять в", selection: $settings.screenshotFolder) {
                    ForEach(ScreenshotFolder.allCases) { Text($0.title).tag($0) }
                }
                Picker("Удалять автоматически", selection: $settings.lifetimeMinutes) {
                    ForEach(screenshotLifetimes, id: \.1) { Text($0.0).tag($0.1) }
                }
                Toggle(isOn: $settings.deleteAfterDrag) {
                    Text("Удалять после перетаскивания")
                    Text("Скриншот уходит в Корзину, когда вы перетащили его в другое приложение.")
                }
                Toggle(isOn: $settings.hideSystemThumbnail) {
                    Text("Скрыть миниатюру в углу экрана")
                    Text("Без неё скриншот появляется на полке мгновенно.")
                }
            }

            Section("Загрузки") {
                Toggle(isOn: $settings.trackDownloads) {
                    Text("Показывать новые загрузки")
                    Text("Всё, что появилось в папке «Загрузки», попадает на полку.")
                }
                Group {
                    Picker("Убирать с полки", selection: $settings.downloadShelfMinutes) {
                        ForEach(downloadLifetimes, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    Toggle(isOn: $settings.trashDownloadsOnExpire) {
                        Text("При этом удалять файл")
                        Text("Выключено — файл остаётся в «Загрузках», уходит только с полки.")
                    }
                    Toggle(isOn: $settings.trashDownloadsAfterDrag) {
                        Text("Удалять файл после перетаскивания")
                        Text("Удобно для одноразовых файлов: перетащил — и забыл.")
                    }
                }
                .disabled(!settings.trackDownloads)
            }

            Section("Лоток") {
                Toggle(isOn: $settings.trayRemoveAfterDrag) {
                    Text("Убирать из лотка после перетаскивания")
                    Text("Положили файл в лоток, перетащили куда нужно — он исчезает из лотка. Сам файл не удаляется.")
                }
            }

            Section("Буфер обмена") {
                Toggle(isOn: $settings.clipboardEnabled) {
                    Text("Сохранять историю буфера обмена")
                    Text("Текст и картинки. Помеченные секретными данные пропускаются; секреты без такой метки могут сохраниться.")
                }
                Picker("Хранить последних", selection: $settings.clipboardLimit) {
                    ForEach([20, 50, 100, 200], id: \.self) { Text("\($0)").tag($0) }
                }
                .disabled(!settings.clipboardEnabled)
            }

            Section("Музыка") {
                Toggle(isOn: $settings.showNowPlaying) {
                    Text("Показывать, что играет")
                    Text("Музыка и Spotify. При первом запуске macOS спросит разрешение на управление плеером.")
                }
            }

            Section("Общие") {
                Toggle("Показывать полку при новом файле", isOn: $settings.peekOnCapture)
                Toggle("Открывать при входе в систему", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))
                LabeledContent("Папка со скриншотами") {
                    Button("Показать в Finder") {
                        NSWorkspace.shared.open(settings.screenshotFolder.url)
                    }
                }
            }

            Section("Сочетания клавиш macOS") {
                LabeledContent("Весь экран", value: "⇧⌘3")
                LabeledContent("Область", value: "⇧⌘4")
                LabeledContent("Окно", value: "⇧⌘4, затем пробел")
                LabeledContent("Запись экрана и параметры", value: "⇧⌘5")
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
            LabeledContent("Ключ \(provider.title)") {
                HStack(spacing: 8) {
                    if checking {
                        ProgressView().controlSize(.small)
                    } else if status == nil {
                        Label("Работает", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Button("Удалить") {
                        Keychain.delete(provider.keychainAccount)
                        settings.refreshAIKeys()
                        hasKey = false
                        models = []
                        status = nil
                    }
                }
            }
            Picker("Модель \(provider.title)", selection: modelBinding) {
                ForEach(modelOptions, id: \.self) { Text($0).tag($0) }
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.orange)
            }
        } else {
            LabeledContent("Ключ \(provider.title)") {
                HStack(spacing: 8) {
                    SecureField("Вставьте ключ", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .onSubmit(save)
                    Button("Сохранить", action: save)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Link("Где взять ключ \(provider.title) →", destination: provider.keyPageURL)
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
            status = "Не удалось проверить ключ: " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
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
            Text("Показывать островок при выделении текста")
            Text("Выделили текст в любом приложении — у чёлки появляются кнопки «Спросить» и быстрые действия.")
        }
        .disabled(settings.availableProviders.isEmpty)

        if settings.showOnSelection {
            // Статус доступа обновляется раз в секунду, пока открыты настройки
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if SelectionWatcher.isTrusted {
                    Label("Доступ к Универсальному доступу есть", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    HStack {
                        Label("Нужно разрешение «Универсальный доступ» для NotchShelf", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Открыть") { SelectionWatcher.openAccessibilitySettings() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}
