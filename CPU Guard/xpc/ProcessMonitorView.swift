//
//  ProcessMonitorView.swift
//  CPU Guard
//
//  Created by Cristian Baluta on 22.08.2026.
//

import SwiftUI

struct ProcessMonitorView: View {
    @StateObject private var daemonManager = DaemonManager()

    var body: some View {
        VStack(spacing: 16) {
            Text("Daemon Status: \(daemonManager.isRegistered ? "Active" : "Not Registered")")
                .font(.headline)

            HStack {
                Button("Register Helper") {
                    daemonManager.registerDaemon()
                }
                .disabled(daemonManager.isRegistered)

                Button("Unregister Helper") {
                    daemonManager.unregisterDaemon()
                }
                .disabled(!daemonManager.isRegistered)
            }

            Divider()

            Button("Query WindowServer Metrics (PID 88)") {
                daemonManager.fetchCPU(for: 88)
            }
            .disabled(!daemonManager.isRegistered)

            Text("CPU Ticks: \(daemonManager.lastCpuResult)")
        }
        .padding()
        .frame(width: 400, height: 250)
    }
}
