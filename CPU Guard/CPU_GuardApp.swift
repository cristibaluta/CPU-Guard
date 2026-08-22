//
//  CPU_GuardApp.swift
//  CPU Guard
//
//  Created by Cristian Baluta on 08/05/2026.
//

import SwiftUI
import AppKit

final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let monitor = ProcessMonitor()

    override init() {
        super.init()
        monitor.start()
        configureStatusItem()
        configurePopover()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "CPU Guard")
        button.action = #selector(togglePopover(_:))
        button.target = self
    }

    private func configurePopover() {
        popover.behavior = .applicationDefined
        popover.contentSize = NSSize(width: 800, height: 360)
        popover.contentViewController = NSHostingController(rootView: ContentView(monitor: monitor))
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }

        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as a menu bar utility without a Dock icon.
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController()
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
