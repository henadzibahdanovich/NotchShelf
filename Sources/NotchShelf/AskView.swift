import AppKit
import SwiftUI

/// Панель «Спросить Claude / ChatGPT», выезжающая из-под чёлки.
struct AskPanel: View {
    @ObservedObject var ask: AskModel
    @ObservedObject var settings: AppSettings
    let close: () -> Void
    let openSettings: () -> Void
    @FocusState private var inputFocused: Bool
    @State private var contextExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !ask.context.isEmpty && ask.messages.isEmpty {
                contextCard
            }

            Group {
                if ask.messages.isEmpty {
                    starter
                } else {
                    conversation
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if let error = ask.errorText {
                errorBanner(error)
            }

            inputBar
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassBackground(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .onAppear { focusInputSoon() }
        .onChange(of: ask.context) { _, _ in focusInputSoon() }
        .onExitCommand { close() }
        .onChange(of: settings.connectedProviders) { _, connected in
            if !connected.contains(ask.provider), let p = settings.preferredProvider { ask.provider = p }
        }
        .animation(.snappy(duration: 0.25), value: ask.messages.count)
        .animation(.snappy(duration: 0.25), value: ask.errorText)
    }

    private func focusInputSoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            inputFocused = true
        }
    }

    // MARK: Шапка

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tint)
            // Показываем только ИИ с подключённым ключом
            if settings.availableProviders.count > 1 {
                Picker("Модель", selection: $ask.provider) {
                    ForEach(settings.availableProviders) { p in
                        Text(p.title).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            } else if let only = settings.availableProviders.first {
                Text(only.title)
                    .font(.system(size: 13, weight: .semibold))
            } else {
                Text("ИИ не подключён")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            GlassGroup(spacing: 6) {
                HStack(spacing: 6) {
                    if !ask.messages.isEmpty {
                        GlassIconButton(systemName: "square.and.pencil", help: "Новый вопрос") { ask.reset() }
                    }
                    if !settings.availableProviders.isEmpty {
                        GlassIconButton(systemName: "arrow.up.forward.app",
                                        help: "Продолжить в \(ask.provider.title) в браузере") { ask.continueInBrowser() }
                    }
                    GlassIconButton(systemName: "xmark", help: "Закрыть (Esc)") { close() }
                }
            }
        }
        .frame(height: 28)
    }

    // MARK: Выделенный текст

    private var contextCard: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor)
                .frame(width: 3)
            Text(ask.context)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(contextExpanded ? 12 : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            VStack(spacing: 4) {
                Button { contextExpanded.toggle() } label: {
                    Image(systemName: contextExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(contextExpanded ? "Свернуть" : "Показать весь текст")
                Button { ask.context = "" } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Убрать текст")
            }
        }
        .padding(10)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    // MARK: Пустое состояние / быстрые действия

    private var starter: some View {
        VStack(alignment: .leading, spacing: 10) {
            if settings.availableProviders.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "key")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Подключите ключ Claude или ChatGPT")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Button("Открыть настройки", action: openSettings)
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if ask.context.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Спросите \(ask.provider.title) о чём угодно")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Совет: выделите текст в любом приложении → правый клик → Службы → «Спросить \(ask.provider.title)»")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Быстрые действия")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                FlowChips(actions: AskModel.quickActions) { action in ask.send(action.prompt) }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Переписка

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(ask.messages) { message in
                        MessageRow(message: message, ask: ask,
                                   isLast: message.id == ask.messages.last?.id)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.automatic)
            .onChange(of: ask.messages.last?.display) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: ask.messages.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.system(size: 12)).lineLimit(2)
            Spacer(minLength: 0)
            if !ask.hasKey {
                Button("Открыть настройки", action: openSettings)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.12)))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Поле ввода

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(ask.messages.isEmpty ? "Спросите что угодно…" : "Уточните или задайте новый вопрос…",
                      text: $ask.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .lineLimit(1...5)
                .focused($inputFocused)
                .onSubmit { ask.send() }
                .padding(.vertical, 9)
                .padding(.leading, 14)

            Button {
                if ask.isStreaming { ask.stop() } else { ask.send() }
            } label: {
                Image(systemName: ask.isStreaming ? "stop.fill" : "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(canSend || ask.isStreaming ? Color.accentColor : Color.secondary.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend && !ask.isStreaming)
            .help(ask.isStreaming ? "Остановить" : "Отправить (Return)")
            .padding(.trailing, 5)
            .padding(.bottom, 4)
        }
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.primary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(inputFocused ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1))
    }

    private var canSend: Bool {
        !ask.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (ask.messages.isEmpty && !ask.context.isEmpty)
    }
}

/// Сообщение в переписке.
private struct MessageRow: View {
    let message: ChatMessage
    @ObservedObject var ask: AskModel
    let isLast: Bool

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 60)
                Text(message.display)
                    .font(.system(size: 13))
                    .lineLimit(4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18)))
                    .textSelection(.enabled)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if message.display.isEmpty && ask.isStreaming && isLast {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("\(ask.provider.title) думает…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(Self.markdown(message.display))
                        .font(.system(size: 13.5))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !(ask.isStreaming && isLast) && !message.display.isEmpty {
                    Button { ask.copy(message) } label: {
                        Label(ask.copiedMessageID == message.id ? "Скопировано" : "Копировать",
                              systemImage: ask.copiedMessageID == message.id ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

/// Кнопки быстрых действий.
private struct FlowChips: View {
    let actions: [QuickAction]
    let onTap: (QuickAction) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(actions) { action in
                ChipButton(action: action) { onTap(action) }
            }
        }
    }
}

private struct ChipButton: View {
    let action: QuickAction
    let tap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: tap) {
            Label(action.title, systemImage: action.icon)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassBackground(Capsule(), interactive: true)
        .scaleEffect(hovering ? 1.04 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}
