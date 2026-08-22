//
//  HogAlertView.swift
//  CPU Guard
//

import SwiftUI

struct HogAlertView: View {
    @ObservedObject var monitor: ProcessMonitor
    var onDismiss: () -> Void

    @State private var sortOrder: [KeyPathComparator<Process>] = []

    private var displayedHogs: [Process] {
        sortOrder.isEmpty
            ? monitor.resourceHogs
            : monitor.resourceHogs.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 12))
                Text("Resource Hogs")
                    .font(.system(size: 12, weight: .semibold))
                Text("· \(monitor.resourceHogs.count) process\(monitor.resourceHogs.count == 1 ? "" : "es") over 10% CPU for 5s")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Dismiss") {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.trailing, 2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            Table(displayedHogs, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { proc in
                    HStack(spacing: 6) {
                        Button { monitor.togglePause(proc) } label: {
                            Image(systemName: proc.isPaused ? "play.circle.fill" : "pause.circle.fill")
                                .foregroundColor(proc.isPaused ? .green : .orange)
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.plain)

                        Text(proc.name)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .width(min: 80, ideal: 140)

                TableColumn("CPU", value: \.cpuUsage) { proc in
                    Text(String(format: "%.1f%%", proc.cpuUsage))
                        .foregroundColor(proc.cpuUsage > 50 ? .red : .orange)
                        .fontWeight(.medium)
                }
                .width(50)

                TableColumn("5m CPU") { proc in
                    CPUSparklineView(values: proc.cpuHistory)
                }
                .width(130)

                TableColumn("Memory", value: \.memoryMB) { proc in
                    Text(String(format: "%.1f MB", proc.memoryMB))
                        .font(.system(size: 11))
                }
                .width(75)

                TableColumn("Mem 25m") { proc in
                    MemorySparklineView(values: proc.memoryHistory)
                }
                .width(130)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}
