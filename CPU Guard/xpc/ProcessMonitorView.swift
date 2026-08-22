//
//  ProcessMonitorView.swift
//  CPU Guard
//
//  Created by Cristian Baluta on 22.08.2026.
//

import SwiftUI

struct ProcessMonitorView: View {
    @ObservedObject var monitor: ProcessMonitor
    @ObservedObject var daemonManager: DaemonManager

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle()
                    .fill(daemonManager.isRegistered ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(daemonManager.isRegistered ? "Helper Active" : "Helper Not Registered")
                    .font(.subheadline)

                Spacer()

                if daemonManager.isRegistered {
                    Button("Unregister Helper") {
                        daemonManager.unregisterDaemon()
                    }
                } else {
                    Button("Register Helper") {
                        daemonManager.registerDaemon()
                    }
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // The real process table. Rows the app can't read directly (WindowServer, etc.)
            // get filled in by the privileged helper once it's registered — see
            // ProcessMonitor.applyHelperResults.
            ContentView(monitor: monitor)
        }
        .frame(width: 800, height: 360)
    }
}
