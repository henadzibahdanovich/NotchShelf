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
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
