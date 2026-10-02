import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum PersonalizationSection: String, CaseIterable {
    case dictionary = "Dictionary", snippets = "Snippets", apps = "App styles"
    var detail: String {
        switch self {
        case .dictionary: return "Teach OpenScribe your names, terms, and common corrections."
        case .snippets: return "Say a short phrase to insert a longer piece of text."
        case .apps: return "Choose a different writing tone for the apps you use."
        }
    }
    var addTitle: String {
        switch self {
        case .dictionary: return "Add correction"
        case .snippets: return "Add snippet"
        case .apps: return "Add app style"
        }
    }
}

struct PersonalizationView: View {
    @ObservedObject var controller: AppController
    @State private var section: PersonalizationSection = .dictionary
    @State private var editor: PersonalizationDraft?
    @State private var deleteAction: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                FlowTabs(items: PersonalizationSection.allCases.map { ($0, $0.rawValue) }, selection: $section)
                Text(section.detail).font(.system(size: 13)).foregroundStyle(FlowTheme.inkMuted)
                if section == .dictionary {
                    FlowSettingsGroup(title: "Vocabulary") {
                        FlowSettingsRow(title: "Names & terminology", detail: controller.settings.customVocabulary.isEmpty
                            ? "Add words you want OpenScribe to recognize."
                            : controller.settings.customVocabulary.joined(separator: ", "), symbol: "textformat.abc") {
                            Button(controller.settings.customVocabulary.isEmpty ? "Add words…" : "Edit…") {
                                editor = .init(kind: .vocabulary, replacement: controller.settings.customVocabulary.joined(separator: ", "))
                            }.buttonStyle(.flowSecondary)
                        }
                    }
                }
                HStack {
                    Text(section == .dictionary ? "Corrections" : section.rawValue).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button { editor = .init(kind: section == .dictionary ? .correction : section == .snippets ? .snippet : .appStyle) } label: {
                        Label(section.addTitle, systemImage: "plus")
                    }.buttonStyle(.flowSecondary)
                }
                entries
                Text(section == .dictionary ? "Corrections work even when writing cleanup is off. Vocabulary guides AI cleanup."
                     : section == .snippets ? "A trigger must be the entire dictation. Snippets insert their exact text and skip cleanup."
                     : "App styles apply when writing cleanup is on, using the app where recording starts.")
                    .font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkFaint).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: 760).padding(.horizontal, 32).padding(.vertical, 24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $editor) { draft in
            PersonalizationEditor(controller: controller, initial: draft) { editor = nil }
        }
        .alert("Remove this item?", isPresented: Binding(get: { deleteAction != nil }, set: { if !$0 { deleteAction = nil } })) {
            Button("Remove", role: .destructive) { deleteAction?(); deleteAction = nil; controller.flash("Removed") }
            Button("Cancel", role: .cancel) { deleteAction = nil }
        } message: { Text("Future dictations will use your remaining preferences.") }
    }

    @ViewBuilder private var entries: some View {
        switch section {
        case .dictionary:
            if controller.settings.correctionRules.isEmpty { empty("No corrections yet", symbol: "text.badge.checkmark") }
            else {
                FlowSettingsGroup {
                    ForEach(controller.settings.correctionRules) { rule in
                        HStack(spacing: 12) {
                            Text(rule.heard).font(.system(size: 13)).foregroundStyle(FlowTheme.inkMuted)
                            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(FlowTheme.inkFaint)
                            Text(rule.replacement).font(.system(size: 13, weight: .medium))
                            Spacer()
                            rowActions(edit: { editor = .init(kind: .correction, originalID: rule.id, trigger: rule.heard, replacement: rule.replacement) }, remove: {
                                controller.updateSettings { $0.correctionRules.removeAll { $0.id == rule.id } }
                            })
                        }.padding(16)
                        if rule.id != controller.settings.correctionRules.last?.id { FlowRowDivider() }
                    }
                }
            }
        case .snippets:
            if controller.settings.snippets.isEmpty { empty("No snippets yet", symbol: "text.badge.plus") }
            else {
                FlowSettingsGroup {
                    ForEach(controller.settings.snippets) { snippet in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(snippet.trigger).font(.system(size: 13, weight: .semibold))
                                Text(snippet.replacement).font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted).lineLimit(3)
                            }
                            Spacer()
                            rowActions(edit: { editor = .init(kind: .snippet, originalID: snippet.id, trigger: snippet.trigger, replacement: snippet.replacement) }, remove: {
                                controller.updateSettings { $0.snippets.removeAll { $0.id == snippet.id } }
                            })
                        }.padding(16)
                        if snippet.id != controller.settings.snippets.last?.id { FlowRowDivider() }
                    }
                }
            }
        case .apps:
            let apps = controller.settings.appWritingTones.keys.sorted()
            if apps.isEmpty { empty("No app styles yet", symbol: "app.badge") }
            else {
                FlowSettingsGroup {
                    ForEach(apps, id: \.self) { identifier in
                        HStack(spacing: 12) {
                            AppStyleIcon(identifier: identifier)
                            Text(appName(identifier)).font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text(controller.settings.appWritingTones[identifier]?.title ?? "").font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
                            rowActions(edit: { editor = .init(kind: .appStyle, originalBundle: identifier, trigger: identifier, tone: controller.settings.appWritingTones[identifier] ?? .natural) }, remove: {
                                controller.updateSettings { $0.appWritingTones.removeValue(forKey: identifier) }
                            })
                        }.padding(16)
                        if identifier != apps.last { FlowRowDivider() }
                    }
                }
            }
        }
    }
    private func empty(_ title: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 24, weight: .light)).foregroundStyle(FlowTheme.inkFaint)
            Text(title).font(.system(size: 13)).foregroundStyle(FlowTheme.inkMuted)
            Button(section.addTitle) { editor = .init(kind: section == .dictionary ? .correction : section == .snippets ? .snippet : .appStyle) }
                .buttonStyle(.flowGhost)
        }.frame(maxWidth: .infinity).padding(.vertical, 34)
            .background(FlowTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(FlowTheme.line, lineWidth: 1))
    }
    private func rowActions(edit: @escaping () -> Void, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 3) {
            FlowIconButton(symbol: "pencil", help: "Edit item", size: 26, action: edit)
            FlowIconButton(symbol: "trash", help: "Remove item", size: 26) { deleteAction = remove }
        }
    }
}

private struct PersonalizationDraft: Identifiable {
    enum Kind { case correction, snippet, appStyle, vocabulary }
    var id = UUID()
    var kind: Kind
    var originalID: UUID?
    var originalBundle: String?
    var trigger = ""
    var replacement = ""
    var tone: WritingTone = .natural
    var title: String {
        switch kind {
        case .correction: return originalID == nil ? "Add correction" : "Edit correction"
        case .snippet: return originalID == nil ? "Add snippet" : "Edit snippet"
        case .appStyle: return originalBundle == nil ? "Add app style" : "Edit app style"
        case .vocabulary: return "Your vocabulary"
        }
    }
}

private struct PersonalizationEditor: View {
    @ObservedObject var controller: AppController
    let onClose: () -> Void
    @State private var draft: PersonalizationDraft
    @State private var failure: String?

    init(controller: AppController, initial: PersonalizationDraft, onClose: @escaping () -> Void) {
        self.controller = controller; self.onClose = onClose; _draft = State(initialValue: initial)
    }
    private var canSave: Bool {
        switch draft.kind {
        case .vocabulary: return true
        case .appStyle: return !draft.trigger.isEmpty
        default: return !draft.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draft.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(draft.title).font(.system(size: 22, weight: .semibold)).tracking(-0.4)
            switch draft.kind {
            case .correction:
                field("Usually transcribed as", placeholder: "Word or phrase", value: $draft.trigger)
                field("Replace with", placeholder: "Correct spelling", value: $draft.replacement)
            case .snippet:
                field("When I say", placeholder: "e.g. my signature", value: $draft.trigger)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Insert this text").font(.system(size: 12, weight: .medium))
                    TextField("Your snippet", text: $draft.replacement, axis: .vertical).lineLimit(5...9).flowField()
                }
            case .appStyle:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Application").font(.system(size: 12, weight: .medium))
                    HStack(spacing: 10) {
                        if !draft.trigger.isEmpty { AppStyleIcon(identifier: draft.trigger) }
                        Text(draft.trigger.isEmpty ? "Choose an app" : appName(draft.trigger)).font(.system(size: 13))
                            .foregroundStyle(draft.trigger.isEmpty ? FlowTheme.inkFaint : FlowTheme.ink)
                        Spacer()
                        Button(draft.trigger.isEmpty ? "Choose…" : "Change…") { chooseApp() }.buttonStyle(.flowSecondary)
                    }.padding(12).background(FlowTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(FlowTheme.line, lineWidth: 1))
                }
                fieldTone
            case .vocabulary:
                Text("Separate names and terms with commas. These words guide writing cleanup.").font(.system(size: 13)).foregroundStyle(FlowTheme.inkMuted)
                TextField("e.g. OpenScribe, Shashank", text: $draft.replacement, axis: .vertical).lineLimit(4...8).flowField()
            }
            if let failure { Text(failure).font(.system(size: 12)).foregroundStyle(FlowTheme.warning) }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: onClose).buttonStyle(.flowSecondary).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.buttonStyle(.flowPrimary).disabled(!canSave).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 450).background(FlowTheme.background).foregroundStyle(FlowTheme.ink)
    }
    private var fieldTone: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Writing tone").font(.system(size: 12, weight: .medium))
            Picker("Writing tone", selection: $draft.tone) { ForEach(WritingTone.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
        }
    }
    private func field(_ title: String, placeholder: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium))
            TextField(placeholder, text: value).flowField()
        }
    }
    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.applicationBundle]
        if panel.runModal() == .OK, let url = panel.url, let identifier = Bundle(url: url)?.bundleIdentifier { draft.trigger = identifier }
    }
    private func save() {
        let trigger = draft.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = draft.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.kind == .snippet, VoiceSnippet.expansion(for: trigger, snippets: controller.settings.snippets.filter { $0.id != draft.originalID }) != nil {
            failure = "A snippet already uses that trigger."; return
        }
        let saved = controller.updateSettings { settings in
            switch draft.kind {
            case .correction:
                settings.correctionRules.removeAll { $0.id == draft.originalID || $0.heard.caseInsensitiveCompare(trigger) == .orderedSame }
                var rule = CorrectionRule(heard: trigger, replacement: replacement)
                if let id = draft.originalID { rule.id = id }
                settings.correctionRules.append(rule)
            case .snippet:
                settings.snippets.removeAll { $0.id == draft.originalID }
                var snippet = VoiceSnippet(trigger: trigger, replacement: replacement)
                if let id = draft.originalID { snippet.id = id }
                settings.snippets.append(snippet)
            case .appStyle:
                if let original = draft.originalBundle { settings.appWritingTones.removeValue(forKey: original) }
                settings.appWritingTones[trigger] = draft.tone
            case .vocabulary:
                var seen = Set<String>()
                settings.customVocabulary = replacement.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            }
        }
        guard saved else { failure = "Couldn’t save your changes. Check local storage and try again."; return }
        controller.flash("Saved"); onClose()
    }
}

private func appName(_ identifier: String) -> String {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)?.deletingPathExtension().lastPathComponent ?? identifier
}
private struct AppStyleIcon: View {
    let identifier: String
    var body: some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else { Image(systemName: "app").resizable().foregroundStyle(FlowTheme.inkMuted) }
        }.frame(width: 28, height: 28)
    }
}
