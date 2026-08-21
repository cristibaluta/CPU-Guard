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

    var body: some View {
        GeometryReader { geo in
            let points = values.suffix(60)
            let width = geo.size.width
            let height = geo.size.height
            let stepX = width / CGFloat(max(points.count - 1, 1))

            Path { path in
                guard let first = points.first else { return }

                let firstY = height - (CGFloat(max(0, min(first, 100))) / 100.0 * height)
                path.move(to: CGPoint(x: 0, y: firstY))

                for (index, value) in points.dropFirst().enumerated() {
                    let x = CGFloat(index + 1) * stepX
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

    var body: some View {
        GeometryReader { geo in
            let points = values.suffix(300)
            let width = geo.size.width
            let height = geo.size.height

            if !points.isEmpty {
                let stepX = width / CGFloat(max(points.count - 1, 1))
                let maxMemory = points.max() ?? 100.0
                let minMemory = points.min() ?? 0.0
                let range = max(maxMemory - minMemory, 1.0)

                Path { path in
                    if let first = points.first {
                        let firstY = height - ((CGFloat(first) - CGFloat(minMemory)) / CGFloat(range) * height)
                        path.move(to: CGPoint(x: 0, y: firstY))

                        for (index, value) in points.dropFirst().enumerated() {
                            let x = CGFloat(index + 1) * stepX
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
    @StateObject private var monitor = ProcessMonitor()
    @State private var sortOrder = [KeyPathComparator(\Process.name)]

    private func canRevealInFinder(_ proc: Process) -> Bool {
        proc.executablePath != "-" && FileManager.default.fileExists(atPath: proc.executablePath)
    }

    private func revealExecutableInFinder(_ proc: Process) {
        guard canRevealInFinder(proc) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: proc.executablePath)])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search processes...", text: $monitor.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            Table(monitor.filtered, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { proc in
                    HStack(spacing: 8) {
                        Button {
                            monitor.togglePause(proc)
                        } label: {
                            Image(systemName: proc.isPaused ? "play.circle.fill" : "pause.circle.fill")
                                .foregroundColor(proc.isPaused ? .green : .orange)
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(proc.name)
                                .fontWeight(.medium)
                            Text("PID \(proc.id)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(minHeight: 30)
                    .contextMenu {
                        Text("Parent: \(proc.parentName) (\(proc.parentPID))")
                        Text("Path: \(proc.executablePath)")
                        Divider()
                        Button("Reveal Path in Finder") {
                            revealExecutableInFinder(proc)
                        }
                        .disabled(!canRevealInFinder(proc))
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
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}
