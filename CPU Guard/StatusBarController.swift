//
//  StatusBarController.swift
//  CPU Guard
//
//  Created by Cristian Baluta on 22.08.2026.
//

import SwiftUI
import AppKit
import ServiceManagement

@MainActor
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
        guard let button = statusItem.button else {
            return
        }
        // 1. Create a configuration with a specific point size and weight
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            // Optional: match menu bar scaling across different screen densities
            .applying(.init(scale: .large))

        // 2. Initialize the image with the configuration
        if let image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "CPU Guard")?
            .withSymbolConfiguration(config) {

            // Ensures macOS properly tints the icon for light/dark menubar modes
            image.isTemplate = true
            button.image = image
        }

        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self
    }

    private func configurePopover() {
        popover.behavior = .applicationDefined
        popover.contentSize = NSSize(width: 800, height: 360)
//        popover.contentViewController = NSHostingController(rootView: ContentView(monitor: monitor))
        popover.contentViewController = NSHostingController(rootView: ProcessMonitorView())
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
        guard let panel = hogPanel else {
            return
        }
        positionHogPanel()
        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    // Coordinate system is from bottom-left
    private func positionHogPanel() {
        guard let panel = hogPanel, let screen = NSScreen.main else {
            return
        }

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
            originX = min(buttonRect.maxX - panelWidth/2, screenFrame.maxX - panelWidth - 8)
        }
        let originY = screenFrame.maxY - menuBarH - panelHeight - 16

        panel.setFrame(NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight), display: true)
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit CPU Guard",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // Reset so left-click still opens the popover
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        if isLaunchAtLoginEnabled {
            try? service.unregister()
        } else {
            try? service.register()
        }
    }

    private var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let button = statusItem.button else {
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
