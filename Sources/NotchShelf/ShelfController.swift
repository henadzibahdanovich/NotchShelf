import AppKit
import Combine
import SwiftUI

/// Геометрия полки — общая для SwiftUI и для проверки наведения мыши.
struct ShelfLayout: Equatable {
    var hasNotch: Bool = false
    var notchWidth: CGFloat = 0
    var menuBarHeight: CGFloat = 24

    static let earWidth: CGFloat = 44
    static let pillWidth: CGFloat = 92          // для экранов без чёлки
    static let gap: CGFloat = 8                 // зазор между чёлкой и панелью
    static let cardWidth: CGFloat = 132
    static let thumbHeight: CGFloat = 92
    static let cardSpacing: CGFloat = 10
    static let panelPadding: CGFloat = 14
    static let widgetHeight: CGFloat = 56
    static let contentHeight: CGFloat = 132     // превью 92 + 8 + подпись 26 + запас
    static let panelWidth: CGFloat = 640
    static let panelHeight: CGFloat = panelPadding * 2 + widgetHeight + 12 + 26 + 12 + contentHeight
    static let shadowMargin: CGFloat = 30

    var collapsedWidth: CGFloat {
        hasNotch ? notchWidth + Self.earWidth * 2 : Self.pillWidth
    }

    var windowSize: NSSize {
        NSSize(width: Self.panelWidth + Self.shadowMargin * 2,
               height: menuBarHeight + Self.gap + Self.panelHeight + Self.shadowMargin)
    }
}

@MainActor
final class ShelfUIState: ObservableObject {
    @Published var expanded = false
    @Published var layout = ShelfLayout()
    @Published var isDragging = false
}

/// Прозрачное окно-панель над строкой меню, в котором живёт полка.
final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ShelfController {
    let models: ShelfModels
    let store: ShelfStore
    let settings: AppSettings
    let ui = ShelfUIState()
    private var openWork: DispatchWorkItem?
    private let panel: ShelfPanel
    private var screen: NSScreen?
    private var monitors: [Any] = []
    private var collapseWork: DispatchWorkItem?
    private var peekWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var watchdog: Timer?

    init(models: ShelfModels, settings: AppSettings, openSettings: @escaping () -> Void) {
        self.models = models
        self.store = models.store
        self.settings = settings

        panel = ShelfPanel(contentRect: .zero,
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true

        let root = ShelfRootView(models: models, store: store, ui: ui, actions: ShelfActions(
            openSettings: openSettings,
            dragStarted: { [weak self] in self?.ui.isDragging = true },
            dragEnded: { [weak self] item, accepted in
                guard let self else { return }
                self.ui.isDragging = false
                if accepted { self.store.handleDropped(item) }
                self.scheduleCollapseIfMouseOutside()
            }
        ))
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting

        reposition()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }

        store.onNewItem = { [weak self] in self?.peek() }
        models.timer.onFinish = { [weak self] in
            self?.store.showToast("Время вышло")
            self?.peek(force: true)
        }
        models.clipboard.onToast = { [weak self] text in self?.store.showToast(text) }
        installMouseMonitors()
    }

    // MARK: Позиционирование

    private func reposition() {
        let target = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let target else { return }
        screen = target

        var layout = ShelfLayout()
        if target.safeAreaInsets.top > 0,
           let left = target.auxiliaryTopLeftArea, let right = target.auxiliaryTopRightArea {
            layout.hasNotch = true
            layout.menuBarHeight = target.safeAreaInsets.top
            layout.notchWidth = target.frame.width - left.width - right.width
        } else {
            layout.hasNotch = false
            let h = target.frame.maxY - target.visibleFrame.maxY
            layout.menuBarHeight = h > 0 ? h : 24
        }
        ui.layout = layout

        let size = layout.windowSize
        let origin = NSPoint(x: target.frame.midX - size.width / 2, y: target.frame.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // MARK: Наведение мыши

    /// Прямоугольники (в координатах экрана), где полка реагирует на мышь.
    private func hotRect(expanded: Bool) -> NSRect {
        guard let screen else { return .zero }
        let l = ui.layout
        let top = screen.frame.maxY
        let collapsed = NSRect(x: screen.frame.midX - l.collapsedWidth / 2, y: top - l.menuBarHeight,
                               width: l.collapsedWidth, height: l.menuBarHeight)
        guard expanded else { return collapsed }
        let w = ShelfLayout.panelWidth
        let panelRect = NSRect(x: screen.frame.midX - w / 2,
                               y: top - l.menuBarHeight - ShelfLayout.gap - ShelfLayout.panelHeight,
                               width: w, height: ShelfLayout.panelHeight + ShelfLayout.gap)
        return collapsed.union(panelRect).insetBy(dx: -6, dy: -6)
    }

    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return event
        }) { monitors.append(l) }
    }

    private func mouseMoved() {
        let p = NSEvent.mouseLocation
        if ui.expanded {
            if hotRect(expanded: true).contains(p) {
                collapseWork?.cancel()
                peekWork?.cancel()
            } else if peekWork == nil || peekWork!.isCancelled {
                scheduleCollapseIfMouseOutside()
            }
            return
        }
        // Свернуто: открываем, если мышь задержалась у чёлки (а не просто пролетела мимо)
        if hotRect(expanded: false).contains(p) {
            guard openWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.openWork = nil
                    if self.hotRect(expanded: false).contains(NSEvent.mouseLocation) {
                        self.setExpanded(true)
                    }
                }
            }
            openWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        } else {
            openWork?.cancel()
            openWork = nil
        }
    }

    private func scheduleCollapseIfMouseOutside(delay: TimeInterval = 0.35) {
        guard collapseWork == nil || collapseWork!.isCancelled else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.collapseWork = nil
                if self.ui.isDragging { return }
                if !self.hotRect(expanded: true).contains(NSEvent.mouseLocation) {
                    self.setExpanded(false)
                }
            }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setExpanded(_ value: Bool) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
            ui.expanded = value
        }
        panel.ignoresMouseEvents = !ui.expanded

        // Страховка: если мышь ушла слишком быстро и событие потерялось — всё равно сворачиваемся
        watchdog?.invalidate()
        watchdog = nil
        if ui.expanded {
            watchdog = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.peekWork == nil || self.peekWork!.isCancelled else { return }
                    if !self.hotRect(expanded: true).contains(NSEvent.mouseLocation) {
                        self.scheduleCollapseIfMouseOutside()
                    }
                }
            }
        }
    }

    /// Кратко показываем полку, когда приходит новый файл или срабатывает таймер.
    private func peek(force: Bool = false) {
        guard force || settings.peekOnCapture else { return }
        setExpanded(true)
        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.peekWork = nil
                guard !self.ui.isDragging else { return }
                if !self.hotRect(expanded: true).contains(NSEvent.mouseLocation) {
                    self.setExpanded(false)
                }
            }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func showFromMenu() {
        peek(force: true)
    }
}
