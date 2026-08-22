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
    private var hogPanel: NSPanel?

    override init() {
        super.init()
        monitor.start()
        configureStatusItem()
        configurePopover()
        setupHogPanel()
        monitor.onNewHogDetected = { [weak self] in
            self?.showHogPanel()
        }
        monitor.onResourceHogsCleared = { [weak self] in
            self?.hogPanel?.orderOut(nil)
        }
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

    private func setupHogPanel() {
        let view = HogAlertView(monitor: monitor) { [weak self] in
            self?.hogPanel?.orderOut(nil)
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(rootView: view)
        hogPanel = panel
    }

    private func showHogPanel() {
        guard let panel = hogPanel else { return }
        positionHogPanel()
        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    private func positionHogPanel() {
        guard let panel = hogPanel, let screen = NSScreen.main else { return }

        let hogCount = max(monitor.resourceHogs.count, 1)
        let headerH: CGFloat = 36    // alert header bar
        let rowH: CGFloat = 48       // each process row (padding + content + divider)
        let panelHeight = min(headerH + rowH * CGFloat(hogCount) + 1, 380)
        let panelWidth: CGFloat = 620

        // Position just below the menu bar, horizontally near the status item.
        let menuBarH = NSStatusBar.system.thickness
        let screenFrame = screen.frame

        var originX = screenFrame.maxX - panelWidth - 16
        if let button = statusItem.button, let buttonWindow = button.window {
            let buttonRect = buttonWindow.convertToScreen(button.frame)
            originX = min(buttonRect.maxX - panelWidth, screenFrame.maxX - panelWidth - 8)
        }
        let originY = screenFrame.maxY - menuBarH - panelHeight

        panel.setFrame(NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight), display: true)
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
