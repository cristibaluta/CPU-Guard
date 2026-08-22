//
//  DaemonManager.swift
//  CPU Guard
//
//  Created by Cristian Baluta on 22.08.2026.
//

import SwiftUI
import ServiceManagement
import Combine

class DaemonManager: ObservableObject {
    
    @Published var isRegistered = false
    @Published var lastCpuResult: Double = 0.0
    
    private let service = SMAppService.daemon(plistName: "ro.imagin.CPU-Guard-Helper.plist")
    private var connection: NSXPCConnection?

    init() {
        updateStatus()
    }

    func updateStatus() {
        isRegistered = (service.status == .enabled)
    }

    // Register / Install Daemon (Triggers macOS Authorization Prompt)
    func registerDaemon() {
        do {
            try service.register()
            updateStatus()
        } catch {
            print("Failed to register daemon: \(error.localizedDescription)")
        }
    }

    // Unregister Daemon
    func unregisterDaemon() {
        do {
            try service.unregister()
            updateStatus()
        } catch {
            print("Failed to unregister daemon: \(error.localizedDescription)")
        }
    }

    // Establish XPC connection and communicate with root daemon
    func fetchCPU(for pid: Int32) {
        if connection == nil {
            let conn = NSXPCConnection(machServiceName: "ro.imagin.CPU-Guard-Helper", options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: HelperDaemonProtocol.self)
            conn.resume()
            self.connection = conn
        }

        guard let helper = connection?.remoteObjectProxyWithErrorHandler({ error in
            print("XPC Connection Error: \(error.localizedDescription)")
        }) as? HelperDaemonProtocol else { return }

        helper.getCPUUsage(for: pid) { [weak self] ticks in
            DispatchQueue.main.async {
                self?.lastCpuResult = ticks
            }
        }
    }
}
