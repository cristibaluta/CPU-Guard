//
//  MemoryAlertEngine.swift
//  CPU Guard
//

import SwiftUI
import AppKit
import Combine

struct MemoryAlert: Identifiable {
    let id = UUID()
    let ruleID: UUID
    let bundleID: String
    let name: String
    var usedMB: Double
    let limitMB: Double
}

func formatMemory(_ mb: Double) -> String {
    mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
}

@MainActor
final class MemoryAlertEngine: ObservableObject {
    @Published private(set) var alerts: [MemoryAlert] = [] {
        didSet { updatePanel() }
    }

    private let store: MemoryRulesStore
    /// Given the panel width, returns the left edge and the top edge (screen coordinates) where the panel should appear.
    private let placement: (CGFloat) -> (originX: CGFloat, topY: CGFloat)?
    private var cancellable: AnyCancellable?
    /// Rules currently over their limit; an alert is raised only on the transition.
    private var overLimit = Set<UUID>()
    private var panel: NSPanel?

    private let rowHeight: CGFloat = 52
    private let panelWidth: CGFloat = 430
    private let autoDismiss: TimeInterval = 15

    init(monitor: ProcessMonitor, store: MemoryRulesStore, placement: @escaping (CGFloat) -> (originX: CGFloat, topY: CGFloat)?) {
        self.store = store
        self.placement = placement
        cancellable = monitor.$processes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] processes in
                MainActor.assumeIsolated { self?.evaluate(processes) }
            }
    }

    private func appURL(for bundleID: String) -> URL? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private func evaluate(_ processes: [Process]) {
        let activeIDs = Set(store.rules.map(\.id))
        overLimit = overLimit.intersection(activeIDs)

        for rule in store.rules {
            guard rule.isEnabled, let url = appURL(for: rule.bundleID) else {
                overLimit.remove(rule.id)
                continue
            }
            let prefix = url.path + "/"
            let used = processes
                .filter { $0.executablePath.hasPrefix(prefix) }
                .reduce(0.0) { $0 + $1.memoryMB }

            if used > rule.limitMB {
                if overLimit.insert(rule.id).inserted {
                    let name = appName(for: rule.bundleID)
                    let alert = MemoryAlert(ruleID: rule.id, bundleID: rule.bundleID, name: name,
                                            usedMB: used, limitMB: rule.limitMB)
                    alerts.append(alert)
                    DispatchQueue.main.asyncAfter(deadline: .now() + autoDismiss) { [weak self] in
                        self?.dismiss(alert.id)
                    }
                } else if let i = alerts.firstIndex(where: { $0.ruleID == rule.id }) {
                    alerts[i].usedMB = used
                }
            } else if used < rule.limitMB * 0.9 {
                // Hysteresis so hovering around the limit doesn't re-alert constantly.
                overLimit.remove(rule.id)
            }
        }
        alerts.removeAll { alert in !store.rules.contains { $0.id == alert.ruleID && $0.isEnabled } }
    }

    func dismiss(_ id: UUID) {
        alerts.removeAll { $0.id == id }
    }

    func quit(_ alert: MemoryAlert) {
        NSRunningApplication.runningApplications(withBundleIdentifier: alert.bundleID).forEach { $0.terminate() }
        dismiss(alert.id)
    }

    func restart(_ alert: MemoryAlert) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: alert.bundleID)
        let url = apps.first?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: alert.bundleID)
        apps.forEach { $0.terminate() }
        dismiss(alert.id)
        guard let url else { return }
        // Wait (up to 30 s) for a graceful quit, e.g. while a "save changes?" dialog is open.
        Task { @MainActor in
            for _ in 0..<60 {
                if apps.allSatisfy({ $0.isTerminated }) { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard apps.allSatisfy({ $0.isTerminated }) else { return }
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: - Panel

    /// Re-run placement, e.g. when another window of the app opened or closed.
    func reposition() {
        guard !alerts.isEmpty else { return }
        updatePanel()
    }

    private func updatePanel() {
        guard !alerts.isEmpty else {
            panel?.orderOut(nil)
            return
        }
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: rowHeight),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.level = .statusBar
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentViewController = NSHostingController(rootView: MemoryAlertView(engine: self))
            panel = p
        }
        guard let panel, let screen = NSScreen.main else { return }
        let height = rowHeight * CGFloat(alerts.count)
        let target = placement(panelWidth) ?? (screen.frame.maxX - panelWidth - 16, screen.frame.maxY - 40)
        panel.setFrame(NSRect(x: target.originX, y: target.topY - height, width: panelWidth, height: height), display: true)
        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }
}

struct MemoryAlertView: View {
    @ObservedObject var engine: MemoryAlertEngine

    var body: some View {
        VStack(spacing: 0) {
            ForEach(engine.alerts) { alert in
                HStack(spacing: 8) {
                    // Badge only on the first row; other rows keep the space so they stay aligned.
                    AppBadgeIcon()
                        .opacity(alert.id == engine.alerts.first?.id ? 1 : 0)
                    Image(nsImage: appIcon(for: alert.bundleID))
                        .resizable()
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(alert.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text("\(formatMemory(alert.usedMB)) used · limit \(formatMemory(alert.limitMB))")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    Button("Restart") { engine.restart(alert) }
                        .controlSize(.small)
                    Button("Quit") { engine.quit(alert) }
                        .controlSize(.small)
                    Button { engine.dismiss(alert.id) } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 52)
                if alert.id != engine.alerts.last?.id {
                    Divider()
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
