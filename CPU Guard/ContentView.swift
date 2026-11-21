//
//  ContentView.swift
//  CPU Guard
//
//  Created by Cristian Baluta on 08/05/2026.
//

import SwiftUI
import AppKit

/// Fine dotted baseline for the not-yet-recorded part of a chart window.
private func emptyBaseline(width: CGFloat, height: CGFloat, emptyWidth: CGFloat) -> some View {
    Path { path in
        path.move(to: CGPoint(x: 0, y: height))
        path.addLine(to: CGPoint(x: emptyWidth, y: height))
    }
    .stroke(Color.gray.opacity(0.7), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [0.1, 4]))
}

/// Marker + value label for the sample under the mouse.
private struct ChartHoverOverlay: View {
    let point: CGPoint
    let label: String
    let width: CGFloat
    let color: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: point.x, y: 0))
                path.addLine(to: CGPoint(x: point.x, y: 24))
            }
            .stroke(Color.secondary.opacity(0.5), lineWidth: 0.5)

            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .position(point)

            Text(label)
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
                .padding(.horizontal, 3)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.9))
                .cornerRadius(3)
                .fixedSize()
                .position(x: min(max(point.x, 26), width - 26), y: point.y < 12 ? 17 : 6)
        }
        .allowsHitTesting(false)
    }
}

struct CPUSparklineView: View {
    let values: [Double]
    var capacity: Int = HistoryConfig.cpuSamples
    @State private var hoverX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let points = Array(values.suffix(capacity))
            let width = geo.size.width
            let height = geo.size.height
            // The chart always spans the full window; new samples enter at the right edge
            // and the not-yet-filled part on the left stays empty.
            let stepX = width / CGFloat(max(capacity - 1, 1))
            let startX = CGFloat(capacity - points.count) * stepX
            let yFor: (Double) -> CGFloat = { value in
                height - (CGFloat(max(0, min(value, 100))) / 100.0 * height)
            }

            emptyBaseline(width: width, height: height, emptyWidth: min(startX, width))

            Path { path in
                guard let first = points.first else { return }

                path.move(to: CGPoint(x: startX, y: yFor(first)))
                if points.count == 1 {
                    path.addLine(to: CGPoint(x: startX + 1, y: yFor(first)))
                }

                for (index, value) in points.dropFirst().enumerated() {
                    path.addLine(to: CGPoint(x: startX + CGFloat(index + 1) * stepX, y: yFor(value)))
                }
            }
            .stroke(Color.accentColor, lineWidth: 1.5)

            if let hoverX, !points.isEmpty {
                let index = min(max(Int(((hoverX - startX) / stepX).rounded()), 0), points.count - 1)
                let point = CGPoint(x: startX + CGFloat(index) * stepX, y: yFor(points[index]))
                ChartHoverOverlay(point: point, label: String(format: "%.1f%%", points[index]),
                                  width: width, color: .accentColor)
            }
        }
        .frame(height: 24)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): hoverX = location.x
            case .ended: hoverX = nil
            }
        }
    }
}

struct MemorySparklineView: View {
    let values: [Double]
    var capacity: Int = HistoryConfig.memorySamples
    @State private var hoverX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let points = Array(values.suffix(capacity))
            let width = geo.size.width
            let height = geo.size.height
            let stepX = width / CGFloat(max(capacity - 1, 1))
            let startX = CGFloat(capacity - points.count) * stepX
            let maxMemory = points.max() ?? 100.0
            let minMemory = points.min() ?? 0.0
            let range = max(maxMemory - minMemory, 1.0)
            let yFor: (Double) -> CGFloat = { value in
                height - ((CGFloat(value) - CGFloat(minMemory)) / CGFloat(range) * height)
            }

            emptyBaseline(width: width, height: height, emptyWidth: min(startX, width))

            if !points.isEmpty {
                Path { path in
                    if let first = points.first {
                        path.move(to: CGPoint(x: startX, y: yFor(first)))
                        if points.count == 1 {
                            path.addLine(to: CGPoint(x: startX + 1, y: yFor(first)))
                        }

                        for (index, value) in points.dropFirst().enumerated() {
                            path.addLine(to: CGPoint(x: startX + CGFloat(index + 1) * stepX, y: yFor(value)))
                        }
                    }
                }
                .stroke(Color.blue, lineWidth: 1.5)

                if let hoverX {
                    let index = min(max(Int(((hoverX - startX) / stepX).rounded()), 0), points.count - 1)
                    let point = CGPoint(x: startX + CGFloat(index) * stepX, y: yFor(points[index]))
                    ChartHoverOverlay(point: point, label: String(format: "%.1f MB", points[index]),
                                      width: width, color: .blue)
                }
            }
        }
        .frame(height: 24)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): hoverX = location.x
            case .ended: hoverX = nil
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var monitor: ProcessMonitor
    @State private var userSortOrder: [KeyPathComparator<Process>] = ContentView.loadSortOrder()

    private static let sortKeyDefaultsKey = "processSortKey"
    private static let sortAscendingDefaultsKey = "processSortAscending"

    private static func loadSortOrder() -> [KeyPathComparator<Process>] {
        let defaults = UserDefaults.standard
        guard let key = defaults.string(forKey: sortKeyDefaultsKey) else {
            return []
        }
        let order: SortOrder = defaults.bool(forKey: sortAscendingDefaultsKey) ? .forward : .reverse
        switch key {
        case "name": return [KeyPathComparator(\Process.name, order: order)]
        case "cpu": return [KeyPathComparator(\Process.cpuUsage, order: order)]
        case "memory": return [KeyPathComparator(\Process.memoryMB, order: order)]
        default: return []
        }
    }

    private static func saveSortOrder(_ comparators: [KeyPathComparator<Process>]) {
        let defaults = UserDefaults.standard
        guard let first = comparators.first else {
            defaults.removeObject(forKey: sortKeyDefaultsKey)
            defaults.removeObject(forKey: sortAscendingDefaultsKey)
            return
        }
        let key: String?
        if first.keyPath == \Process.name {
            key = "name"
        } else if first.keyPath == \Process.cpuUsage {
            key = "cpu"
        } else if first.keyPath == \Process.memoryMB {
            key = "memory"
        } else {
            key = nil
        }
        guard let key else { return }
        defaults.set(key, forKey: sortKeyDefaultsKey)
        defaults.set(first.order == .forward, forKey: sortAscendingDefaultsKey)
    }

    private var sortBinding: Binding<[KeyPathComparator<Process>]> {
        Binding(
            get: { userSortOrder },
            set: {
                userSortOrder = $0
                ContentView.saveSortOrder($0)
            }
        )
    }
    @StateObject private var stats = SystemStatsMonitor()

    private var pinnedComparator: KeyPathComparator<Process> {
        KeyPathComparator(\Process.pinSortRank, order: .reverse)
    }

    private var pausedComparator: KeyPathComparator<Process> {
        KeyPathComparator(\Process.pauseSortRank, order: .reverse)
    }

    private var displayedProcesses: [Process] {
        if userSortOrder.isEmpty {
            // Keep original monitor order (CPU-history-based) within each priority bucket.
            let pinned = monitor.filtered.filter { $0.isPinned }
            let paused = monitor.filtered.filter { !$0.isPinned && $0.isPaused }
            let normal = monitor.filtered.filter { !$0.isPinned && !$0.isPaused }
            return pinned + paused + normal
        }

        return monitor.filtered.sorted(using: [pinnedComparator, pausedComparator] + userSortOrder)
    }

    private func canRevealInFinder(_ proc: Process) -> Bool {
        proc.executablePath != "-" && FileManager.default.fileExists(atPath: proc.executablePath)
    }

    private func revealExecutableInFinder(_ proc: Process) {
        guard canRevealInFinder(proc) else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: proc.executablePath)])
    }

    private func runningApp(for proc: Process) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: proc.id), app.bundleURL != nil else {
            return nil
        }
        return app
    }

    /// The app that gets restarted for this row: the process itself if it is an app, otherwise the app
    /// responsible for it (e.g. Safari for its WebKit WebContent / Networking / GPU processes).
    private func restartTarget(for proc: Process) -> (app: NSRunningApplication, isOwner: Bool)? {
        if let app = runningApp(for: proc) {
            return (app, false)
        }
        if let pid = ResponsibleProcess.pid(for: proc.id),
           let owner = NSRunningApplication(processIdentifier: pid),
           owner.bundleURL != nil {
            return (owner, true)
        }
        return nil
    }

    private func restartTitle(for proc: Process) -> String {
        guard let target = restartTarget(for: proc) else {
            return "Restart App"
        }
        if target.isOwner {
            return "Restart \(target.app.localizedName ?? "owner app") (owns this process)"
        }
        return "Restart App"
    }

    private func restartApp(_ proc: Process) {
        guard let target = restartTarget(for: proc), let url = target.app.bundleURL else {
            return
        }
        let app = target.app
        app.terminate()
        // Wait (up to 30 s) for a graceful quit before relaunching.
        Task { @MainActor in
            for _ in 0..<60 {
                if app.isTerminated { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard app.isTerminated else { return }
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Shortens long strings in the middle, e.g. "/Applications/Ado…/MacOS/Photoshop".
    private func truncatedMiddle(_ text: String, limit: Int = 50) -> String {
        guard text.count > limit else {
            return text
        }
        let head = (limit - 1) / 2
        let tail = limit - 1 - head
        return String(text.prefix(head)) + "…" + String(text.suffix(tail))
    }

    private func killProcess(_ proc: Process, force: Bool) {
        monitor.killProcess(pid: proc.id, force: force) { success, error in
            print(success)
            print(error as Any)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    TextField("Search", text: $monitor.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(width: 200)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            Table(displayedProcesses, sortOrder: sortBinding) {
                TableColumn("Name", value: \.name) { proc in
                    HoverReader { rowHovered in
                    HStack(spacing: 8) {
                        if proc.isPinned {
                            Button {
                                monitor.togglePin(proc)
                            } label: {
                                Image(systemName: "pin.fill")
                                    .foregroundColor(.yellow)
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                        }

                        ProcessIconButton(proc: proc, isRowHovered: rowHovered) {
                            monitor.togglePause(proc)
                        }

                        VStack(alignment: .leading, spacing: 1) {
                            Text(proc.name)
                                .fontWeight(.medium)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(verbatim: "PID \(proc.id)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Text(verbatim: "Parent: \(truncatedMiddle(proc.parentName, limit: 30)) (\(proc.parentPID))")
                        Text("Path: \(truncatedMiddle(proc.executablePath))")

                        Divider()

                        Button(proc.isPinned ? "Unpin" : "Pin") {
                            monitor.togglePin(proc)
                        }

                        Divider()

                        Button("Reveal Path in Finder") {
                            revealExecutableInFinder(proc)
                        }
                        .disabled(!canRevealInFinder(proc))

                        Divider()

                        Button(restartTitle(for: proc)) {
                            restartApp(proc)
                        }
                        .disabled(restartTarget(for: proc) == nil)
                        Button("Kill App") {
                            killProcess(proc, force: false)
                        }
                        Button("Force Kill App") {
                            killProcess(proc, force: true)
                        }
                    }
                    }
                }
                .width(min: 100, ideal: 120)

                TableColumn("CPU (5m history)", value: \.cpuUsage) { proc in
                    if proc.hasMetrics {
                        HStack(spacing: 8) {
                            Text(String(format: "%.1f%%", proc.cpuUsage))
                                .monospacedDigit()
                                .foregroundColor(proc.cpuUsage > 50 ? .red : proc.cpuUsage > 20 ? .orange : .primary)
                                .frame(width: 50, alignment: .trailing)
                            CPUSparklineView(values: proc.cpuHistory)
                        }
                    } else {
                        Text("---")
                            .foregroundColor(.secondary)
                    }
                }
                .width(min: 180, ideal: 220)

                TableColumn("Memory (25m history)", value: \.memoryMB) { proc in
                    if proc.hasMetrics {
                        HStack(spacing: 8) {
                            Text(String(format: "%.1f MB", proc.memoryMB))
                                .monospacedDigit()
                                .frame(width: 70, alignment: .trailing)
                            MemorySparklineView(values: proc.memoryHistory)
                        }
                    } else {
                        Text("---")
                            .foregroundColor(.secondary)
                    }
                }
                .width(min: 200, ideal: 240)

            }

            Divider()

            SystemStatsBar(stats: stats)
        }
        .onAppear { stats.start() }
        .onDisappear { stats.stop() }
    }
}
