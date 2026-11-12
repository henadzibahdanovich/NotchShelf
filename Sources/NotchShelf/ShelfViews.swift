import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShelfActions {
    var openSettings: () -> Void
    var dragStarted: () -> Void
    var dragEnded: (ShotItem, Bool) -> Void
    var openAsk: () -> Void
    var closeAsk: () -> Void
    /// Из плашки выделения: какой ИИ и (необязательно) быстрое действие.
    var askAboutSelection: (AIProvider, String?) -> Void
    var dismissSelection: () -> Void
    /// Открыть вопрос к ИИ с этим файлом во вложении.
    var askAboutFile: (ShotItem) -> Void
}

/// Все модели, которые видит полка.
@MainActor
struct ShelfModels {
    let store: ShelfStore
    let clipboard: ClipboardHistory
    let player: NowPlaying
    let timer: FocusTimer
    let downloads: DownloadProgressMonitor
    let ask: AskModel
    let settings: AppSettings
}

// MARK: - Корень

struct ShelfRootView: View {
    let models: ShelfModels
    @ObservedObject var store: ShelfStore
    @ObservedObject var ui: ShelfUIState
    let actions: ShelfActions

    var body: some View {
        let l = ui.layout
        VStack(spacing: ShelfLayout.gap) {
            CollapsedIndicator(store: store, timer: models.timer, player: models.player,
                               downloads: models.downloads, layout: l)

            if ui.expanded && ui.mode == .selection {
                SelectionBar(text: ui.selectionText, settings: models.settings,
                             ask: actions.askAboutSelection, dismiss: actions.dismissSelection)
                    .frame(width: ShelfLayout.selectionBarWidth, height: ShelfLayout.selectionBarHeight)
                    .transition(.scale(scale: 0.6, anchor: .top).combined(with: .opacity))
            } else if ui.expanded && ui.mode == .ask {
                AskPanel(ask: models.ask, settings: models.settings,
                         close: actions.closeAsk, openSettings: actions.openSettings)
                    .frame(width: ShelfLayout.panelWidth, height: ShelfLayout.askPanelHeight)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.55, anchor: .top).combined(with: .opacity),
                            removal: .scale(scale: 0.85, anchor: .top).combined(with: .opacity)
                        )
                    )
            } else if ui.expanded {
                HubPanel(models: models, store: store, actions: actions)
                    .frame(width: ShelfLayout.panelWidth, height: ShelfLayout.panelHeight)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.55, anchor: .top).combined(with: .opacity),
                            removal: .scale(scale: 0.85, anchor: .top).combined(with: .opacity)
                        )
                    )
            }
            Spacer(minLength: 0)
        }
        .frame(width: l.windowSize.width, height: l.windowSize.height, alignment: .top)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: ui.expanded)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: ui.mode)
    }
}

// MARK: - «Ушки» у чёлки: показывают самое важное прямо сейчас

private enum EarContent: Equatable {
    case download(fraction: Double?)
    case timer(progress: Double, text: String, running: Bool)
    case music(artwork: NSImage?, playing: Bool)
    case shelf(thumbnail: NSImage?, count: Int)
    case empty

    static func == (a: EarContent, b: EarContent) -> Bool {
        switch (a, b) {
        case let (.download(x), .download(y)): return x == y
        case let (.timer(p1, t1, r1), .timer(p2, t2, r2)): return p1 == p2 && t1 == t2 && r1 == r2
        case let (.music(a1, p1), .music(a2, p2)): return a1 === a2 && p1 == p2
        case let (.shelf(t1, c1), .shelf(t2, c2)): return t1 === t2 && c1 == c2
        case (.empty, .empty): return true
        default: return false
        }
    }

    var kindKey: Int {
        switch self {
        case .download: return 1
        case .timer: return 2
        case .music: return 3
        case .shelf: return 4
        case .empty: return 0
        }
    }
}

struct CollapsedIndicator: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject var timer: FocusTimer
    @ObservedObject var player: NowPlaying
    @ObservedObject var downloads: DownloadProgressMonitor
    let layout: ShelfLayout

    /// Приоритет: загрузка → таймер → музыка → полка.
    private var content: EarContent {
        if !downloads.active.isEmpty { return .download(fraction: downloads.overallFraction) }
        if timer.isActive {
            return .timer(progress: timer.progress, text: FocusTimer.format(timer.remaining), running: timer.isRunning)
        }
        if let t = player.track, t.isPlaying { return .music(artwork: t.artwork, playing: true) }
        let files = store.items.filter { $0.kind != .tray }
        if !files.isEmpty { return .shelf(thumbnail: files.first?.thumbnail, count: files.count) }
        return .empty
    }

    var body: some View {
        let c = content
        let visible = c != .empty
        Group {
            if layout.hasNotch {
                HStack(spacing: 0) {
                    leftEar(c).frame(width: ShelfLayout.earWidth)
                    Spacer(minLength: layout.notchWidth)
                    rightEar(c).frame(width: ShelfLayout.earWidth)
                }
                .frame(width: visible ? layout.collapsedWidth : layout.notchWidth, height: layout.menuBarHeight)
                .background(
                    UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous)
                        .fill(Color.black)
                )
                .environment(\.colorScheme, .dark)
            } else {
                HStack(spacing: 6) {
                    leftEar(c)
                    rightEar(c)
                }
                .padding(.horizontal, 8)
                .frame(height: max(layout.menuBarHeight - 4, 18))
                .glassBackground(Capsule())
                .padding(.top, 2)
                .scaleEffect(visible ? 1 : 0.6, anchor: .top)
            }
        }
        .opacity(visible ? 1 : 0)
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: c.kindKey)
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: visible)
        .frame(height: layout.menuBarHeight, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("NotchShelf")
    }

    @ViewBuilder
    private func leftEar(_ c: EarContent) -> some View {
        switch c {
        case .download(let f):
            ProgressRing(fraction: f, lineWidth: 2, tint: .white) {
                Image(systemName: "arrow.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 17, height: 17)
            .transition(.scale.combined(with: .opacity))
        case .timer(let p, _, let running):
            ProgressRing(fraction: p, lineWidth: 2, tint: running ? .orange : .white.opacity(0.6)) {
                Image(systemName: "timer").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 17, height: 17)
            .transition(.scale.combined(with: .opacity))
        case .music(let art, _):
            Thumb(image: art, placeholder: "music.note", size: 20)
                .transition(.scale.combined(with: .opacity))
        case .shelf(let thumb, _):
            Thumb(image: thumb, placeholder: "photo", size: 20)
                .transition(.scale.combined(with: .opacity))
        case .empty:
            Color.clear
        }
    }

    @ViewBuilder
    private func rightEar(_ c: EarContent) -> some View {
        switch c {
        case .download(let f):
            earText(f.map { "\(Int($0 * 100))%" } ?? "···")
        case .timer(_, let text, _):
            earText(text, size: text.count > 5 ? 9.5 : 11)
        case .music(_, let playing):
            EqualizerBars(playing: playing)
                .frame(width: 16, height: 12)
        case .shelf(_, let count):
            earText("\(count)")
        case .empty:
            Color.clear
        }
    }

    private func earText(_ s: String, size: CGFloat = 11.5) -> some View {
        Text(s)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(layout.hasNotch ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .contentTransition(.numericText())
    }
}

/// Маленькая скруглённая миниатюра.
struct Thumb: View {
    let image: NSImage?
    let placeholder: String
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.15)
                    Image(systemName: placeholder).font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .frame(width: size, height: size * 0.78)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
    }
}

/// Кольцо прогресса; без значения — вращающаяся дуга.
struct ProgressRing<Center: View>: View {
    let fraction: Double?
    var lineWidth: CGFloat = 3
    var tint: Color = .accentColor
    @ViewBuilder var center: () -> Center
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.25), lineWidth: lineWidth)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: fraction)
            } else {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
            }
            center()
        }
    }
}

/// «Эквалайзер» для играющей музыки.
struct EqualizerBars: View {
    let playing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 18, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(Color.green)
                        .frame(width: 2.2, height: Self.barHeight(index: i, time: t, playing: playing))
                }
            }
        }
    }

    static func barHeight(index i: Int, time t: Double, playing: Bool) -> CGFloat {
        guard playing else { return 3 }
        let phase = t * (5.5 + Double(i) * 1.7) + Double(i)
        return max(2.5, 12 * (0.3 + 0.7 * abs(sin(phase))))
    }
}

// MARK: - Раскрытая панель-хаб

struct HubPanel: View {
    let models: ShelfModels
    @ObservedObject var store: ShelfStore
    let actions: ShelfActions
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                NowPlayingWidget(player: models.player)
                TimerWidget(timer: models.timer)
                    .frame(width: 250)
            }
            .frame(height: ShelfLayout.widgetHeight)

            PanelHeader(store: store, clipboard: models.clipboard, settings: models.settings, actions: actions)

            Group {
                if store.filter == .clipboard {
                    ClipboardRow(clipboard: models.clipboard)
                } else {
                    FilesRow(store: store, downloads: models.downloads, settings: models.settings, actions: actions)
                }
            }
            .frame(height: ShelfLayout.contentHeight)
        }
        .padding(ShelfLayout.panelPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Содержимое не выходит за скруглённые края панели
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .glassBackground(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            if dropTargeted {
                DropHint().transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
        .onDrop(of: [.fileURL, .url, .image, .plainText, .utf8PlainText], isTargeted: $dropTargeted) { providers in
            store.acceptDrop(providers)
        }
        .onChange(of: dropTargeted) { _, targeted in
            if targeted { store.filter = .tray }
        }
    }
}

private struct DropHint: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        ZStack {
            shape.fill(Color.accentColor.opacity(0.12))
            shape.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            VStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 26, weight: .medium))
                Text(L("Release to drop into the tray")).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Color.accentColor)
        }
        .allowsHitTesting(false)
    }
}

/// Подложка для виджетов внутри стеклянной панели (без «стекла на стекле»).
private struct WidgetBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

// MARK: Сейчас играет

struct NowPlayingWidget: View {
    @ObservedObject var player: NowPlaying

    var body: some View {
        let track = player.track
        let playing = track?.isPlaying == true
        HStack(spacing: 10) {
            Group {
                if let art = track?.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color.primary.opacity(0.08)
                        Image(systemName: "music.note").font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            .onTapGesture { player.openPlayer() }
            .help(L("Open player"))

            VStack(alignment: .leading, spacing: 2) {
                Text(track?.title ?? L("Nothing playing"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(track == nil ? Color.secondary : Color.primary)
                    .lineLimit(1)
                Text(track?.artist ?? L("Music, Spotify and other players"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)

            HStack(spacing: 6) {
                GlassIconButton(systemName: "backward.fill", help: L("Previous track")) { player.previous() }
                GlassIconButton(systemName: playing ? "pause.fill" : "play.fill",
                                help: playing ? L("Pause") : L("Play"), size: 32) { player.playPause() }
                GlassIconButton(systemName: "forward.fill", help: L("Next track")) { player.next() }
            }
            .disabled(track == nil)
            .opacity(track == nil ? 0.45 : 1)
        }
        .modifier(WidgetBackground())
        .animation(.snappy(duration: 0.25), value: track?.key)
    }
}

// MARK: Таймер

struct TimerWidget: View {
    @ObservedObject var timer: FocusTimer

    var body: some View {
        HStack(spacing: 10) {
            if timer.isActive {
                ProgressRing(fraction: timer.progress, lineWidth: 3.5, tint: timer.isRunning ? .orange : .secondary) {
                    Image(systemName: "timer").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(timer.isRunning ? Color.orange : Color.secondary)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 1) {
                    Text(FocusTimer.format(timer.remaining))
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                    Text(timer.isRunning ? L("Running · %@ min", "\(Int(timer.total / 60))") : L("Pause"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    GlassIconButton(systemName: timer.isRunning ? "pause.fill" : "play.fill",
                                    help: timer.isRunning ? L("Pause") : L("Resume")) { timer.togglePause() }
                    GlassIconButton(systemName: "goforward.5", help: L("Add 5 minutes")) { timer.addFiveMinutes() }
                    GlassIconButton(systemName: "xmark", help: L("Stop"), role: .destructive) { timer.stop() }
                }
            } else {
                ZStack {
                    Circle().fill(Color.orange.opacity(0.15))
                    Image(systemName: "timer").font(.system(size: 15, weight: .semibold)).foregroundStyle(.orange)
                }
                .frame(width: 36, height: 36)

                Text(L("Timer"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    ForEach(FocusTimer.presets, id: \.minutes) { preset in
                        PresetChip(minutes: preset.minutes, hint: preset.hint) { timer.start(minutes: preset.minutes) }
                    }
                }
            }
        }
        .modifier(WidgetBackground())
        .animation(.snappy(duration: 0.25), value: timer.isActive)
    }
}

private struct PresetChip: View {
    let minutes: Int
    let hint: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("\(minutes)")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .frame(width: 28, height: 26)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassBackground(Capsule(), interactive: true)
        .scaleEffect(hovering ? 1.08 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onReliableHover { hovering = $0 }
        .help(L("%@ — %@ min", "\(hint)", "\(minutes)"))
    }
}

// MARK: Шапка с разделами

struct PanelHeader: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject var clipboard: ClipboardHistory
    @ObservedObject var settings: AppSettings
    let actions: ShelfActions

    private var canClear: Bool {
        store.filter == .clipboard
            ? clipboard.entries.contains { !$0.isPinned }
            : store.visibleItems.contains { !$0.isPinned }
    }

    var body: some View {
        HStack(spacing: 8) {
            Picker(L("Section"), selection: $store.filter) {
                ForEach(ShelfFilter.allCases) { f in
                    Text(f.title).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()

            if let toast = store.toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast)
            }

            Spacer(minLength: 0)

            GlassGroup(spacing: 6) {
                HStack(spacing: 6) {
                    if !settings.availableProviders.isEmpty {
                        GlassIconButton(systemName: "sparkles",
                                        help: L("Ask %@", settings.availableProviders.map(\.title).joined(separator: L(" or ")))) {
                            actions.openAsk()
                        }
                    }
                    if canClear {
                        GlassIconButton(systemName: "xmark.bin", help: L("Clear section (pinned items stay)")) {
                            if store.filter == .clipboard { clipboard.clearUnpinned() } else { store.clearVisible() }
                        }
                    }
                    GlassIconButton(systemName: "gearshape", help: L("Settings")) { actions.openSettings() }
                }
            }
        }
        .frame(height: 26)
        .animation(.snappy(duration: 0.25), value: store.toast)
    }
}

// MARK: Файлы

struct FilesRow: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject var downloads: DownloadProgressMonitor
    @ObservedObject var settings: AppSettings
    let actions: ShelfActions

    private var showDownloads: Bool { store.filter == .all || store.filter == .downloads }

    var body: some View {
        let items = store.visibleItems
        let active = showDownloads ? downloads.active : []
        if items.isEmpty && active.isEmpty {
            EmptyState(filter: store.filter)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                GlassGroup(spacing: 6) {
                    HStack(alignment: .top, spacing: ShelfLayout.cardSpacing) {
                        ForEach(active) { d in
                            ActiveDownloadCard(download: d)
                                .transition(.scale(scale: 0.7).combined(with: .opacity))
                        }
                        ForEach(items) { item in
                            ShotCard(item: item, store: store, actions: actions,
                                     aiAvailable: !settings.availableProviders.isEmpty)
                                .transition(.scale(scale: 0.7).combined(with: .opacity))
                        }
                    }
                    // Отступы внутри прокрутки: место для увеличения при наведении и тени
                    .padding(.vertical, 6)
                    .padding(.horizontal, ShelfLayout.panelPadding)
                    .animation(.spring(response: 0.42, dampingFraction: 0.8), value: items.map(\.id))
                    .animation(.spring(response: 0.42, dampingFraction: 0.8), value: active.map(\.id))
                }
            }
            .padding(.horizontal, -ShelfLayout.panelPadding)
        }
    }
}

struct EmptyState: View {
    let filter: ShelfFilter

    private var content: (icon: String, title: String, subtitle: String) {
        switch filter {
        case .all: return ("tray", L("The shelf is empty"), L("Take a screenshot, download a file or drop something here"))
        case .screenshots: return ("camera.viewfinder", L("No screenshots"), L("⇧⌘4 — selection, ⇧⌘3 — entire screen"))
        case .downloads: return ("arrow.down.circle", L("No new downloads"), L("Downloaded files will appear here"))
        case .tray: return ("tray.and.arrow.down", L("The tray is empty"), L("Drop files, links, images or text here"))
        case .clipboard: return ("doc.on.clipboard", L("No history yet"), L("Copy something and it will appear here"))
        }
    }

    var body: some View {
        let c = content
        VStack(spacing: 6) {
            Image(systemName: c.icon)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
            Text(c.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            Text(c.subtitle).font(.system(size: 11)).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ActiveDownloadCard: View {
    let download: ActiveDownload

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.primary.opacity(0.06))
                ProgressRing(fraction: download.fraction, lineWidth: 4, tint: .accentColor) {
                    Text(download.fraction.map { "\(Int($0 * 100))%" } ?? "")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .frame(width: 50, height: 50)
            }
            .frame(width: ShelfLayout.cardWidth, height: ShelfLayout.thumbHeight)

            Text(download.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(height: 26)
        }
        .frame(width: ShelfLayout.cardWidth)
        .help(L("Downloading: %@", "\(download.name)"))
    }
}

// MARK: Карточка файла

struct ShotCard: View {
    let item: ShotItem
    @ObservedObject var store: ShelfStore
    let actions: ShelfActions
    var aiAvailable = false
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            thumbnail
            footer.frame(height: 26)
        }
        .frame(width: ShelfLayout.cardWidth)
        .onReliableHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
    }

    private var fitsAsDocument: Bool { item.kind != .screenshot && !item.isImage }

    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return ZStack(alignment: .topLeading) {
            Group {
                if let img = item.thumbnail {
                    if fitsAsDocument {
                        ZStack {
                            Rectangle().fill(Color.primary.opacity(0.06))
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(10)
                        }
                    } else {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    }
                } else {
                    ZStack {
                        Rectangle().fill(Color.primary.opacity(0.06))
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .frame(width: ShelfLayout.cardWidth, height: ShelfLayout.thumbHeight)
            .clipShape(shape)
            .overlay(shape.strokeBorder(item.isPinned ? Color.accentColor.opacity(0.9) : .white.opacity(0.22),
                                        lineWidth: item.isPinned ? 1.5 : 0.5))

            HStack(spacing: 4) {
                if item.isPinned { badge("pin.fill") }
                if item.isVideo { badge("video.fill") }
                if item.kind == .download { badge("arrow.down") }
                if item.kind == .tray { badge("tray.fill") }
            }
            .padding(6)
        }
        .contentShape(shape)
        .onTapGesture(count: 2) { store.open(item) }
        .gesture(
            DragGesture(minimumDistance: 4).onChanged { _ in
                FileDragController.shared.begin(
                    url: item.url,
                    image: item.thumbnail,
                    onStart: actions.dragStarted,
                    onEnd: { accepted in actions.dragEnded(item, accepted) }
                )
            }
        )
        .shadow(color: .black.opacity(hovering ? 0.28 : 0.16), radius: hovering ? 10 : 5, y: hovering ? 5 : 2)
        .scaleEffect(hovering ? 1.035 : 1)
        .help(helpText)
    }

    private var helpText: String {
        let hint = L("Drag to use it elsewhere. Double-click to open")
        return item.kind == .screenshot ? hint : item.name + "\n" + hint
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(.black.opacity(0.45)))
    }

    @ViewBuilder
    private var footer: some View {
        ZStack {
            if hovering {
                HStack(spacing: buttonSize < 26 ? 4 : 6) { buttons }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text(item.kind == .screenshot ? statusText(now: context.date) : item.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(item.kind == .screenshot ? Color.secondary : Color.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 2)
                }
                .transition(.opacity)
            }
        }
    }

    /// Можно ли спросить ИИ про этот файл (картинка, PDF или текст + подключён ключ).
    private var canAsk: Bool {
        guard aiAvailable else { return false }
        let type = UTType(filenameExtension: item.url.pathExtension.lowercased())
        return item.isImage || type?.conforms(to: .pdf) == true || type?.conforms(to: .text) == true
    }

    /// С пятой кнопкой карточка тесновата — делаем кнопки чуть меньше.
    private var buttonSize: CGFloat { canAsk && item.kind != .tray ? 23 : 26 }

    @ViewBuilder
    private var buttons: some View {
        let s = buttonSize
        if canAsk {
            GlassIconButton(systemName: "sparkles", help: L("Ask AI about this file"), size: s) { actions.askAboutFile(item) }
        }
        switch item.kind {
        case .screenshot:
            GlassIconButton(systemName: "doc.on.doc", help: L("Copy"), size: s) { store.copy(item) }
            if item.isImage {
                GlassIconButton(systemName: "text.viewfinder", help: L("Copy text from screenshot"), size: s) { store.copyText(item) }
            } else {
                GlassIconButton(systemName: "folder", help: L("Show in Finder"), size: s) { store.revealInFinder(item) }
            }
            pinButton(size: s)
            GlassIconButton(systemName: "trash", help: L("Move to Trash"), role: .destructive, size: s) { store.delete(item) }
        case .download:
            GlassIconButton(systemName: "folder", help: L("Show in Finder"), size: s) { store.revealInFinder(item) }
            GlassIconButton(systemName: "xmark", help: L("Remove from shelf (file stays)"), size: s) { store.dismiss(item) }
            pinButton(size: s)
            GlassIconButton(systemName: "trash", help: L("Move to Trash"), role: .destructive, size: s) { store.delete(item) }
        case .tray:
            GlassIconButton(systemName: "doc.on.doc", help: L("Copy"), size: s) { store.copy(item) }
            if !item.owned {
                GlassIconButton(systemName: "folder", help: L("Show in Finder"), size: s) { store.revealInFinder(item) }
            }
            GlassIconButton(systemName: "xmark",
                            help: item.owned ? L("Remove from tray") : L("Remove from tray (file stays in place)"), size: s) {
                store.dismiss(item)
            }
        }
    }

    private func pinButton(size: CGFloat) -> some View {
        GlassIconButton(systemName: item.isPinned ? "pin.slash" : "pin",
                        help: item.isPinned ? L("Unpin") : L("Pin — don’t remove automatically"), size: size) {
            store.togglePin(item)
        }
    }

    private func statusText(now: Date) -> String {
        if item.isPinned { return L("Pinned") }
        guard let left = store.remainingTime(for: item, now: now) else {
            let mins = Int(now.timeIntervalSince(item.addedAt) / 60)
            return mins < 1 ? L("Just now") : L("%@ ago", "\(Self.duration(mins))")
        }
        let mins = Int(ceil(left / 60))
        return left < 60 ? L("Deleted in a minute") : L("%@ left", "\(Self.duration(mins))")
    }

    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return L("%@ min", "\(minutes)") }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? L("%@ h", "\(h)") : L("%@ h %@ min", "\(h)", "\(m)")
    }
}

// MARK: Буфер обмена

struct ClipboardRow: View {
    @ObservedObject var clipboard: ClipboardHistory

    var body: some View {
        if clipboard.entries.isEmpty {
            EmptyState(filter: .clipboard)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                GlassGroup(spacing: 6) {
                    HStack(alignment: .top, spacing: ShelfLayout.cardSpacing) {
                        ForEach(clipboard.entries) { entry in
                            ClipCard(entry: entry, clipboard: clipboard)
                                .transition(.scale(scale: 0.7).combined(with: .opacity))
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, ShelfLayout.panelPadding)
                    .animation(.spring(response: 0.42, dampingFraction: 0.8), value: clipboard.entries.map(\.id))
                }
            }
            .padding(.horizontal, -ShelfLayout.panelPadding)
        }
    }
}

struct ClipCard: View {
    let entry: ClipEntry
    @ObservedObject var clipboard: ClipboardHistory
    @State private var hovering = false
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 8) {
            preview
                .onTapGesture { clipboard.copy(entry) }
                .onDrag { dragProvider() }
                .help(L("Click to copy. You can also drag it"))
            footer.frame(height: 26)
        }
        .frame(width: ShelfLayout.cardWidth)
        .onReliableHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .task(id: entry.id) {
            if let url = entry.imageURL { image = NSImage(contentsOf: url) }
        }
    }

    private var preview: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return ZStack(alignment: .topLeading) {
            if let text = entry.text {
                shape.fill(Color.primary.opacity(0.06))
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(6)
                    .multilineTextAlignment(.leading)
                    .padding(9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                shape.fill(Color.primary.opacity(0.06))
            }
            if entry.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.accentColor))
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(width: ShelfLayout.cardWidth, height: ShelfLayout.thumbHeight)
        .clipShape(shape)
        .overlay(shape.strokeBorder(entry.isPinned ? Color.accentColor.opacity(0.9) : .white.opacity(0.22),
                                    lineWidth: entry.isPinned ? 1.5 : 0.5))
        .contentShape(shape)
        .shadow(color: .black.opacity(hovering ? 0.24 : 0.12), radius: hovering ? 9 : 4, y: hovering ? 4 : 2)
        .scaleEffect(hovering ? 1.035 : 1)
    }

    private func dragProvider() -> NSItemProvider {
        if let text = entry.text { return NSItemProvider(object: text as NSString) }
        if let url = entry.imageURL, let provider = NSItemProvider(contentsOf: url) { return provider }
        return NSItemProvider()
    }

    @ViewBuilder
    private var footer: some View {
        ZStack {
            if hovering {
                HStack(spacing: 6) {
                    GlassIconButton(systemName: "doc.on.doc", help: L("Copy")) { clipboard.copy(entry) }
                    GlassIconButton(systemName: entry.isPinned ? "pin.slash" : "pin",
                                    help: entry.isPinned ? L("Unpin") : L("Pin")) { clipboard.togglePin(entry) }
                    GlassIconButton(systemName: "trash", help: L("Remove from history"), role: .destructive) {
                        clipboard.remove(entry)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(subtitle(now: ctx.date))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .transition(.opacity)
            }
        }
    }

    private func subtitle(now: Date) -> String {
        let mins = Int(now.timeIntervalSince(entry.date) / 60)
        let time = mins < 1 ? L("just now") : L("%@ ago", "\(ShotCard.duration(mins))")
        if let app = entry.appName { return "\(app) · \(time)" }
        return time
    }
}

// MARK: - Плашка при выделении текста

struct SelectionBar: View {
    let text: String
    @ObservedObject var settings: AppSettings
    let ask: (AIProvider, String?) -> Void
    let dismiss: () -> Void

    private var preview: String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 40 ? String(flat.prefix(40)) + "…" : flat
    }

    var body: some View {
        let providers = settings.availableProviders
        let main = settings.preferredProvider
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
            Text("«\(preview)»")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 170, alignment: .leading)

            Divider().frame(height: 20)

            ForEach(providers) { p in
                SelectionPill(title: L("Ask %@", "\(p.title)")) { ask(p, nil) }
            }

            if let main {
                Divider().frame(height: 20)
                GlassGroup(spacing: 4) {
                    HStack(spacing: 4) {
                        ForEach(AskModel.quickActions.prefix(3)) { action in
                            GlassIconButton(systemName: action.icon, help: "\(action.title) — \(main.title)", size: 28) {
                                ask(main, action.prompt)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)
            GlassIconButton(systemName: "xmark", help: L("Hide"), size: 24) { dismiss() }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassBackground(Capsule())
    }
}

private struct SelectionPill: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 11)
                .frame(height: 28)
                .foregroundStyle(.white)
                .background(Capsule().fill(Color.accentColor.opacity(hovering ? 1 : 0.88)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.04 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onReliableHover { hovering = $0 }
    }
}
