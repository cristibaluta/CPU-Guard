//
//  Process.swift
//  CPU Guard
//
//  Created by Cristian Baluta on 08/05/2026.
//


import Foundation
import Darwin
import Combine

struct Process: Identifiable {
    let id: Int32  // PID
    let name: String
    var cpuUsage: Double
    var cpuHistory: [Double]
    var memoryMB: Double
    var memoryHistory: [Double]
    var initialMemoryMB: Double  // Memory when first seen
    var isPaused: Bool
    var hasMetrics: Bool  // True if proc_pidinfo succeeded
    var status: String { isPaused ? "Paused" : "Running" }
}

@MainActor
class ProcessMonitor: ObservableObject {
    @Published var processes: [Process] = []
    @Published var searchText: String = ""
    private var timer: Timer?
    private var previousCPUTimes: [Int32: UInt64] = [:]
    private var cpuHistoryByPID: [Int32: [Double]] = [:]
    private var memoryHistoryByPID: [Int32: [Double]] = [:]
    private var initialMemoryByPID: [Int32: Double] = [:]
    private var previousTimestamp: Date = Date()
    private let secondsPerMachTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (Double(info.numer) / Double(info.denom)) / 1_000_000_000.0
    }()

    var filtered: [Process] {
        if searchText.isEmpty { return processes }
        return processes.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private func historyCPUScore(for process: Process) -> Double {
        process.cpuHistory.reduce(0, +)
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
    }

    func refresh() {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        sysctl(&mib, 4, nil, &size, nil, 0)
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        sysctl(&mib, 4, &procs, &size, nil, 0)

        let now = Date()
        let elapsed = now.timeIntervalSince(previousTimestamp)
        var newCPUTimes: [Int32: UInt64] = [:]
        var newCPUHistoryByPID: [Int32: [Double]] = [:]
        var newMemoryHistoryByPID: [Int32: [Double]] = [:]

        var updated: [Process] = []
        for p in procs {
            let pid = p.kp_proc.p_pid
            guard pid > 0 else { continue }

            let nameBytes = p.kp_proc.p_comm
            let name = withUnsafeBytes(of: nameBytes) { ptr -> String in
                let buf = ptr.bindMemory(to: CChar.self)
                return String(cString: buf.baseAddress!)
            }
            guard !name.isEmpty else {
                continue
            }

            // Memory + CPU via proc_pidinfo
            var taskInfo = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            let ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, size)

            var memMB = 0.0
            var cpuPercent = 0.0
            var hasMetrics = false

            if ret == Int32(MemoryLayout<proc_taskinfo>.size) {
                hasMetrics = true
                memMB = Double(taskInfo.pti_resident_size) / 1_048_576.0

                let totalTicks = taskInfo.pti_total_user + taskInfo.pti_total_system
                newCPUTimes[pid] = totalTicks
                if let prev = previousCPUTimes[pid], elapsed > 0 {
                    let delta = Double(totalTicks - prev)
                    // proc_taskinfo CPU totals are mach absolute ticks; convert to seconds.
                    let cpuSeconds = delta * secondsPerMachTick
                    cpuPercent = (cpuSeconds / elapsed) * 100.0
                }
            }
            // If proc_pidinfo fails (common for kernel_task, windowserver, etc.),
            // we still include the process but with hasMetrics = false.

            // Keep a rolling 300-point history (about 25 minutes at 5s refresh).
            var cpuHistory = cpuHistoryByPID[pid] ?? []
            cpuHistory.append(cpuPercent)
            if cpuHistory.count > 300 {
                cpuHistory.removeFirst(cpuHistory.count - 300)
            }
            newCPUHistoryByPID[pid] = cpuHistory

            // Track memory history
            var memoryHistory = memoryHistoryByPID[pid] ?? []
            memoryHistory.append(memMB)
            if memoryHistory.count > 300 {
                memoryHistory.removeFirst(memoryHistory.count - 300)
            }
            newMemoryHistoryByPID[pid] = memoryHistory

            // Store initial memory on first appearance
            if initialMemoryByPID[pid] == nil {
                initialMemoryByPID[pid] = memMB
            }
            let initialMemory = initialMemoryByPID[pid] ?? memMB

            let isPaused = (Int32(p.kp_proc.p_stat) == SSTOP)
            let proc = Process(
                id: pid,
                name: name,
                cpuUsage: cpuPercent,
                cpuHistory: cpuHistory,
                memoryMB: memMB,
                memoryHistory: memoryHistory,
                initialMemoryMB: initialMemory,
                isPaused: isPaused,
                hasMetrics: hasMetrics
            )
            updated.append(proc)
        }

        previousCPUTimes = newCPUTimes
        cpuHistoryByPID = newCPUHistoryByPID
        memoryHistoryByPID = newMemoryHistoryByPID
        previousTimestamp = now
        processes = updated.sorted {
            let lhsScore = historyCPUScore(for: $0)
            let rhsScore = historyCPUScore(for: $1)

            if lhsScore == rhsScore {
                return $0.cpuUsage > $1.cpuUsage
            }
            return lhsScore > rhsScore
        }
    }

    func togglePause(_ process: Process) {
        let signal = process.isPaused ? SIGCONT : SIGSTOP
        kill(process.id, signal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.refresh()
        }
    }
}
