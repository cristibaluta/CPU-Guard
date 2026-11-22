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
final class StatusBarController: NSObject, NSPopoverDelegate {
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
    private var aboutWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private let stats = SystemStatsMonitor()
    private var isAlert = false
    private var displayMode = StatusDisplayMode.load()
    // 2 s samples, 3 per candle (6 s), 20 candles = 2 minutes of history.
    private var cpuSeries = CandleSeries(samplesPerCandle: 3, maxCandles: 20)
    private var memSeries = CandleSeries(samplesPerCandle: 3, maxCandles: 20)
    private var sampleTimer: Timer?

    override init() {
        monitor = ProcessMonitor(daemonManager: daemonManager)
        powerMonitor = PowerMonitor()
        super.init()
        memoryEngine = MemoryAlertEngine(monitor: monitor, store: memoryStore) { [weak self] width in
            self?.memoryPanelPlacement(width: width)
        }
        monitor.start()
        powerMonitor.start()
        configureStatusItem()
        stats.start()
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordSample()
            }
        }
        Publishers.CombineLatest4(stats.$cpuUser, stats.$cpuSystem, stats.$memUsed, stats.$swapUsed)
            .combineLatest(stats.$pressure)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.setStatusIcon(alert: self?.isAlert ?? false) }
            .store(in: &cancellables)
        configurePopover()
        setupHogPanel()
        monitor.onNewHogDetected = { [weak self] in
            self?.showHogPanel()
        }
        monitor.onResourceHogsCleared = { [weak self] in
            self?.hogPanel?.orderOut(nil)
            self?.memoryEngine?.reposition()
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

    private func recordSample() {
        cpuSeries.add(stats.cpuTotal)
        memSeries.add(stats.memTotal > 0 ? stats.memUsed / stats.memTotal * 100 : 0)
        if displayMode == .charts {
            setStatusIcon(alert: isAlert)
        }
    }

    private func setStatusIcon(alert: Bool) {
        isAlert = alert
        guard let button = statusItem.button,
              let icon = NSImage(named: alert ? "MenuBarIconAlert" : "MenuBarIcon") else { return }

        let gb = 1_073_741_824.0
        let underPressure = stats.pressure != .normal
        // Not a template image (the swap value needs a color), so pick the menu bar foreground ourselves.
        let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let baseColor: NSColor = isDark ? .white : .black
        let swapColor: NSColor = underPressure ? .systemOrange : baseColor

        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        func attrs(_ color: NSColor) -> [NSAttributedString.Key: Any] {
            [.font: font, .foregroundColor: color]
        }

        var lines: [NSAttributedString] = []
        if displayMode == .values {
            let cpuLine = NSMutableAttributedString(string: String(format: "CPU %.0f%%", stats.cpuTotal), attributes: attrs(baseColor))
            let memLine = NSMutableAttributedString(string: String(format: "%.1f GB | ", stats.memUsed / gb), attributes: attrs(baseColor))
            memLine.append(NSAttributedString(string: String(format: "%.1f GB", stats.swapUsed / gb), attributes: attrs(swapColor)))
            lines = [cpuLine, memLine]
        }

        let sizes = lines.map { $0.size() }
        let iconSize: CGFloat = 18
        let height: CGFloat = 22
        let gap: CGFloat = 4
        let chartHeight: CGFloat = 18
        let chartWidth = chartHeight * 2
        let blockHeight = sizes.map(\.height).reduce(0, +)

        let showCharts = displayMode == .charts
        let textWidth = ceil(sizes.map(\.width).max() ?? 0)
        let leadingWidth: CGFloat = showCharts ? chartWidth * 2 + gap : textWidth
        let iconX = leadingWidth > 0 ? leadingWidth + gap : 0
        let cpuSeries = self.cpuSeries
        let memSeries = self.memSeries

        // Everything is drawn into one image so it is vertically centered.
        let image = NSImage(size: NSSize(width: iconX + iconSize, height: height), flipped: false) { _ in
            if showCharts {
                let y = (height - chartHeight) / 2
                CandleChart.draw(cpuSeries, in: NSRect(x: 0, y: y, width: chartWidth, height: chartHeight),
                                 color: baseColor, highThreshold: 80)
                CandleChart.draw(memSeries, in: NSRect(x: chartWidth + gap, y: y, width: chartWidth, height: chartHeight),
                                 color: baseColor, highThreshold: 90)
            } else {
                var y = (height + blockHeight) / 2
                for (line, size) in zip(lines, sizes) {
                    y -= size.height
                    line.draw(at: NSPoint(x: textWidth - size.width, y: y))
                }
            }
            let iconRect = NSRect(x: iconX, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
            icon.draw(in: iconRect)
            baseColor.set()
            iconRect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
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
        popover.delegate = self
        popover.contentSize = NSSize(width: 800, height: 500)
//        popover.contentViewController = NSHostingController(rootView: ContentView(monitor: monitor))
        popover.contentViewController = NSHostingController(rootView: ProcessMonitorView(
            monitor: monitor,
            daemonManager: daemonManager,
            onIconClick: { [weak self] in self?.showContextMenuFromPopover() }
        ))
    }

    private func setupHogPanel() {
        let view = HogAlertView(monitor: monitor) { [weak self] in
            self?.hogPanel?.orderOut(nil)
            self?.memoryEngine?.reposition()
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
        memoryEngine?.reposition()
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

        // Stack below the popover when it is open, otherwise just below the status item.
        let origin = stackOrigin(width: panelWidth, below: [popoverWindow]) ?? (screen.frame.maxX - panelWidth - 16, screen.frame.maxY - 40)
        let originX = origin.x
        let originY = origin.topY - panelHeight

        panel.setFrame(NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight), display: true)
    }

    private var popoverWindow: NSWindow? {
        popover.isShown ? popover.contentViewController?.view.window : nil
    }

    /// Where the memory warning goes: stacked below the popover and hog panel when they are open.
    private func memoryPanelPlacement(width: CGFloat) -> (originX: CGFloat, topY: CGFloat)? {
        guard let origin = stackOrigin(width: width, below: [popoverWindow, hogPanel]) else {
            return nil
        }
        return (origin.x, origin.topY)
    }

    /// Windows are stacked vertically and right-aligned to the first open one.
    /// With none open, the result is centered under the status item.
    private func stackOrigin(width: CGFloat, below windows: [NSWindow?]) -> (x: CGFloat, topY: CGFloat)? {
        guard let screen = NSScreen.main else {
            return nil
        }
        let frames = windows.compactMap { $0 }.filter { $0.isVisible }.map(\.frame)
        let x: CGFloat
        let topY: CGFloat
        if let first = frames.first {
            x = first.maxX - width
            topY = (frames.map(\.minY).min() ?? first.minY) - 8
        } else {
            // The status item's window may not be positioned yet right after launch (frame near
            // the origin), so only trust it once it is on screen.
            var midX = screen.frame.maxX - 200
            if let button = statusItem.button, let window = button.window {
                let frame = window.convertToScreen(button.frame)
                if frame.width > 0, frame.midX > screen.frame.minX + 100, screen.frame.intersects(frame) {
                    midX = frame.midX
                }
            }
            x = midX - width / 2
            topY = screen.frame.maxY - NSStatusBar.system.thickness - 16
        }
        return (max(screen.frame.minX + 8, min(x, screen.frame.maxX - width - 8)), topY)
    }

    private func repositionPanels() {
        if let hog = hogPanel, hog.isVisible {
            positionHogPanel()
        }
        memoryEngine?.reposition()
    }

    func popoverDidClose(_ notification: Notification) {
        repositionPanels()
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
        statusItem.menu = makeContextMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // Reset so left-click still opens the popover
    }

    /// Shared by the status item's right-click and the icon in the popover header.
    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()

        let aboutItem = NSMenuItem(title: "About CPU Guard", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(.separator())

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

        let displayItem = NSMenuItem(title: "Status Bar Display", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        for mode in StatusDisplayMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectDisplayMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == displayMode ? .on : .off
            displayMenu.addItem(item)
        }
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

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

        return menu
    }

    private func showContextMenuFromPopover() {
        guard let window = popover.contentViewController?.view.window,
              let view = window.contentView,
              let event = NSApp.currentEvent else {
            return
        }
        NSMenu.popUpContextMenu(makeContextMenu(), with: event, for: view)
    }

    @objc private func showAbout() {
        if aboutWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 240),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "About CPU Guard"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: AboutView())
            window.center()
            aboutWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func selectDisplayMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = StatusDisplayMode(rawValue: raw) else {
            return
        }
        displayMode = mode
        mode.save()
        setStatusIcon(alert: isAlert)
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
        repositionPanels()
    }
}
