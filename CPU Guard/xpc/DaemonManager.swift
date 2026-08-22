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

    private let machServiceName = "ro.imagin.CPU-Guard-Helper"
    private let service = SMAppService.daemon(plistName: "ro.imagin.CPU-Guard-Helper.plist")
    private var connection: NSXPCConnection?

    init() {
        updateStatus()
    }

    func updateStatus() {
        isRegistered = (service.status == .enabled)
    }

    // Register / Install Daemon
    func registerDaemon() {
        do {
            try service.register()
            updateStatus()
            // Registration can succeed while the daemon stays disabled until the
            // user approves it in System Settings (this replaces the old
            // SMJobBless authorization prompt).
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            print("Failed to register daemon: \(error)")
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

    // MARK: - XPC connection

    private func makeConnection() -> NSXPCConnection {
        let conn = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperDaemonProtocol.self)
        // If the daemon restarts or the connection drops, throw away the stale proxy so the
        // next call reconnects instead of silently failing forever.
        conn.invalidationHandler = { [weak self] in self?.connection = nil }
        conn.interruptionHandler = { [weak self] in self?.connection = nil }
        conn.resume()
        return conn
    }

    private func helperProxy(errorHandler: @escaping (Error) -> Void) -> HelperDaemonProtocol? {
        if connection == nil {
            connection = makeConnection()
        }
        return connection?.remoteObjectProxyWithErrorHandler(errorHandler) as? HelperDaemonProtocol
    }

    // Establish XPC connection and communicate with root daemon (manual single-PID test)
    func fetchCPU(for pid: Int32) {
        guard let helper = helperProxy(errorHandler: { error in
            print("XPC Connection Error: \(error.localizedDescription)")
        }) else { return }

        helper.getCPUUsage(for: pid) { [weak self] ticks in
            DispatchQueue.main.async {
                self?.lastCpuResult = ticks
            }
        }
    }

    /// Batched CPU/memory query used by ProcessMonitor for processes it couldn't read itself
    /// (e.g. WindowServer). Completion is always called on the main queue with a result for
    /// every pid the helper was able to read; unreadable/missing pids are simply absent.
    /// Returns an empty result immediately if the daemon isn't registered — callers should
    /// treat that the same as "helper unavailable" rather than an error.
    func fetchTaskInfo(forPIDs pids: [Int32],
                        completion: @escaping (_ results: [Int32: (cpuTicks: Double, residentBytes: Double)]) -> Void) {
        guard isRegistered, !pids.isEmpty else {
            completion([:])
            return
        }
        guard let helper = helperProxy(errorHandler: { error in
            print("XPC Connection Error: \(error.localizedDescription)")
            DispatchQueue.main.async { completion([:]) }
        }) else {
            completion([:])
            return
        }

        helper.getTaskInfo(forPIDs: pids) { returnedPIDs, cpuTicks, residentBytes, success in
            var results: [Int32: (cpuTicks: Double, residentBytes: Double)] = [:]
            for i in 0..<returnedPIDs.count where i < success.count && success[i] {
                results[returnedPIDs[i]] = (cpuTicks[i], residentBytes[i])
            }
            DispatchQueue.main.async {
                completion(results)
            }
        }
    }
}
