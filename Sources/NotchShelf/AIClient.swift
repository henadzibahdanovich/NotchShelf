import Foundation

enum AIProvider: String, CaseIterable, Identifiable, Sendable {
    case claude, chatgpt
    var id: String { rawValue }

    var title: String { self == .claude ? "Claude" : "ChatGPT" }
    var keychainAccount: String { self == .claude ? "anthropic" : "openai" }
    var defaultModel: String { self == .claude ? "claude-sonnet-4-5" : "gpt-5" }

    var keyPageURL: URL {
        URL(string: self == .claude
            ? "https://console.anthropic.com/settings/keys"
            : "https://platform.openai.com/api-keys")!
    }

    /// Открыть тот же вопрос в веб-чате.
    func webURL(prefill: String) -> URL? {
        let base = self == .claude ? "https://claude.ai/new" : "https://chatgpt.com/"
        var c = URLComponents(string: base)
        c?.queryItems = [URLQueryItem(name: "q", value: String(prefill.prefix(6000)))]
        return c?.url
    }
}

struct AIMessage: Sendable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    let text: String
    var attachments: [Attachment] = []
}

enum AIError: LocalizedError {
    case noKey(AIProvider)
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noKey(let p): return "Добавьте ключ \(p.title) в настройках"
        case .http(let code, let message):
            if code == 401 { return "Ключ не подошёл (401). Проверьте его в настройках" }
            if code == 429 { return "Слишком много запросов или закончился баланс (429)" }
            return message.isEmpty ? "Ошибка сервера (\(code))" : "\(message) (\(code))"
        case .badResponse: return "Неожиданный ответ сервера"
        }
    }
}

/// Запросы к Anthropic и OpenAI с потоковым ответом.
enum AIClient {
    // MARK: Потоковый ответ

    static func stream(provider: AIProvider, model: String, system: String,
                       messages: [AIMessage], key: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(provider: provider, model: model, system: system,
                                                  messages: messages, key: key)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw AIError.badResponse }
                    if http.statusCode != 200 {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 4000 { break }
                        }
                        throw AIError.http(http.statusCode, errorMessage(from: body))
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if json["type"] as? String == "error" {
                            throw AIError.http(500, errorMessage(from: payload))
                        }
                        if let delta = textDelta(provider: provider, json: json), !delta.isEmpty {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func makeRequest(provider: AIProvider, model: String, system: String,
                                    messages: [AIMessage], key: String) throws -> URLRequest {
        var request: URLRequest
        var body: [String: Any]
        switch provider {
        case .claude:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": model,
                "max_tokens": 4096,
                "stream": true,
                "system": system,
                "messages": messages.map { m -> [String: Any] in ["role": m.role.rawValue, "content": claudeContent(m)] },
            ]
        case .chatgpt:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body = [
                "model": model,
                "stream": true,
                "messages": [["role": "system", "content": system] as [String: Any]]
                    + messages.map { m -> [String: Any] in ["role": m.role.rawValue, "content": openAIContent(m)] },
            ]
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: Вложения

    private static func fileBlockText(_ a: Attachment) -> String {
        "<file name=\"\(a.name)\">\n\(a.textContent)\n</file>"
    }

    /// Anthropic: картинки и PDF — отдельными блоками перед текстом вопроса.
    private static func claudeContent(_ m: AIMessage) -> Any {
        guard !m.attachments.isEmpty else { return m.text }
        var blocks: [[String: Any]] = []
        for a in m.attachments {
            switch a.kind {
            case .image:
                blocks.append(["type": "image",
                               "source": ["type": "base64", "media_type": a.mediaType, "data": a.base64]])
            case .pdf:
                blocks.append(["type": "document",
                               "source": ["type": "base64", "media_type": "application/pdf", "data": a.base64]])
            case .text:
                blocks.append(["type": "text", "text": fileBlockText(a)])
            }
        }
        blocks.append(["type": "text", "text": m.text])
        return blocks
    }

    /// OpenAI: текст, image_url (data URL) и file для PDF.
    private static func openAIContent(_ m: AIMessage) -> Any {
        guard !m.attachments.isEmpty, m.role == .user else { return m.text }
        var parts: [[String: Any]] = [["type": "text", "text": m.text]]
        for a in m.attachments {
            switch a.kind {
            case .image:
                parts.append(["type": "image_url",
                              "image_url": ["url": "data:\(a.mediaType);base64,\(a.base64)"]])
            case .pdf:
                parts.append(["type": "file",
                              "file": ["filename": a.name, "file_data": "data:application/pdf;base64,\(a.base64)"]])
            case .text:
                parts.append(["type": "text", "text": fileBlockText(a)])
            }
        }
        return parts
    }

    private static func textDelta(provider: AIProvider, json: [String: Any]) -> String? {
        switch provider {
        case .claude:
            guard json["type"] as? String == "content_block_delta",
                  let delta = json["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta" else { return nil }
            return delta["text"] as? String
        case .chatgpt:
            guard let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else { return nil }
            return delta["content"] as? String
        }
    }

    private static func errorMessage(from body: String) -> String {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else { return "" }
        return message
    }

    // MARK: Список моделей (заодно проверяет ключ)

    static func fetchModels(provider: AIProvider, key: String) async throws -> [String] {
        var request: URLRequest
        switch provider {
        case .claude:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .chatgpt:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw AIError.http(code, errorMessage(from: String(data: data, encoding: .utf8) ?? ""))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { throw AIError.badResponse }

        switch provider {
        case .claude:
            // Anthropic отдаёт модели от новых к старым
            return list.compactMap { $0["id"] as? String }
        case .chatgpt:
            let skip = ["audio", "realtime", "transcribe", "tts", "image", "search", "instruct",
                        "embedding", "dall", "whisper", "moderation", "codex", "computer"]
            return list
                .compactMap { m -> (String, Double)? in
                    guard let id = m["id"] as? String else { return nil }
                    return (id, (m["created"] as? NSNumber)?.doubleValue ?? 0)
                }
                .filter { id, _ in
                    (id.hasPrefix("gpt-") || id.hasPrefix("o3") || id.hasPrefix("o4"))
                        && !skip.contains(where: { id.contains($0) })
                }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }
    }
}
