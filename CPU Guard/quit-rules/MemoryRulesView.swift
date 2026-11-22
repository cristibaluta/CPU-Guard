//
//  MemoryRulesView.swift
//  CPU Guard
//

import SwiftUI
import AppKit
internal import UniformTypeIdentifiers

/// Container shown in the rules window.
struct RulesWindowView: View {
    @ObservedObject var quitStore: QuitRulesStore
    @ObservedObject var memoryStore: MemoryRulesStore

    var body: some View {
        TabView {
            QuitRulesView(store: quitStore)
                .tabItem { Text("Quit Together") }
            MemoryRulesView(store: memoryStore)
                .tabItem { Text("Memory Alerts") }
        }
        .padding(8)
        // The tab bar is centered, so the top-left corner is free.
        .overlay(alignment: .topLeading) {
            AppBadgeIcon().padding(.leading, 12).padding(.top, 6)
        }
    }
}

struct MemoryRulesView: View {
    @ObservedObject var store: MemoryRulesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Show a warning when an app (all its processes combined) uses more memory than the limit.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(12)
            List {
                ForEach($store.rules) { $rule in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $rule.isEnabled).labelsHidden()
                        Image(nsImage: appIcon(for: rule.bundleID)).resizable().frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(appName(for: rule.bundleID))
                            Text(rule.bundleID).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("Limit")
                        TextField("", value: Binding(
                            get: { rule.limitMB / 1024 },
                            set: { rule.limitMB = max(0.1, $0) * 1024 }
                        ), format: .number.precision(.fractionLength(0...2)))
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                        Text("GB")
                        Button { store.rules.removeAll { $0.id == rule.id } } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
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
                .fixedSize()
                Button("Choose app…") { chooseApp() }
                Spacer()
            }
            .padding(8)
        }
        .frame(minWidth: 700, minHeight: 480)
    }

    private func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular
                && $0.bundleIdentifier != nil
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier
            }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func add(_ id: String?) {
        guard let id, !store.rules.contains(where: { $0.bundleID == id }) else { return }
        store.rules.append(MemoryRule(bundleID: id))
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
