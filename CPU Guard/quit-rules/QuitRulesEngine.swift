//
//  QuitRulesEngine.swift
//  CPU Guard
//

import AppKit
import SwiftUI
import Combine

@MainActor
final class QuitRulesEngine {
    private let store: QuitRulesStore
    private var rules: [QuitRule] { store.rules.filter { $0.isEnabled } }
    private var observers: [NSObjectProtocol] = []
    private var isPoweringOff = false
    /// Apps terminated by us; their termination must not trigger rules.
    private var quitByUs = Set<String>()
    private let report = QuitReportController()

    init(store: QuitRulesStore = .shared) {
        self.store = store
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier else { return }
            MainActor.assumeIsolated { self?.handleTermination(of: id) }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPoweringOff = true }
        })
    }

    private func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private func handleTermination(of bundleID: String) {
        if quitByUs.remove(bundleID) != nil || isPoweringOff {
            return
        }
        for rule in rules where rule.triggers.contains(bundleID) {
            DispatchQueue.main.asyncAfter(deadline: .now() + rule.delay) { [weak self] in
                self?.apply(rule)
            }
        }
    }

    private func apply(_ rule: QuitRule) {
        guard !isPoweringOff else { return }
        // Keep linked apps alive while any other trigger app is still open.
        if rule.triggers.contains(where: isRunning) {
            return
        }
        var killed: [QuitReportEntry] = []
        defer { if !killed.isEmpty { report.add(killed) } }
        for id in rule.linked {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
                quitByUs.insert(id)
                if !killed.contains(where: { $0.bundleID == id }) {
                    killed.append(QuitReportEntry(bundleID: id, name: app.localizedName ?? id,
                                                  ruleName: rule.name, date: Date()))
                }
                app.terminate()
                if let timeout = rule.forceQuitAfter {
                    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                        if !app.isTerminated { app.forceTerminate() }
                    }
                }
            }
        }
    }
}

struct QuitReportEntry: Identifiable {
    let id = UUID()
    let bundleID: String
    let name: String
    let ruleName: String
    let date: Date
}

@MainActor
final class QuitReportModel: ObservableObject {
    @Published var entries: [QuitReportEntry] = []
}

/// Window listing apps closed by quit rules; stays open until the user closes it.
@MainActor
final class QuitReportController {
    private let model = QuitReportModel()
    private var window: NSWindow?

    func add(_ new: [QuitReportEntry]) {
        model.entries.insert(contentsOf: new, at: 0)
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Apps Closed by Quit Rules"
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.contentViewController = NSHostingController(rootView: QuitReportView(model: model, onClear: { [weak self] in
                self?.model.entries.removeAll()
            }))
            w.center()
            window = w
        }
        if window?.isVisible != true {
            // Fresh session: only show the newly closed apps.
            model.entries = new
        }
        window?.orderFrontRegardless()
    }
}

struct QuitReportView: View {
    @ObservedObject var model: QuitReportModel
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(model.entries) { entry in
                HStack(spacing: 8) {
                    // Badge only on the first row; other rows keep the space so they stay aligned.
                    AppBadgeIcon()
                        .opacity(entry.id == model.entries.first?.id ? 1 : 0)
                    Image(nsImage: appIcon(for: entry.bundleID))
                        .resizable()
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name).font(.system(size: 12, weight: .semibold))
                        Text("Rule: \(entry.ruleName)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(entry.date, style: .time)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Clear", action: onClear).controlSize(.small)
            }
            .padding(8)
        }
        .frame(minWidth: 360, minHeight: 200)
    }
}
