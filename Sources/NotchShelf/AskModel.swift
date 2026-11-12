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

    static let systemPrompt = """
    Ты — помощник, встроенный в macOS. Пользователь выделил текст в каком-то приложении и задаёт по нему вопрос.
    Отвечай кратко и по делу, на языке вопроса пользователя (если вопроса нет — на языке текста).
    Если просят написать ответ, перевод или исправленный текст — выдай только готовый текст, без вступлений и пояснений,
    чтобы его можно было сразу скопировать и вставить.
    """

    static let quickActions: [QuickAction] = [
        QuickAction(id: "reply", title: "Ответить", icon: "arrowshape.turn.up.left",
                    prompt: "Напиши ответ на это сообщение от моего имени. Тот же язык и тон, только текст ответа."),
        QuickAction(id: "translate", title: "Перевести", icon: "globe",
                    prompt: "Переведи на русский. Если текст уже на русском — переведи на английский. Только перевод."),
        QuickAction(id: "fix", title: "Исправить", icon: "checkmark.seal",
                    prompt: "Исправь ошибки и улучши стиль, сохрани язык и смысл. Только исправленный текст."),
        QuickAction(id: "shorten", title: "Сократить", icon: "arrow.down.right.and.arrow.up.left",
                    prompt: "Сократи текст, сохранив главное."),
        QuickAction(id: "explain", title: "Объяснить", icon: "lightbulb",
                    prompt: "Объясни простыми словами, о чём этот текст и что в нём важно."),
    ]

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

        let fallback = files.isEmpty ? "Помоги с этим текстом." : "Посмотри на вложения и помоги с ними."
        var sent = question.isEmpty ? fallback : question
        if firstTurn && !context.isEmpty {
            sent += "\n\n<текст>\n\(context)\n</текст>"
        }
        let display = question.isEmpty ? (files.isEmpty ? "Помоги с этим текстом" : "") : question
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
                if q.display != "Помоги с этим текстом" { input = q.display }
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
            let items = datas.compactMap { AttachmentLoader.load(imageData: $0, name: "Изображение") }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loadingAttachments -= 1
                items.forEach { self.append($0) }
                if items.isEmpty { self.errorText = "Не удалось прочитать картинку" }
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
                    guard let data, let a = AttachmentLoader.load(imageData: data, name: "Изображение") else { return }
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
        panel.prompt = "Прикрепить"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }

    private func append(_ attachment: Attachment) {
        guard attachments.count < Self.maxAttachments else {
            errorText = "Можно прикрепить не больше \(Self.maxAttachments) файлов"
            return
        }
        attachments.append(attachment)
        if errorText != nil && !(errorText ?? "").contains("ключ") { errorText = nil }
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
            let q = input.isEmpty ? "Помоги с этим текстом." : input
            text = context.isEmpty ? q : "\(q)\n\n<текст>\n\(context)\n</текст>"
        }
        if let url = provider.webURL(prefill: text) { NSWorkspace.shared.open(url) }
    }
}
