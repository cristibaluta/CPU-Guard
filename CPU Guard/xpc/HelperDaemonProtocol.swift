//
//  HelperDaemonProtocol.swift
//  CPU Guard
//
//  Created by Cristian Baluta on 22.08.2026.
//


import Foundation

// Protocols must be @objc and adopt NSXPCListenerDelegate / AnyObject
@objc(HelperDaemonProtocol)
public protocol HelperDaemonProtocol {
    /// Single-PID CPU query. Kept for the manual "test the helper" button in ProcessMonitorView.
    func getCPUUsage(for pid: Int32, with reply: @escaping (Double) -> Void)

    /// Batched query used by ProcessMonitor's periodic refresh.
    ///
    /// For each pid in `pids`, returns the cumulative CPU ticks (mach-absolute-time units,
    /// matching `pti_total_user + pti_total_system`) and resident memory in bytes, as seen
    /// by the root daemon via `proc_pidinfo`. `success[i]` is `false` when `proc_pidinfo`
    /// failed for that pid (e.g. it already exited).
    ///
    /// This runs as root, so it can read processes owned by other users (WindowServer,
    /// kernel daemons, etc.) that the unprivileged main app can't query directly.
    /// Batched into one round trip rather than one XPC call per pid, since ProcessMonitor
    /// may need this for dozens of processes every refresh cycle.
    func getTaskInfo(forPIDs pids: [Int32],
                      with reply: @escaping (_ pids: [Int32], _ cpuTicks: [Double], _ residentBytes: [Double], _ success: [Bool]) -> Void)
}
