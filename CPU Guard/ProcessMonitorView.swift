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
    var onIconClick: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // Only shown while the helper isn't registered. Once registered, it is
            // managed from the status bar context menu.
            if !daemonManager.isRegistered {
                HStack {
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 8, height: 8)
                    Text("Helper Not Registered")
                        .font(.subheadline)

                    Spacer()

                    Button("Register Helper") {
                        daemonManager.registerDaemon()
                    }
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))

                Divider()
            }

            // The real process table. Rows the app can't read directly (WindowServer, etc.)
            // get filled in by the privileged helper once it's registered — see
            // ProcessMonitor.applyHelperResults.
            ContentView(monitor: monitor, onIconClick: onIconClick)
        }
        .frame(width: 800, height: 500)
    }
}
