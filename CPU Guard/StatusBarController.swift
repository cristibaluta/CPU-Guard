//
//  StatusBarController.swift
//  CPU Guard
//
//  Created by Cristian Baluta on 22.08.2026.
//

import SwiftUI
import AppKit
import ServiceManagement
import Combine

@MainActor
final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let daemonManager = DaemonManager()
    private let monitor: ProcessMonitor
    private let powerMonitor: PowerMonitor
    private var hogPanel: NSPanel?
    private let rulesStore = QuitRulesStore.shared
    private let memoryStore = MemoryRulesStore.shared
    private var memoryEngine: MemoryAlertEngine?
    private var rulesWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private let stats = SystemStatsMonitor()
    private var isAlert = false

    override init() {
        monitor = ProcessMonitor(daemonManager: daemonManager)
        powerMonitor = PowerMonitor()
        super.init()
        memoryEngine = MemoryAlertEngine(monitor: monitor, store: memoryStore) { [weak self] in
            self?.memoryPanelPlacement()
        }
        monitor.start()
        powerMonitor.start()
        configureStatusItem()
        stats.start()
        Publishers.CombineLatest4(stats.$cpuUser, stats.$cpuSystem, stats.$memUsed, stats.$memTotal)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in self?.setStatusIcon(alert: self?.isAlert ?? false) }
            .store(in: &cancellables)
        configurePopover()
        setupHogPanel()
        monitor.onNewHogDetected = { [weak self] in
            self?.showHogPanel()
        }
        monitor.onResourceHogsCleared = { [weak self] in
            self?.hogPanel?.orderOut(nil)
        }
        if let memoryEngine {
            Publishers.CombineLatest(monitor.$resourceHogs, memoryEngine.$alerts)
                .map { hogs, memAlerts in !hogs.isEmpty || !memAlerts.isEmpty }
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isAlert in self?.setStatusIcon(alert: isAlert) }
                .store(in: &cancellables)
        }
    }

    private func setStatusIcon(alert: Bool) {
        isAlert = alert
        guard let button = statusItem.button,
              let icon = NSImage(named: alert ? "MenuBarIconAlert" : "MenuBarIcon") else { return }

        let memPercent = stats.memTotal > 0 ? stats.memUsed / stats.memTotal * 100 : 0
        let lines = [String(format: "CPU %.0f%%", stats.cpuTotal), String(format: "MEM %.0f%%", memPercent)]
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let sizes = lines.map { ($0 as NSString).size(withAttributes: attributes) }
        let textWidth = ceil(sizes.map(\.width).max() ?? 0)
        let iconSize: CGFloat = 18
        let height: CGFloat = 22
        let gap: CGFloat = 4
        let blockHeight = sizes.map(\.height).reduce(0, +)

        // Draw text + icon into a single template image so everything is vertically centered
        // and tinted correctly for light/dark menu bars.
        let image = NSImage(size: NSSize(width: textWidth + gap + iconSize, height: height), flipped: false) { _ in
            var y = (height + blockHeight) / 2
            for (line, size) in zip(lines, sizes) {
                y -= size.height
                (line as NSString).draw(at: NSPoint(x: textWidth - size.width, y: y), withAttributes: attributes)
            }
            icon.draw(in: NSRect(x: textWidth + gap, y: (height - iconSize) / 2, width: iconSize, height: iconSize))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "CPU Guard"
        button.imagePosition = .imageOnly
        button.image = image
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
        setStatusIcon(alert: false)

        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self
    }

    private func configurePopover() {
        popover.behavior = .applicationDefined
        popover.contentSize = NSSize(width: 800, height: 500)
//        popover.contentViewController = NSHostingController(rootView: ContentView(monitor: monitor))
        popover.contentViewController = NSHostingController(rootView: ProcessMonitorView(monitor: monitor, daemonManager: daemonManager))
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

    /// Where the memory warning tooltip goes: under the status item, below the hog panel if it is showing.
    private func memoryPanelPlacement() -> (midX: CGFloat, topY: CGFloat)? {
        guard let screen = NSScreen.main else {
            return nil
        }
        // Default: top-right corner. The status item's window may not be positioned yet right
        // after launch (frame near the origin), so only trust it once it is on screen.
        var midX = screen.frame.maxX - 200
        if let button = statusItem.button, let window = button.window {
            let frame = window.convertToScreen(button.frame)
            if frame.width > 0, frame.midX > screen.frame.minX + 100, screen.frame.intersects(frame) {
                midX = frame.midX
            }
        }
        var topY = screen.frame.maxY - NSStatusBar.system.thickness - 16
        if let hog = hogPanel, hog.isVisible {
            topY = hog.frame.minY - 8
        }
        return (midX, topY)
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

        daemonManager.updateStatus()
        let helperItem = NSMenuItem(
            title: "Helper Registered",
            action: #selector(toggleHelper),
            keyEquivalent: ""
        )
        helperItem.target = self
        helperItem.state = daemonManager.isRegistered ? .on : .off
        menu.addItem(helperItem)

        menu.addItem(.separator())

        let rulesItem = NSMenuItem(title: "Quit Rules", action: nil, keyEquivalent: "")
        let rulesMenu = NSMenu()
        for rule in rulesStore.rules {
            let item = NSMenuItem(
                title: "\(rule.name) (\(rule.triggers.count) → \(rule.linked.count))",
                action: #selector(toggleRule(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = rule.id
            item.state = rule.isEnabled ? .on : .off
            rulesMenu.addItem(item)
        }
        if !rulesStore.rules.isEmpty {
            rulesMenu.addItem(.separator())
        }
        let editItem = NSMenuItem(title: "Edit Rules…", action: #selector(showRulesEditor), keyEquivalent: "")
        editItem.target = self
        rulesMenu.addItem(editItem)
        rulesItem.submenu = rulesMenu
        menu.addItem(rulesItem)

        let memoryItem = NSMenuItem(title: "Memory Alerts", action: nil, keyEquivalent: "")
        let memoryMenu = NSMenu()
        for rule in memoryStore.rules {
            let item = NSMenuItem(
                title: "\(appName(for: rule.bundleID)) > \(formatMemory(rule.limitMB))",
                action: #selector(toggleMemoryRule(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = rule.id
            item.state = rule.isEnabled ? .on : .off
            memoryMenu.addItem(item)
        }
        if !memoryStore.rules.isEmpty {
            memoryMenu.addItem(.separator())
        }
        let editMemoryItem = NSMenuItem(title: "Edit Rules…", action: #selector(showRulesEditor), keyEquivalent: "")
        editMemoryItem.target = self
        memoryMenu.addItem(editMemoryItem)
        memoryItem.submenu = memoryMenu
        menu.addItem(memoryItem)

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

    @objc private func toggleHelper() {
        if daemonManager.isRegistered {
            daemonManager.unregisterDaemon()
        } else {
            daemonManager.registerDaemon()
        }
    }

    @objc private func toggleRule(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let index = rulesStore.rules.firstIndex(where: { $0.id == id }) else {
            return
        }
        rulesStore.rules[index].isEnabled.toggle()
    }

    @objc private func toggleMemoryRule(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let index = memoryStore.rules.firstIndex(where: { $0.id == id }) else {
            return
        }
        memoryStore.rules[index].isEnabled.toggle()
    }

    @objc private func showRulesEditor() {
        if rulesWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "CPU Guard Rules"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: RulesWindowView(quitStore: rulesStore, memoryStore: memoryStore)
            )
            window.center()
            rulesWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        rulesWindow?.makeKeyAndOrderFront(nil)
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
