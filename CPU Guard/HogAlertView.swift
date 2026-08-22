//
//  HogAlertView.swift
//  CPU Guard
//

import SwiftUI

struct HogAlertView: View {
    @ObservedObject var monitor: ProcessMonitor
    var onDismiss: () -> Void

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

            // Process rows — no header row
            VStack(spacing: 0) {
                ForEach(monitor.resourceHogs) { proc in
                    HogRowView(proc: proc, monitor: monitor)
                    if proc.id != monitor.resourceHogs.last?.id {
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct HogRowView: View {
    let proc: Process
    let monitor: ProcessMonitor

    var body: some View {
        HStack(spacing: 8) {
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
                .frame(minWidth: 80, idealWidth: 140, maxWidth: .infinity, alignment: .leading)

            Text(String(format: "%.1f%%", proc.cpuUsage))
                .foregroundColor(proc.cpuUsage > 50 ? .red : .orange)
                .fontWeight(.medium)
                .frame(width: 50, alignment: .trailing)

            CPUSparklineView(values: proc.cpuHistory)
                .frame(width: 130, height: 24)

            Text(String(format: "%.1f MB", proc.memoryMB))
                .font(.system(size: 11))
                .frame(width: 75, alignment: .trailing)

            MemorySparklineView(values: proc.memoryHistory)
                .frame(width: 130, height: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
