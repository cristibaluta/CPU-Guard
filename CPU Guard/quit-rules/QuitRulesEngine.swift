//
//  QuitRulesEngine.swift
//  CPU Guard
//

import AppKit

@MainActor
final class QuitRulesEngine {
    private let store: QuitRulesStore
    private var rules: [QuitRule] { store.rules.filter { $0.isEnabled } }
    private var observers: [NSObjectProtocol] = []
    private var isPoweringOff = false
    /// Apps terminated by us; their termination must not trigger rules.
    private var quitByUs = Set<String>()

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
        for id in rule.linked {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
                quitByUs.insert(id)
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
