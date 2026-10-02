import AppKit
import SwiftUI

/// Design tokens. Every color resolves against the current appearance, so views follow
/// the system (or the theme chosen in Settings) without being rebuilt.
enum FlowTheme {
    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static let background = dynamic(light: rgb(0.975, 0.970, 0.951), dark: rgb(0.067, 0.071, 0.067))
    static let surface = dynamic(light: rgb(0.998, 0.997, 0.988), dark: rgb(0.110, 0.118, 0.110))
    static let surfaceMuted = dynamic(light: rgb(0.15, 0.17, 0.12, 0.05), dark: rgb(0.98, 0.97, 0.92, 0.06))
    static let surfaceHover = dynamic(light: rgb(0.15, 0.17, 0.12, 0.08), dark: rgb(0.98, 0.97, 0.92, 0.10))
    static let line = dynamic(light: rgb(0.15, 0.17, 0.12, 0.12), dark: rgb(0.98, 0.97, 0.92, 0.10))

    static let ink = dynamic(light: rgb(0.12, 0.14, 0.11), dark: rgb(0.96, 0.95, 0.91))
    static let inkMuted = dynamic(light: rgb(0.12, 0.14, 0.11, 0.65), dark: rgb(0.96, 0.95, 0.91, 0.65))
    static let inkFaint = dynamic(light: rgb(0.12, 0.14, 0.11, 0.48), dark: rgb(0.96, 0.95, 0.91, 0.46))

    static let accent = dynamic(light: rgb(0.68, 0.32, 0.10), dark: rgb(0.94, 0.72, 0.39))
    static let accentSoft = dynamic(light: rgb(0.68, 0.32, 0.10, 0.08), dark: rgb(0.94, 0.72, 0.39, 0.10))
    static let primaryText = dynamic(light: rgb(1, 0.99, 0.96), dark: rgb(0.12, 0.14, 0.11))
    static let recording = dynamic(light: rgb(0.91, 0.24, 0.27), dark: rgb(1.0, 0.39, 0.40))
    static let success = dynamic(light: rgb(0.13, 0.62, 0.38), dark: rgb(0.30, 0.82, 0.55))
    static let warning = dynamic(light: rgb(0.80, 0.50, 0.05), dark: rgb(1.0, 0.72, 0.28))

    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.82)
}

struct WhisperlightLogo: View {
    let size: CGFloat

    init(size: CGFloat = 32) {
        self.size = size
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Color(red: 0.08, green: 0.09, blue: 0.12))
            .overlay(
                WhisperlightWave()
                    .stroke(
                        Color(red: 1.0, green: 0.98, blue: 0.90),
                        style: StrokeStyle(
                            lineWidth: max(1.6, size * 0.075),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .padding(size * 0.23)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: max(1, size * 0.03))
            )
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.22), radius: size * 0.14, y: size * 0.06)
            .accessibilityLabel("OpenScribe")
    }
}

struct WhisperlightWave: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let y = rect.midY
        let quarter = rect.width * 0.25

        path.move(to: CGPoint(x: rect.minX, y: y))
        path.addCurve(
            to: CGPoint(x: rect.minX + quarter, y: y),
            control1: CGPoint(x: rect.minX + quarter * 0.34, y: rect.minY),
            control2: CGPoint(x: rect.minX + quarter * 0.66, y: rect.minY)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + quarter * 2, y: y),
            control1: CGPoint(x: rect.minX + quarter * 1.34, y: rect.maxY),
            control2: CGPoint(x: rect.minX + quarter * 1.66, y: rect.maxY)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + quarter * 3, y: y),
            control1: CGPoint(x: rect.minX + quarter * 2.34, y: rect.minY),
            control2: CGPoint(x: rect.minX + quarter * 2.66, y: rect.minY)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: y),
            control1: CGPoint(x: rect.minX + quarter * 3.34, y: rect.maxY),
            control2: CGPoint(x: rect.minX + quarter * 3.66, y: rect.maxY)
        )
        return path
    }
}

/// Native translucency for the sidebar and floating panels.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.material = material
        view.blendingMode = blendingMode
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}

extension View {
    func flowCard(padding: CGFloat = 18, radius: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(FlowTheme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(FlowTheme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }

    func flowField() -> some View {
        textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(FlowTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.line, lineWidth: 1))
    }
}
