import AppKit
import SwiftUI

@main
struct OpenScribeInstallerApp: App {
    @NSApplicationDelegateAdaptor(InstallerAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            InstallerView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 620, height: 460)
    }
}

final class InstallerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private enum InstallState: Equatable {
    case ready
    case installing
    case installed
    case failed(String)
}

private struct InstallerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var state: InstallState = .ready

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.055, green: 0.065, blue: 0.09), Color(red: 0.12, green: 0.10, blue: 0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color(red: 0.67, green: 0.51, blue: 0.86).opacity(0.18))
                .frame(width: 270, height: 270)
                .blur(radius: 12)
                .offset(x: 250, y: -190)

            Circle()
                .fill(Color(red: 0.42, green: 0.90, blue: 0.73).opacity(0.10))
                .frame(width: 220, height: 220)
                .blur(radius: 20)
                .offset(x: -270, y: 220)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("OPENSCRIBE")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .tracking(2.2)
                            .foregroundStyle(Color(red: 0.73, green: 0.64, blue: 0.98))
                        Text("Speak it. OpenScribe types it.")
                            .font(.system(size: 28, weight: .medium, design: .serif))
                            .foregroundStyle(Color(red: 0.98, green: 0.97, blue: 0.91))
                    }
                    Spacer()
                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.60))
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close installer")
                }

                Text("Move the signal into Applications, then start dictating.")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.60))
                    .padding(.top, 8)

                HStack(spacing: 16) {
                    InstallerTile(
                        label: "OpenScribe",
                        tint: Color(red: 0.73, green: 0.64, blue: 0.98),
                        content: AnyView(InstallerLogo())
                    )

                    HStack(spacing: 5) {
                        WaveformLine()
                            .stroke(Color(red: 0.73, green: 0.64, blue: 0.98).opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .frame(width: 76, height: 28)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.70))
                    }
                    .frame(maxWidth: .infinity)

                    InstallerTile(
                        label: "Applications",
                        tint: Color(red: 0.42, green: 0.90, blue: 0.73),
                        content: AnyView(
                            Image(systemName: "folder.fill")
                                .font(.system(size: 54, weight: .medium))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(Color(red: 0.42, green: 0.90, blue: 0.73))
                        )
                    )
                }
                .padding(.top, 34)

                Spacer(minLength: 20)

                Group {
                    switch state {
                    case .ready:
                        Button(action: install) {
                            Label("Install to Applications", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(InstallerPrimaryButtonStyle())
                    case .installing:
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Color(red: 0.10, green: 0.08, blue: 0.13))
                            Text("Preparing OpenScribe…")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(red: 0.73, green: 0.64, blue: 0.98), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(Color(red: 0.10, green: 0.08, blue: 0.13))
                    case .installed:
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/OpenScribe.app"))
                            NSApp.terminate(nil)
                        } label: {
                            Label("Open OpenScribe", systemImage: "waveform")
                        }
                        .buttonStyle(InstallerPrimaryButtonStyle())
                    case .failed(let message):
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Installation needs attention")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(red: 1.0, green: 0.66, blue: 0.62))
                            Text(message)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.68))
                                .lineLimit(3)
                            Button("Try again", action: install)
                                .buttonStyle(InstallerSecondaryButtonStyle())
                        }
                    }
                }

                Text("The installer copies the app, clears its download quarantine, and opens it for you.")
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.42))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 12)
            }
            .padding(34)
        }
        .frame(width: 620, height: 460)
        .preferredColorScheme(.dark)
    }

    private func install() {
        guard state != .installing else { return }
        state = .installing
        let source = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("OpenScribe.app")
        let target = URL(fileURLWithPath: "/Applications/OpenScribe.app")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = InstallerOperations.install(source: source, target: target)
            DispatchQueue.main.async {
                switch result {
                case .success:
                    state = .installed
                case .failure(let error):
                    state = .failed(error.localizedDescription)
                }
            }
        }
    }
}

private enum InstallerOperations {
    static func install(source: URL, target: URL) -> Result<Void, Error> {
        guard FileManager.default.fileExists(atPath: source.path) else {
            return .failure(InstallerError.appNotFound(source.path))
        }

        let script = """
        on run argv
            set sourceApp to item 1 of argv
            set targetApp to item 2 of argv
            set command to "/bin/rm -rf " & quoted form of targetApp & " && /usr/bin/ditto --rsrc --extattr --acl " & quoted form of sourceApp & " " & quoted form of targetApp & " && /usr/bin/xattr -dr com.apple.quarantine " & quoted form of targetApp & " && /usr/bin/open " & quoted form of targetApp
            do shell script command with administrator privileges
        end run
        """

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, source.path, target.path]
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure(error)
        }

        guard process.terminationStatus == 0 else {
            let message = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(InstallerError.installFailed(message ?? "The installation was cancelled."))
        }
        return .success(())
    }
}

private enum InstallerError: LocalizedError {
    case appNotFound(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .appNotFound(let path):
            return "OpenScribe.app was not found beside this installer (looked at \(path))."
        case .installFailed(let message):
            return message
        }
    }
}

private struct InstallerTile: View {
    let label: String
    let tint: Color
    let content: AnyView

    var body: some View {
        VStack(spacing: 11) {
            content
                .frame(width: 88, height: 88)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(tint.opacity(0.24), lineWidth: 1))
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.76))
        }
        .frame(width: 118)
    }
}

private struct InstallerLogo: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(red: 0.035, green: 0.045, blue: 0.065))
            WaveformLine()
                .stroke(Color(red: 1.0, green: 0.98, blue: 0.90), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
                .padding(18)
        }
        .padding(14)
    }
}

private struct WaveformLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let y = rect.midY
        let q = rect.width * 0.25
        path.move(to: CGPoint(x: rect.minX, y: y))
        path.addCurve(to: CGPoint(x: rect.minX + q, y: y), control1: CGPoint(x: rect.minX + q * 0.34, y: rect.minY), control2: CGPoint(x: rect.minX + q * 0.66, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.minX + q * 2, y: y), control1: CGPoint(x: rect.minX + q * 1.34, y: rect.maxY), control2: CGPoint(x: rect.minX + q * 1.66, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.minX + q * 3, y: y), control1: CGPoint(x: rect.minX + q * 2.34, y: rect.minY), control2: CGPoint(x: rect.minX + q * 2.66, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: y), control1: CGPoint(x: rect.minX + q * 3.34, y: rect.maxY), control2: CGPoint(x: rect.minX + q * 3.66, y: rect.maxY))
        return path
    }
}

private struct InstallerPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(Color(red: 0.10, green: 0.08, blue: 0.13))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color(red: 0.73, green: 0.64, blue: 0.98), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Color.black.opacity(0.25), radius: 18, y: 8)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
    }
}

private struct InstallerSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.82))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.09), in: Capsule())
    }
}
