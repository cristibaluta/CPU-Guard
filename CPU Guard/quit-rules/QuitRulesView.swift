//
//  QuitRulesView.swift
//  CPU Guard
//

import SwiftUI
import AppKit
internal import UniformTypeIdentifiers

private func appName(for bundleID: String) -> String {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
    return bundleID
}

private func appIcon(for bundleID: String) -> NSImage {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        return NSWorkspace.shared.icon(forFile: url.path)
    }
    return NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: nil) ?? NSImage()
}

struct QuitRulesView: View {
    @ObservedObject var store: QuitRulesStore
    @State private var selection: UUID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.rules) { rule in
                        HStack {
                            Image(systemName: rule.isEnabled ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(rule.isEnabled ? .green : .secondary)
                            Text(rule.name.isEmpty ? "Untitled" : rule.name)
                        }
                        .tag(rule.id)
                    }
                }
                HStack {
                    Button {
                        let rule = QuitRule(name: "New rule", triggers: [], linked: [])
                        store.rules.append(rule)
                        selection = rule.id
                    } label: { Image(systemName: "plus") }
                    Button {
                        if let id = selection {
                            store.rules.removeAll { $0.id == id }
                            selection = store.rules.first?.id
                        }
                    } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    Spacer()
                }
                .padding(8)
            }
            .frame(minWidth: 200, idealWidth: 220, maxWidth: 280)

            Group {
                if let index = store.rules.firstIndex(where: { $0.id == selection }) {
                    RuleEditor(rule: $store.rules[index])
                } else {
                    Text("Select or add a rule").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 400)
        }
        .frame(minWidth: 700, minHeight: 480)
        .onAppear { selection = selection ?? store.rules.first?.id }
    }
}

private struct RuleEditor: View {
    @Binding var rule: QuitRule

    var body: some View {
        Form {
            TextField("Name", text: $rule.name)
            Toggle("Enabled", isOn: $rule.isEnabled)
            Stepper("Delay: \(Int(rule.delay)) s", value: $rule.delay, in: 0...60)
            Toggle("Force quit if still running", isOn: Binding(
                get: { rule.forceQuitAfter != nil },
                set: { rule.forceQuitAfter = $0 ? 10 : nil }
            ))
            if let timeout = rule.forceQuitAfter {
                Stepper("Force quit after: \(Int(timeout)) s", value: Binding(
                    get: { timeout },
                    set: { rule.forceQuitAfter = $0 }
                ), in: 1...120)
            }
            AppListSection(title: "When any of these quits…", ids: $rule.triggers)
            AppListSection(title: "…also quit these", ids: $rule.linked)
        }
        .formStyle(.grouped)
    }
}

private struct AppListSection: View {
    let title: String
    @Binding var ids: [String]

    var body: some View {
        Section(title) {
            ForEach(ids, id: \.self) { id in
                HStack {
                    Image(nsImage: appIcon(for: id)).resizable().frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(appName(for: id))
                        Text(id).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { ids.removeAll { $0 == id } } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                Menu("Add running app") {
                    ForEach(runningApps(), id: \.bundleIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                            add(app.bundleIdentifier)
                        }
                    }
                }
                Button("Choose app…") { chooseApp() }
            }
        }
    }

    private func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func add(_ id: String?) {
        if let id, !ids.contains(id) { ids.append(id) }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK {
            for url in panel.urls { add(Bundle(url: url)?.bundleIdentifier) }
        }
    }
}
