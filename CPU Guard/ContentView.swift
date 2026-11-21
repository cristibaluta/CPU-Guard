//
//  ContentView.swift
//  CPU Guard
//
//  Created by Cristian Baluta on 08/05/2026.
//

import SwiftUI
import AppKit

struct CPUSparklineView: View {
    let values: [Double]
    var capacity: Int = HistoryConfig.cpuSamples

    var body: some View {
        GeometryReader { geo in
            let points = Array(values.suffix(capacity))
            let width = geo.size.width
            let height = geo.size.height
            // The chart always spans the full window; new samples enter at the right edge
            // and the not-yet-filled part on the left stays empty.
            let stepX = width / CGFloat(max(capacity - 1, 1))
            let startX = CGFloat(capacity - points.count) * stepX

            // Not-yet-recorded part of the window: fine dashed gray baseline.
            Path { path in
                let step = width / CGFloat(max(capacity - 1, 1))
                let emptyWidth = min(CGFloat(capacity - points.count) * step, width)
                path.move(to: CGPoint(x: 0, y: height - 0.5))
                path.addLine(to: CGPoint(x: emptyWidth, y: height - 0.5))
            }
            .stroke(Color.gray.opacity(0.6), style: StrokeStyle(lineWidth: 0.75, dash: [2, 2]))

            Path { path in
                guard let first = points.first else { return }

                let firstY = height - (CGFloat(max(0, min(first, 100))) / 100.0 * height)
                path.move(to: CGPoint(x: startX, y: firstY))
                if points.count == 1 {
                    path.addLine(to: CGPoint(x: startX + 1, y: firstY))
                }

                for (index, value) in points.dropFirst().enumerated() {
                    let x = startX + CGFloat(index + 1) * stepX
                    let y = height - (CGFloat(max(0, min(value, 100))) / 100.0 * height)
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(Color.accentColor, lineWidth: 1.5)
        }
        .frame(height: 24)
    }
}

struct MemorySparklineView: View {
    let values: [Double]
    var capacity: Int = HistoryConfig.memorySamples

    var body: some View {
        GeometryReader { geo in
            let points = Array(values.suffix(capacity))
            let width = geo.size.width
            let height = geo.size.height

            // Not-yet-recorded part of the window: fine dashed gray baseline.
            Path { path in
                let step = width / CGFloat(max(capacity - 1, 1))
                let emptyWidth = min(CGFloat(capacity - points.count) * step, width)
                path.move(to: CGPoint(x: 0, y: height - 0.5))
                path.addLine(to: CGPoint(x: emptyWidth, y: height - 0.5))
            }
            .stroke(Color.gray.opacity(0.6), style: StrokeStyle(lineWidth: 0.75, dash: [2, 2]))

            if !points.isEmpty {
                let stepX = width / CGFloat(max(capacity - 1, 1))
                let startX = CGFloat(capacity - points.count) * stepX
                let maxMemory = points.max() ?? 100.0
                let minMemory = points.min() ?? 0.0
                let range = max(maxMemory - minMemory, 1.0)

                Path { path in
                    if let first = points.first {
                        let firstY = height - ((CGFloat(first) - CGFloat(minMemory)) / CGFloat(range) * height)
                        path.move(to: CGPoint(x: startX, y: firstY))
                        if points.count == 1 {
                            path.addLine(to: CGPoint(x: startX + 1, y: firstY))
                        }

                        for (index, value) in points.dropFirst().enumerated() {
                            let x = startX + CGFloat(index + 1) * stepX
                            let y = height - ((CGFloat(value) - CGFloat(minMemory)) / CGFloat(range) * height)
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(Color.blue, lineWidth: 1.5)
            }
        }
        .frame(height: 24)
    }
}

struct ContentView: View {
    @ObservedObject var monitor: ProcessMonitor
    @State private var userSortOrder: [KeyPathComparator<Process>] = []
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

            Table(displayedProcesses, sortOrder: $userSortOrder) {
                TableColumn("Name", value: \.name) { proc in
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

                        ProcessIconButton(proc: proc) {
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
                .width(min: 100, ideal: 120)

                TableColumn("CPU", value: \.cpuUsage) { proc in
                    if proc.hasMetrics {
                        Text(String(format: "%.1f%%", proc.cpuUsage))
                            .foregroundColor(proc.cpuUsage > 50 ? .red : proc.cpuUsage > 20 ? .orange : .primary)
                    } else {
                        Text("---")
                            .foregroundColor(.secondary)
                    }
                }
                .width(40)

                TableColumn("5m CPU") { proc in
                    if proc.hasMetrics {
                        CPUSparklineView(values: proc.cpuHistory)
                    } else {
                        Text("---")
                            .foregroundColor(.secondary)
                    }
                }
                .width(170)

                TableColumn("Memory", value: \.memoryMB) { proc in
                    if proc.hasMetrics {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "%.1f → %.1f MB", proc.initialMemoryMB, proc.memoryMB))
                                .font(.system(size: 11))
                            let delta = proc.memoryMB - proc.initialMemoryMB
                            let deltaText = String(format: "%+.1f MB", delta)
                            Text(deltaText)
                                .font(.system(size: 10))
                                .foregroundColor(delta > 0 ? .orange : delta < 0 ? .green : .primary)
                        }
                    } else {
                        Text("---")
                            .foregroundColor(.secondary)
                    }
                }
                .width(100)

                TableColumn("Mem 25m") { proc in
                    if proc.hasMetrics {
                        MemorySparklineView(values: proc.memoryHistory)
                    } else {
                        Text("---")
                            .foregroundColor(.secondary)
                    }
                }
                .width(170)

            }

            Divider()

            SystemStatsBar(stats: stats)
        }
        .onAppear { stats.start() }
        .onDisappear { stats.stop() }
    }
}
