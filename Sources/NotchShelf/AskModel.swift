import AppKit

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: AIMessage.Role
    /// То, что уходит в модель (для первого вопроса — вместе с выделенным текстом).
    var text: String
    /// То, что показываем в интерфейсе.
    var display: String
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
        guard !question.isEmpty || (firstTurn && !context.isEmpty) else { return }

        guard let key = Keychain.get(provider.keychainAccount) else {
            errorText = AIError.noKey(provider).errorDescription
            return
        }

        var sent = question.isEmpty ? "Помоги с этим текстом." : question
        if firstTurn && !context.isEmpty {
            sent += "\n\n<текст>\n\(context)\n</текст>"
        }
        messages.append(ChatMessage(role: .user, text: sent, display: question.isEmpty ? "Помоги с этим текстом" : question))
        input = ""
        errorText = nil

        let history = messages.map { AIMessage(role: $0.role, text: $0.text) }
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
            }
        }
        if (error as? URLError)?.code == .cancelled { return }
        errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
