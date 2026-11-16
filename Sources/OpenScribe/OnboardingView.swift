import SwiftUI

/// The screens of first-run setup, in order. Only the four middle steps show progress dots.
enum OnboardingStep: String, CaseIterable, Identifiable {
    case welcome, microphone, connect, everyApp, tryIt, done

    var id: String { rawValue }

    /// Position among the progress dots, if this step has one.
    var progressIndex: Int? {
        switch self {
        case .microphone: return 0
        case .connect: return 1
        case .everyApp: return 2
        case .tryIt: return 3
        case .welcome, .done: return nil
        }
    }
    static let progressCount = 4

    var next: OnboardingStep? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
        return all[index + 1]
    }

    var previous: OnboardingStep? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index > 0 else { return nil }
        return all[index - 1]
    }

    /// Where to pick up, from facts first and the saved step second: the first missing requirement
    /// (microphone, then key); with both in place, Try it if the person got that far or Accessibility is
    /// already allowed, otherwise the optional Accessibility step. Someone who never left Welcome starts there.
    static func resume(from readiness: SetupReadiness, saved: OnboardingStep?) -> OnboardingStep {
        guard saved != nil else { return .welcome }
        if !readiness.microphone { return .microphone }
        if !readiness.speechKey { return .connect }
        if saved == .tryIt || saved == .done || readiness.accessibility { return .tryIt }
        return .everyApp
    }

    private static let savedKey = "onboarding-v4-step"
    static var saved: OnboardingStep? { UserDefaults.standard.string(forKey: savedKey).flatMap(OnboardingStep.init(rawValue:)) }
    static func save(_ step: OnboardingStep) {
        guard step != .welcome else { return }
        UserDefaults.standard.set(step.rawValue, forKey: savedKey)
    }
    static func clearSaved() { UserDefaults.standard.removeObject(forKey: savedKey) }
}

/// Moves between steps. Steps decide when to call it; the container owns the current step.
struct OnboardingNavigator {
    let step: OnboardingStep
    /// False in previews and render tests: no system prompts, audio, Flowbar or saved progress.
    let live: Bool
    let go: (OnboardingStep) -> Void

    func next() { if let next = step.next { go(next) } }
    func back() { if let previous = step.previous { go(previous) } }
}

/// First-run setup, shown in its own small window. Welcome → Microphone → Connect → Works in every app
/// → Try it → Meet the Flowbar.
struct OnboardingView: View {
    static let windowSize = CGSize(width: 760, height: 560)

    @ObservedObject var controller: AppController
    @State private var step: OnboardingStep
    @State private var forward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let live: Bool

    /// The app's setup window: resumes from what is already in place, or starts over when `restart` is set.
    init(controller: AppController, restart: Bool = false) {
        self.controller = controller
        live = true
        _step = State(initialValue: restart ? .welcome
                      : OnboardingStep.resume(from: controller.setupReadiness, saved: OnboardingStep.saved))
    }

    /// Previews and render tests: a fixed step with no side effects.
    init(controller: AppController, initialStep: OnboardingStep) {
        self.controller = controller
        live = false
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        ZStack {
            page.id(step).transition(transition)
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .background(FlowTheme.background)
        .foregroundStyle(FlowTheme.ink)
        .tint(FlowTheme.accent)
        .ignoresSafeArea()
        .onChange(of: step) { _, step in if live { OnboardingStep.save(step) } }
    }

    @ViewBuilder private var page: some View {
        let nav = OnboardingNavigator(step: step, live: live, go: go)
        switch step {
        case .welcome: OnboardingWelcomeStep(nav: nav)
        case .microphone: OnboardingMicrophoneStep(controller: controller, permissions: controller.permissions, nav: nav)
        case .connect: OnboardingConnectStep(controller: controller, nav: nav)
        case .everyApp: OnboardingEveryAppStep(controller: controller, permissions: controller.permissions, nav: nav)
        case .tryIt: OnboardingTryItStep(controller: controller, permissions: controller.permissions, nav: nav)
        case .done: OnboardingDoneStep(controller: controller, nav: nav)
        }
    }

    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: forward ? 28 : -28)), removal: .opacity)
    }

    private func go(_ target: OnboardingStep) {
        guard target != step else { return }
        let all = OnboardingStep.allCases
        forward = (all.firstIndex(of: target) ?? 0) > (all.firstIndex(of: step) ?? 0)
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.24)) { step = target }
    }
}

// MARK: - Shared layout

/// One screen: content centered vertically in the window, a footer with progress (or a note) and actions.
struct OnboardingPage<Content: View, Leading: View, Actions: View>: View {
    let step: OnboardingStep
    var centered = false
    var spacing: CGFloat = 16
    @ViewBuilder var content: () -> Content
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: centered ? .center : .leading, spacing: spacing) { content() }
                .multilineTextAlignment(centered ? .center : .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: centered ? .center : .leading)
                .padding(.horizontal, 60)
                .padding(.top, 44)
                .padding(.bottom, 6)
            HStack(spacing: 12) {
                leading()
                Spacer(minLength: 12)
                HStack(spacing: 8) { actions() }
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 18)
        }
    }
}

extension OnboardingPage where Leading == OnboardingProgress {
    init(step: OnboardingStep, centered: Bool = false, spacing: CGFloat = 16,
         @ViewBuilder content: @escaping () -> Content, @ViewBuilder actions: @escaping () -> Actions) {
        self.init(step: step, centered: centered, spacing: spacing, content: content,
                  leading: { OnboardingProgress(step: step) }, actions: actions)
    }
}

/// Four dots: finished steps faded, the current one stretched into a pill.
struct OnboardingProgress: View {
    let step: OnboardingStep

    var body: some View {
        let current = step.progressIndex ?? -1
        HStack(spacing: 7) {
            ForEach(0..<OnboardingStep.progressCount, id: \.self) { index in
                Capsule()
                    .fill(index <= current ? FlowTheme.accent : FlowTheme.line)
                    .opacity(index < current ? 0.45 : 1)
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(current >= 0 ? "Step \(current + 1) of \(OnboardingStep.progressCount)" : "")
    }
}

enum OnboardingText {
    static func eyebrow(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(FlowTheme.inkFaint)
    }

    static func title(_ text: String, size: CGFloat = 27) -> some View {
        Text(text).font(.system(size: size, weight: .bold)).tracking(size > 30 ? -0.9 : -0.6)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    static func body(_ text: String) -> some View {
        Text(text).font(.system(size: 13.5)).foregroundStyle(FlowTheme.inkMuted)
            .frame(maxWidth: 470, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkFaint).fixedSize(horizontal: false, vertical: true)
    }
}

/// A filled circle with a check, or an empty ring for something still to do.
struct OnboardingCheck: View {
    let done: Bool
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle().fill(done ? FlowTheme.success : Color.clear)
            Circle().stroke(done ? Color.clear : FlowTheme.line, lineWidth: 1.5)
            if done {
                Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .heavy)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The Flowbar's dark pill, used in the Welcome and Done illustrations.
struct OnboardingPill<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 9) { content() }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(OnboardingPalette.pillInk)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule(style: .circular).fill(OnboardingPalette.pill).shadow(color: .black.opacity(0.25), radius: 9, y: 6))
            .overlay(Capsule(style: .circular).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }
}

enum OnboardingPalette {
    static let pill = Color(red: 0.08, green: 0.09, blue: 0.12)
    static let pillInk = Color(red: 1.0, green: 0.98, blue: 0.90)
    static let pillRecording = Color(red: 1.0, green: 0.39, blue: 0.40)
}

extension AccessibilityNotification.Announcement {
    /// VoiceOver hears status changes such as "Microphone allowed".
    static func say(_ message: String) { AccessibilityNotification.Announcement(message).post() }
}
