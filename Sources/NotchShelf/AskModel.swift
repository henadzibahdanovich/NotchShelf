import AppKit
import UniformTypeIdentifiers

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: AIMessage.Role
    /// То, что уходит в модель (для первого вопроса — вместе с выделенным текстом).
    var text: String
    /// То, что показываем в интерфейсе.
    var display: String
    var attachments: [Attachment] = []
}

struct QuickAction: Identifiable {
    let id: String
    let title: String
    let icon: String
    let prompt: String
}

/// Диалог «Спросить Claude / ChatGPT» по выделенному тексту.
@MainActor
final class AskModel: ObservableObject {
    @Published var provider: AIProvider
    @Published var context: String = ""
    @Published var input: String = ""
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isStreaming = false
    @Published var errorText: String?
    @Published var copiedMessageID: UUID?
    /// Файлы, прикреплённые к следующему вопросу.
    @Published private(set) var attachments: [Attachment] = []
    @Published private(set) var loadingAttachments = 0
    static let maxAttachments = 10

    private let settings: AppSettings
    private var task: Task<Void, Never>?

    /// Язык интерфейса (одна из локализаций приложения) — на нём модель отвечает по умолчанию.
    static var uiLanguageCode: String { Bundle.main.preferredLocalizations.first ?? "en" }
    static var uiLanguageName: String {
        let code = uiLanguageCode
        return Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
    }

    static var systemPrompt: String {
        """
        You are an assistant built into macOS. The user selected some text in an app and is asking about it, \
        possibly with attached files. Be concise and to the point. Answer in the language of the user's question; \
        if there is no question, answer in \(uiLanguageName). When asked to write a reply, a translation or a corrected text, \
        output only the finished text with no preamble or explanations, so it can be copied and pasted right away.
        """
    }

    /// Подсказка для «Перевести»: на язык интерфейса, а если текст уже на нём — на английский.
    static var translatePrompt: String {
        let code = uiLanguageCode
        if code.hasPrefix("en") { return L("Translate this text into English. Output only the translation.") }
        let name = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        return L("Translate into this language: %@. If the text is already in it, translate into English. Output only the translation.", name)
    }

    static var quickActions: [QuickAction] {
        [
            QuickAction(id: "reply", title: L("Reply"), icon: "arrowshape.turn.up.left",
                        prompt: L("Write a reply to this message on my behalf. Same language and tone, reply text only.")),
            QuickAction(id: "translate", title: L("Translate"), icon: "globe", prompt: translatePrompt),
            QuickAction(id: "fix", title: L("Fix"), icon: "checkmark.seal",
                        prompt: L("Fix mistakes and improve the style, keeping the language and meaning. Corrected text only.")),
            QuickAction(id: "shorten", title: L("Shorten"), icon: "arrow.down.right.and.arrow.up.left",
                        prompt: L("Shorten the text, keeping the key points.")),
            QuickAction(id: "explain", title: L("Explain"), icon: "lightbulb",
                        prompt: L("Explain in simple words what this text is about and what matters in it.")),
        ]
    }

    init(settings: AppSettings) {
        self.settings = settings
        self.provider = settings.preferredProvider ?? settings.defaultAIProvider
    }

    var availableProviders: [AIProvider] { settings.availableProviders }

    var hasKey: Bool { Keychain.get(provider.keychainAccount) != nil }

    // MARK: Жизненный цикл

    func start(provider: AIProvider?, context: String) {
        stop()
        // Если просили ИИ без ключа — берём подключённый
        if let provider, settings.connectedProviders.contains(provider) {
            self.provider = provider
        } else {
            self.provider = settings.preferredProvider ?? settings.defaultAIProvider
        }
        self.context = context.trimmingCharacters(in: .whitespacesAndNewlines)
        messages = []
        input = ""
        errorText = nil
        attachments = []
    }

    func reset() {
        start(provider: provider, context: "")
    }

    func stop() {
        task?.cancel()
        task = nil
        isStreaming = false
    }

    // MARK: Отправка

    func send(_ preset: String? = nil) {
        guard !isStreaming else { return }
        let question = (preset ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        let firstTurn = messages.isEmpty
        let files = attachments
        guard loadingAttachments == 0 else { return }
        guard !question.isEmpty || (firstTurn && !context.isEmpty) || !files.isEmpty else { return }

        guard let key = Keychain.get(provider.keychainAccount) else {
            errorText = AIError.noKey(provider).errorDescription
            return
        }

        let fallback = files.isEmpty ? L("Help me with this text.") : L("Look at the attachments and help me with them.")
        var sent = question.isEmpty ? fallback : question
        if firstTurn && !context.isEmpty {
            sent += "\n\n<text>\n\(context)\n</text>"
        }
        let display = question.isEmpty ? (files.isEmpty ? L("Help with this text") : "") : question
        messages.append(ChatMessage(role: .user, text: sent, display: display, attachments: files))
        input = ""
        errorText = nil
        attachments = []

        let history = messages.map { AIMessage(role: $0.role, text: $0.text, attachments: $0.attachments) }
        messages.append(ChatMessage(role: .assistant, text: "", display: ""))
        isStreaming = true

        let provider = self.provider
        let model = settings.model(for: provider)
        task = Task { [weak self] in
            do {
                for try await chunk in AIClient.stream(provider: provider, model: model, system: AskModel.systemPrompt,
                                                       messages: history, key: key) {
                    self?.appendToLast(chunk)
                }
            } catch is CancellationError {
            } catch {
                self?.fail(error)
            }
            self?.isStreaming = false
        }
    }

    private func appendToLast(_ chunk: String) {
        guard !messages.isEmpty else { return }
        messages[messages.count - 1].text += chunk
        messages[messages.count - 1].display += chunk
    }

    private func fail(_ error: Error) {
        if let last = messages.last, last.role == .assistant, last.text.isEmpty {
            messages.removeLast()
            // Возвращаем вопрос в поле ввода, чтобы можно было повторить
            if let q = messages.last, q.role == .user {
                messages.removeLast()
                if q.display != L("Help with this text") { input = q.display }
                attachments = q.attachments
            }
        }
        if (error as? URLError)?.code == .cancelled { return }
        errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Вложения

    func removeAttachment(_ attachment: Attachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    /// Файлы с диска (Finder, полка, окно выбора).
    func addFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        loadingAttachments += 1
        Task.detached(priority: .userInitiated) {
            let results = urls.map { AttachmentLoader.load(url: $0) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loadingAttachments -= 1
                var errors: [String] = []
                for r in results {
                    switch r {
                    case .success(let a): self.append(a)
                    case .failure(let e): errors.append(e.errorDescription ?? "")
                    }
                }
                if !errors.isEmpty { self.errorText = errors.joined(separator: "\n") }
            }
        }
    }

    /// Картинки без файла (из браузера и т.п.).
    func addImageData(_ datas: [Data]) {
        guard !datas.isEmpty else { return }
        loadingAttachments += 1
        Task.detached(priority: .userInitiated) {
            let items = datas.compactMap { AttachmentLoader.load(imageData: $0, name: L("Image")) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loadingAttachments -= 1
                items.forEach { self.append($0) }
                if items.isEmpty { self.errorText = L("Couldn’t read the image") }
            }
        }
    }

    /// Перетаскивание: файлы из Finder или картинки из браузера.
    func addProviders(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { [weak self] in self?.addFiles([url]) }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                accepted = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let a = AttachmentLoader.load(imageData: data, name: L("Image")) else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { [weak self] in self?.append(a) }
                    }
                }
            }
        }
        return accepted
    }

    /// Окно «Прикрепить файл».
    func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .pdf, .text, .sourceCode, .json]
        panel.prompt = L("Attach")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }

    private func append(_ attachment: Attachment) {
        guard attachments.count < Self.maxAttachments else {
            errorText = L("You can attach up to %@ files", "\(Self.maxAttachments)")
            return
        }
        attachments.append(attachment)
        if errorText != nil && hasKey { errorText = nil }
    }

    // MARK: Прочее

    func copy(_ message: ChatMessage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.display, forType: .string)
        let id = message.id
        copiedMessageID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                if self?.copiedMessageID == id { self?.copiedMessageID = nil }
            }
        }
    }

    /// Открыть разговор в веб-версии Claude/ChatGPT.
    func continueInBrowser() {
        let text: String
        if let first = messages.first(where: { $0.role == .user }) {
            text = first.text
        } else {
            let q = input.isEmpty ? L("Help me with this text.") : input
            text = context.isEmpty ? q : "\(q)\n\n<text>\n\(context)\n</text>"
        }
        if let url = provider.webURL(prefill: text) { NSWorkspace.shared.open(url) }
    }
}
