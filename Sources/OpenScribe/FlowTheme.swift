import SwiftUI

enum FlowTheme {
    private(set) static var variant: FlowThemeVariant = .whisperFlow

    static func apply(_ variant: FlowThemeVariant) {
        self.variant = variant
    }

    static var paper: Color {
        switch variant {
        case .light:
            return Color(red: 1.0, green: 1.0, blue: 1.0)
        case .dark:
            return Color(red: 0.10, green: 0.095, blue: 0.12)
        case .whisperFlow:
            return Color(red: 1.0, green: 1.0, blue: 0.92)
        }
    }

    static var paperMuted: Color {
        switch variant {
        case .light:
            return Color(red: 0.95, green: 0.95, blue: 0.97)
        case .dark:
            return Color(red: 0.16, green: 0.15, blue: 0.18)
        case .whisperFlow:
            return Color(red: 0.96, green: 0.96, blue: 0.88)
        }
    }

    static var ink: Color {
        switch variant {
        case .light:
            return Color(red: 0.08, green: 0.08, blue: 0.10)
        case .dark:
            return Color(red: 0.94, green: 0.93, blue: 0.90)
        case .whisperFlow:
            return Color(red: 0.10, green: 0.10, blue: 0.10)
        }
    }

    static var inkMuted: Color {
        switch variant {
        case .light:
            return Color(red: 0.35, green: 0.35, blue: 0.39)
        case .dark:
            return Color(red: 0.67, green: 0.66, blue: 0.70)
        case .whisperFlow:
            return Color(red: 0.33, green: 0.32, blue: 0.29)
        }
    }

    static var line: Color {
        switch variant {
        case .dark:
            return Color.white.opacity(0.18)
        default:
            return ink.opacity(0.18)
        }
    }

    static var lavender: Color {
        switch variant {
        case .light:
            return Color(red: 0.89, green: 0.81, blue: 1.0)
        case .dark:
            return Color(red: 0.35, green: 0.25, blue: 0.48)
        case .whisperFlow:
            return Color(red: 0.94, green: 0.84, blue: 1.0)
        }
    }

    static var lavenderDeep: Color {
        switch variant {
        case .light:
            return Color(red: 0.42, green: 0.27, blue: 0.60)
        case .dark:
            return Color(red: 0.79, green: 0.67, blue: 1.0)
        case .whisperFlow:
            return Color(red: 0.57, green: 0.38, blue: 0.70)
        }
    }

    static var mint: Color {
        switch variant {
        case .light:
            return Color(red: 0.78, green: 0.93, blue: 0.85)
        case .dark:
            return Color(red: 0.28, green: 0.55, blue: 0.42)
        case .whisperFlow:
            return Color(red: 0.82, green: 0.94, blue: 0.88)
        }
    }

    static var coral: Color {
        switch variant {
        case .light:
            return Color(red: 0.84, green: 0.30, blue: 0.32)
        case .dark:
            return Color(red: 1.0, green: 0.48, blue: 0.50)
        case .whisperFlow:
            return Color(red: 1.0, green: 0.65, blue: 0.62)
        }
    }
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
            .accessibilityLabel("Whisperlight voice waveform")
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
 
 

extension View {
    func flowDisplayFont(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        font(.system(size: size, design: .serif).weight(weight))
    }

    func flowUIFont(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        font(.system(size: size, design: .rounded).weight(weight))
    }

    func flowCard(inset: CGFloat = 18) -> some View {
        self.padding(inset)
            .background(FlowTheme.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(FlowTheme.ink, lineWidth: 1.5))
    }

    func flowPill() -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(FlowTheme.paperMuted, in: Capsule())
            .overlay(Capsule().stroke(FlowTheme.ink, lineWidth: 1))
    }


    func flowFieldRow() -> some View {
        padding(.vertical, 3)
    }
}

struct FlowPrimaryButtonStyle: ButtonStyle {
    var tint: Color = FlowTheme.lavender

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .flowUIFont(size: 13, weight: .semibold)
            .foregroundStyle(FlowTheme.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(FlowTheme.ink, lineWidth: 1.5))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct FlowQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .flowUIFont(size: 12, weight: .medium)
            .foregroundStyle(FlowTheme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(configuration.isPressed ? FlowTheme.paperMuted : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct FlowMenuItemStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? FlowTheme.lavender : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct FlowSectionHeading: View {
    let eyebrow: String
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(eyebrow.uppercased())
                .flowUIFont(size: 10, weight: .semibold)
                .tracking(1.4)
                .foregroundStyle(FlowTheme.lavenderDeep)
            Text(title)
                .flowDisplayFont(size: 32)
                .foregroundStyle(FlowTheme.ink)
            if let detail {
                Text(detail)
                    .flowUIFont(size: 13)
                    .foregroundStyle(FlowTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
