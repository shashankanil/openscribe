import AppKit
import SwiftUI

// MARK: - Buttons

struct FlowButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, destructive }
    enum Size { case small, regular, large }

    var kind: Kind = .secondary
    var size: Size = .regular
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        FlowButtonBody(configuration: configuration, kind: kind, size: size, fullWidth: fullWidth)
    }
}

private struct FlowButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: FlowButtonStyle.Kind
    let size: FlowButtonStyle.Size
    let fullWidth: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var fontSize: CGFloat { size == .small ? 11.5 : size == .large ? 14 : 12.5 }
    private var horizontal: CGFloat { size == .small ? 10 : size == .large ? 18 : 13 }
    private var vertical: CGFloat { size == .small ? 5 : size == .large ? 11 : 7 }
    private var radius: CGFloat { size == .large ? 11 : 8 }

    private var foreground: Color {
        switch kind {
        case .primary: return FlowTheme.primaryText
        case .secondary, .ghost: return FlowTheme.ink
        case .destructive: return FlowTheme.recording
        }
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        switch kind {
        case .primary:
            shape.fill(FlowTheme.accent)
                .overlay(shape.fill(Color.white.opacity(hovering ? 0.10 : 0)))
                .shadow(color: .black.opacity(isEnabled ? 0.10 : 0), radius: 3, y: 1)
        case .secondary:
            shape.fill(hovering ? FlowTheme.surfaceHover : FlowTheme.surfaceMuted)
                .overlay(shape.stroke(FlowTheme.line, lineWidth: 1))
        case .ghost:
            shape.fill(hovering ? FlowTheme.surfaceMuted : Color.clear)
        case .destructive:
            shape.fill(FlowTheme.recording.opacity(hovering ? 0.16 : 0.09))
        }
    }

    var body: some View {
        configuration.label
            .font(.system(size: fontSize, weight: .semibold))
            .labelStyle(FlowLabelStyle())
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(background)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 && isEnabled }
    }
}

private struct FlowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

extension ButtonStyle where Self == FlowButtonStyle {
    static var flowPrimary: FlowButtonStyle { FlowButtonStyle(kind: .primary) }
    static var flowSecondary: FlowButtonStyle { FlowButtonStyle(kind: .secondary) }
    static var flowGhost: FlowButtonStyle { FlowButtonStyle(kind: .ghost) }
    static var flowDestructive: FlowButtonStyle { FlowButtonStyle(kind: .destructive) }
    static func flow(_ kind: FlowButtonStyle.Kind, size: FlowButtonStyle.Size = .regular, fullWidth: Bool = false) -> FlowButtonStyle {
        FlowButtonStyle(kind: kind, size: size, fullWidth: fullWidth)
    }
}

/// A square, symbol-only button with a hover highlight and tooltip.
struct FlowIconButton: View {
    let symbol: String
    let help: String
    var tint: Color = FlowTheme.inkMuted
    var size: CGFloat = 28
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(hovering ? FlowTheme.ink : tint)
                .frame(width: size, height: size)
                .background(hovering ? FlowTheme.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 && isEnabled }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Inputs

struct FlowSearchField: View {
    @Binding var text: String
    var prompt = "Search"
    var focus: FocusState<Bool>.Binding?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(FlowTheme.inkFaint)
            field
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(FlowTheme.inkFaint)
                }.buttonStyle(.plain).help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(FlowTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.line, lineWidth: 1))
    }

    @ViewBuilder private var field: some View {
        let base = TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 13))
        if let focus { base.focused(focus) } else { base }
    }
}

/// Pill tabs with a sliding selection.
struct FlowTabs<Value: Hashable>: View {
    let items: [(value: Value, title: String)]
    @Binding var selection: Value
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                let selected = item.value == selection
                Button {
                    withAnimation(FlowTheme.spring) { selection = item.value }
                } label: {
                    Text(item.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? FlowTheme.ink : FlowTheme.inkMuted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(FlowTheme.surface)
                                    .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(FlowTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Display

struct FlowBadge: View {
    let text: String
    var color: Color = FlowTheme.inkMuted
    var symbol: String?
    var pulsing = false
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
                    .opacity(pulsing && pulse ? 0.35 : 1)
            }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(color.opacity(0.13), in: Capsule())
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// Renders a shortcut such as "⌥ Space" as individual keys.
struct FlowKeycaps: View {
    let shortcut: String

    private var keys: [String] {
        let parts = shortcut.split(separator: " ").map(String.init)
        guard parts.count > 1, let modifiers = parts.first else { return parts.isEmpty ? [shortcut] : parts }
        return modifiers.map(String.init) + parts.dropFirst()
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(FlowTheme.inkMuted)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 22, minHeight: 21)
                    .background(FlowTheme.surface, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(FlowTheme.line, lineWidth: 1))
                    .shadow(color: .black.opacity(0.06), radius: 0, y: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut)
    }
}

struct FlowEmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(FlowTheme.accent)
                .frame(width: 68, height: 68)
                .background(FlowTheme.accentSoft, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            VStack(spacing: 6) {
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(FlowTheme.ink)
                Text(message).font(.system(size: 13)).foregroundStyle(FlowTheme.inkMuted)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            actions().padding(.top, 4)
        }
        .frame(maxWidth: 380)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension FlowEmptyState where Actions == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

struct FlowPageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 24, weight: .bold)).foregroundStyle(FlowTheme.ink)
                if let subtitle {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(FlowTheme.inkMuted).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
    }
}

extension FlowPageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// An inline strip for states that need a decision, such as a recording in progress.
struct FlowBanner<Actions: View>: View {
    let symbol: String
    var tint: Color = FlowTheme.accent
    let title: String
    var detail: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(FlowTheme.ink).lineLimit(1)
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkMuted).lineLimit(2)
                }
            }
            Spacer(minLength: 10)
            actions()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(tint.opacity(0.22), lineWidth: 1))
    }
}

/// Live input meter. Falls back to a gentle pulse when no levels are supplied.
struct FlowWaveform: View {
    var levels: [Float]
    var color: Color = FlowTheme.recording
    var barWidth: CGFloat = 2.6
    var spacing: CGFloat = 3
    var maxHeight: CGFloat = 22
    var animated = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: !animated)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: spacing) {
                ForEach(levels.indices, id: \.self) { index in
                    let level = animated
                        ? Float(0.14 + abs(sin(time * 3.4 + Double(index) * 0.55)) * 0.36)
                        : max(0.06, min(1, levels[index]))
                    Capsule().fill(color)
                        .frame(width: barWidth, height: max(barWidth, CGFloat(level) * maxHeight))
                        .animation(.easeOut(duration: 0.08), value: level)
                }
            }
            .frame(height: maxHeight)
        }
    }
}

// MARK: - Settings layout

struct FlowSettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(FlowTheme.ink).padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FlowTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(FlowTheme.line, lineWidth: 1))
            if let footer {
                Text(footer).font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
    }
}

struct FlowSettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var symbol: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(FlowTheme.accent)
                    .frame(width: 28, height: 28)
                    .background(FlowTheme.accentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(FlowTheme.ink)
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

struct FlowRowDivider: View {
    var body: some View {
        Rectangle().fill(FlowTheme.line).frame(height: 1).padding(.leading, 14)
    }
}

// MARK: - Feedback

/// Brief confirmation shown inside the main window.
struct FlowToast: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(FlowTheme.success)
            Text(message).font(.system(size: 12.5, weight: .medium)).foregroundStyle(FlowTheme.ink)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(FlowTheme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
    }
}

extension View {
    /// Subtle highlight for clickable rows and cards.
    func flowHoverHighlight(radius: CGFloat = 10) -> some View {
        modifier(FlowHoverHighlight(radius: radius))
    }
}

private struct FlowHoverHighlight: ViewModifier {
    let radius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering ? FlowTheme.surfaceMuted : .clear, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

enum FlowFormat {
    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
