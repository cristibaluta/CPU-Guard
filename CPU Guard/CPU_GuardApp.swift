//
//  CPU_GuardApp.swift
//  CPU Guard
//
//  Created by Cristian Baluta on 08/05/2026.
//

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var quitRulesEngine: QuitRulesEngine?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as a menu bar utility without a Dock icon.
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController()
        quitRulesEngine = QuitRulesEngine()
        quitRulesEngine?.start()
    }
}

@main
struct CPU_GuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
