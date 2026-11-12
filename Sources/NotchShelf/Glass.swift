import AppKit
import SwiftUI

// Liquid Glass на macOS 26 (Tahoe) и аккуратный «стеклянный» фолбэк на macOS 14–15.

extension View {
    @ViewBuilder
    func glassBackground<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(interactive ? Glass.regular.interactive() : Glass.regular, in: shape)
        } else {
            self.background(LegacyGlass(shape: shape))
        }
        #else
        self.background(LegacyGlass(shape: shape))
        #endif
    }
}

/// Группирует стеклянные элементы, чтобы на macOS 26 они «сливались» как единое стекло.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

private struct LegacyGlass<S: Shape>: View {
    let shape: S
    var body: some View {
        VisualEffectBlur()
            .clipShape(shape)
            .overlay(
                shape.stroke(
                    LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.08)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.8
                )
            )
            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }
}

private struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Круглая стеклянная кнопка с SF Symbol — основной элемент управления на карточке.
struct GlassIconButton: View {
    let systemName: String
    let help: String
    var role: ButtonRole? = nil
    var size: CGFloat = 26
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(role == .destructive && hovering ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassBackground(Circle(), interactive: true)
        .scaleEffect(hovering ? 1.08 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onReliableHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Надёжное наведение мыши

/// Замена `.onHover` для плавающей панели. Штатное наведение SwiftUI в неактивном окне
/// путает карточки в прокручиваемых списках, а положение AppKit-видов внутри стеклянных
/// контейнеров не совпадает с тем, что на экране. Поэтому считаем сами: рамку элемента
/// даёт SwiftUI (GeometryReader), положение курсора — окно полки.
final class HoverToken {
    var frame: CGRect = .null          // в координатах окна полки (начало — левый верхний угол)
    var action: ((Bool) -> Void)?
    private(set) var inside = false

    func update(mouse: CGPoint?) {
        let now = mouse.map { frame.contains($0) } ?? false
        guard now != inside else { return }
        inside = now
        action?(now)
    }
}

/// Один наблюдатель за мышью: при движении и прокрутке все элементы сверяют свою рамку с курсором.
@MainActor
final class HoverHub {
    static let shared = HoverHub()
    private let tokens = NSHashTable<HoverToken>.weakObjects()
    private var installed = false
    private weak var shelfWindow: NSWindow?

    func register(_ token: HoverToken) {
        tokens.add(token)
        installIfNeeded()
        token.update(mouse: mousePoint())
    }

    func unregister(_ token: HoverToken) {
        tokens.remove(token)
        token.update(mouse: nil)
    }

    func recheck(_ token: HoverToken) {
        token.update(mouse: mousePoint())
    }

    /// Курсор в координатах содержимого окна полки, начало — левый верхний угол (как у SwiftUI).
    private func mousePoint() -> CGPoint? {
        if shelfWindow == nil { shelfWindow = NSApp.windows.first { $0 is ShelfPanel } }
        guard let window = shelfWindow, window.isVisible, let content = window.contentView else { return nil }
        let p = window.mouseLocationOutsideOfEventStream
        return CGPoint(x: p.x, y: content.bounds.height - p.y)
    }

    private func refresh() {
        let point = mousePoint()
        for token in tokens.allObjects { token.update(mouse: point) }
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        let local: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp, .scrollWheel]
        _ = NSEvent.addLocalMonitorForEvents(matching: local) { [weak self] event in
            MainActor.assumeIsolated { self?.refresh() }
            return event
        }
        _ = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}

private struct ReliableHover: ViewModifier {
    let action: (Bool) -> Void
    @State private var token = HoverToken()

    func body(content: Content) -> some View {
        token.action = action
        return content
            .background(
                GeometryReader { geo in
                    let frame = geo.frame(in: .global)
                    Color.clear
                        .onAppear {
                            token.frame = frame
                            HoverHub.shared.register(token)
                        }
                        // Рамка меняется при прокрутке и перестановке карточек
                        .onChange(of: frame) { _, newFrame in
                            token.frame = newFrame
                            HoverHub.shared.recheck(token)
                        }
                        .onDisappear { HoverHub.shared.unregister(token) }
                }
            )
    }
}

extension View {
    /// Наведение по геометрии (см. HoverHub).
    func onReliableHover(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(ReliableHover(action: action))
    }
}
