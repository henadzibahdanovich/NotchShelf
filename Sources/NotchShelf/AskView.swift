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
    @State private var dropTargeted = false

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

            if !ask.attachments.isEmpty || ask.loadingAttachments > 0 {
                AttachmentStrip(ask: ask)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            inputBar
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.snappy(duration: 0.25), value: ask.attachments.map(\.id))
        .background(
            FileDropCatcher(
                onTargetChange: { targeted in
                    dropTargeted = targeted
                    // Иначе поле ввода перехватит файл и вставит его путь как текст
                    if targeted { inputFocused = false }
                },
                onDropFiles: { urls in
                    ask.addFiles(urls)
                    focusInputSoon()
                },
                onDropImageData: { datas in
                    ask.addImageData(datas)
                    focusInputSoon()
                }
            )
        )
        .glassBackground(RoundedRectangle(cornerRadius: 30, style: .continuous))
        // Вся панель — зона для файлов, включая пустые места (без contentShape SwiftUI их «не видит»)
        .contentShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            if dropTargeted {
                AttachDropHint().transition(.opacity)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            let ok = ask.addProviders(providers)
            focusInputSoon()
            return ok
        }
        .onChange(of: dropTargeted) { _, targeted in
            // Иначе поле ввода перехватит файл и вставит его путь как текст
            if targeted { inputFocused = false }
        }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
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
                Picker(L("Model"), selection: $ask.provider) {
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
                Text(L("No AI connected"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            GlassGroup(spacing: 6) {
                HStack(spacing: 6) {
                    if !ask.messages.isEmpty {
                        GlassIconButton(systemName: "square.and.pencil", help: L("New Question")) { ask.reset() }
                    }
                    if !settings.availableProviders.isEmpty {
                        GlassIconButton(systemName: "arrow.up.forward.app",
                                        help: L("Continue in %@ in the browser", "\(ask.provider.title)")) { ask.continueInBrowser() }
                    }
                    GlassIconButton(systemName: "xmark", help: L("Close (Esc)")) { close() }
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
                .help(contextExpanded ? L("Collapse") : L("Show full text"))
                Button { ask.context = "" } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L("Remove text"))
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
                    Text(L("Connect a Claude or ChatGPT key"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Button(L("Open Settings"), action: openSettings)
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if ask.context.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(L("Ask %@ anything", "\(ask.provider.title)"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(L("Drop images, PDFs or text files here — or select text in any app and choose “Ask %@”", "\(ask.provider.title)"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(L("Quick actions"))
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
                Button(L("Open Settings"), action: openSettings)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.12)))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Поле ввода

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 4) {
            Button { ask.pickFiles() } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Attach a file (images, PDF, text). You can also just drop it here"))
            .padding(.leading, 5)
            .padding(.bottom, 4)

            TextField(ask.messages.isEmpty ? L("Ask anything…") : L("Follow up or ask something new…"),
                      text: $ask.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .lineLimit(1...5)
                .focused($inputFocused)
                .onSubmit { ask.send() }
                .padding(.vertical, 9)

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
            .help(ask.isStreaming ? L("Stop") : L("Send (Return)"))
            .padding(.trailing, 5)
            .padding(.bottom, 4)
        }
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.primary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(inputFocused ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1))
    }

    private var canSend: Bool {
        guard ask.loadingAttachments == 0 else { return false }
        return !ask.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (ask.messages.isEmpty && !ask.context.isEmpty)
            || !ask.attachments.isEmpty
    }
}

/// Сообщение в переписке.
private struct MessageRow: View {
    let message: ChatMessage
    @ObservedObject var ask: AskModel
    let isLast: Bool

    var body: some View {
        if message.role == .user {
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachments.isEmpty {
                    HStack(spacing: 6) {
                        Spacer(minLength: 60)
                        ForEach(message.attachments) { a in
                            AttachmentThumb(attachment: a, size: 44)
                        }
                    }
                }
                if !message.display.isEmpty {
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
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if message.display.isEmpty && ask.isStreaming && isLast {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L("%@ is thinking…", "\(ask.provider.title)"))
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
                        Label(ask.copiedMessageID == message.id ? L("Copied") : L("Copy"),
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
        .onReliableHover { hovering = $0 }
    }
}

// MARK: - Вложения

/// Прикреплённые к следующему вопросу файлы.
private struct AttachmentStrip: View {
    @ObservedObject var ask: AskModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ask.attachments) { a in
                    AttachmentThumb(attachment: a, size: 54)
                        .overlay(alignment: .topTrailing) {
                            Button { ask.removeAttachment(a) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 18, height: 18)
                                    .background(Circle().fill(.black.opacity(0.6)))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 5, y: -5)
                            .help(L("Remove"))
                        }
                        .transition(.scale.combined(with: .opacity))
                }
                if ask.loadingAttachments > 0 {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06))
                        ProgressView().controlSize(.small)
                    }
                    .frame(width: 54, height: 54)
                }
            }
            .padding(.top, 8)
            .padding(.horizontal, 6)
        }
        .frame(height: 64)
    }
}

/// Миниатюра вложения: картинка или иконка файла с подписью.
struct AttachmentThumb: View {
    let attachment: Attachment
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        ZStack {
            if attachment.kind == .image, let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                shape.fill(Color.primary.opacity(0.07))
                VStack(spacing: 2) {
                    Image(systemName: attachment.kind == .pdf ? "doc.richtext" : "doc.text")
                        .font(.system(size: size * 0.32, weight: .regular))
                        .foregroundStyle(attachment.kind == .pdf ? Color.red : Color.secondary)
                    if size > 40 {
                        Text(attachment.name)
                            .font(.system(size: 8.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 3)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        .help("\(attachment.name) · \(attachment.sizeText)")
        .task(id: attachment.id) {
            if attachment.kind == .image { image = NSImage(data: attachment.data) }
        }
    }
}

private struct AttachDropHint: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        ZStack {
            shape.fill(Color.accentColor.opacity(0.12))
            shape.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            VStack(spacing: 6) {
                Image(systemName: "paperclip").font(.system(size: 26, weight: .medium))
                Text(L("Release to attach to your question")).font(.system(size: 13, weight: .semibold))
                Text(L("Images, PDFs and text files")).font(.system(size: 11)).opacity(0.8)
            }
            .foregroundStyle(Color.accentColor)
        }
        .allowsHitTesting(false)
    }
}
