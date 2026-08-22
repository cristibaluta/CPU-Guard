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
    let parentPID: Int32
    let parentName: String
    let executablePath: String
    var cpuUsage: Double
    var cpuHistory: [Double]
    var memoryMB: Double
    var memoryHistory: [Double]
    var initialMemoryMB: Double  // Memory when first seen
    var isPaused: Bool
    var isPinned: Bool
    var isResourceHog: Bool
    var hasMetrics: Bool  // True if proc_pidinfo succeeded
    var status: String { isPaused ? "Paused" : "Running" }
    var pinSortRank: Int { isPinned ? 1 : 0 }
    var pauseSortRank: Int { isPaused ? 1 : 0 }
}

@MainActor
class ProcessMonitor: ObservableObject {
    @Published var processes: [Process] = []
    @Published var searchText: String = ""
    @Published var resourceHogs: [Process] = []

    var onNewHogDetected: (() -> Void)?
    var onResourceHogsCleared: (() -> Void)?

    private var timer: Timer?
    private var previousCPUTimes: [Int32: UInt64] = [:]
    private var cpuHistoryByPID: [Int32: [Double]] = [:]
    private var memoryHistoryByPID: [Int32: [Double]] = [:]
    private var initialMemoryByPID: [Int32: Double] = [:]
    private var pinnedPIDs: Set<Int32> = []
    private var pinnedNames: Set<String> = {
        let saved = UserDefaults.standard.stringArray(forKey: "pinnedProcessNames") ?? []
        return Set(saved)
    }()
    private var hogSamplesByPID: [Int32: Int] = [:]
    private var previousTimestamp: Date = Date()
    private let sampleInterval: TimeInterval = 5.0
    private let cpuHistoryLimit = 60     // 5 minutes at 5s cadence
    private let memoryHistoryLimit = 300 // 25 minutes at 5s cadence
    private let secondsPerMachTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (Double(info.numer) / Double(info.denom)) / 1_000_000_000.0
    }()

    var filtered: [Process] {
        if searchText.isEmpty { return processes }
        return processes.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
            || $0.parentName.localizedCaseInsensitiveContains(searchText)
            || $0.executablePath.localizedCaseInsensitiveContains(searchText)
            || String($0.id).contains(searchText)
            || String($0.parentPID).contains(searchText)
        }
    }

    private func historyCPUScore(for process: Process) -> Double {
        process.cpuHistory.reduce(0, +)
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
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
        // Only append history on timer cadence so chart windows map to real time.
        let shouldRecordSample = previousCPUTimes.isEmpty || elapsed >= (sampleInterval * 0.9)
        var newCPUTimes: [Int32: UInt64] = [:]
        var newCPUHistoryByPID: [Int32: [Double]] = [:]
        var newMemoryHistoryByPID: [Int32: [Double]] = [:]

        // Build PID->name/path maps up front so we can label parent processes.
        var nameByPID: [Int32: String] = [:]
        var executablePathByPID: [Int32: String] = [:]
        for p in procs {
            let pid = p.kp_proc.p_pid
            guard pid > 0 else { continue }

            let nameBytes = p.kp_proc.p_comm
            let kernelName = withUnsafeBytes(of: nameBytes) { ptr -> String in
                let buf = ptr.bindMemory(to: CChar.self)
                return String(cString: buf.baseAddress!)
            }

            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let executablePath = pathLen > 0 ? String(cString: pathBuffer) : "-"
            executablePathByPID[pid] = executablePath

            let displayName: String
            if executablePath != "-" {
                displayName = URL(fileURLWithPath: executablePath).lastPathComponent
            } else {
                displayName = kernelName
            }

            if !displayName.isEmpty {
                nameByPID[pid] = displayName
            }
        }

        var updated: [Process] = []
        for p in procs {
            let pid = p.kp_proc.p_pid
            guard pid > 0 else { continue }

            guard let name = nameByPID[pid], !name.isEmpty else {
                continue
            }

            let parentPID = p.kp_eproc.e_ppid
            let parentName = nameByPID[parentPID] ?? "-"
            let executablePath = executablePathByPID[pid] ?? "-"

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

            var cpuHistory = cpuHistoryByPID[pid] ?? []
            if shouldRecordSample {
                cpuHistory.append(cpuPercent)
            }
            if cpuHistory.count > cpuHistoryLimit {
                cpuHistory.removeFirst(cpuHistory.count - cpuHistoryLimit)
            }
            newCPUHistoryByPID[pid] = cpuHistory

            var memoryHistory = memoryHistoryByPID[pid] ?? []
            if shouldRecordSample {
                memoryHistory.append(memMB)
            }
            if memoryHistory.count > memoryHistoryLimit {
                memoryHistory.removeFirst(memoryHistory.count - memoryHistoryLimit)
            }
            newMemoryHistoryByPID[pid] = memoryHistory

            // Store initial memory on first appearance
            if initialMemoryByPID[pid] == nil {
                initialMemoryByPID[pid] = memMB
            }
            let initialMemory = initialMemoryByPID[pid] ?? memMB

            // Resource hog detection: 1 sample at 5s cadence = 5s sustained > 10% CPU.
            if shouldRecordSample {
                if cpuPercent > 10.0 && hasMetrics {
                    hogSamplesByPID[pid] = (hogSamplesByPID[pid] ?? 0) + 1
                } else {
                    hogSamplesByPID[pid] = 0
                }
            }
            let isResourceHog = (hogSamplesByPID[pid] ?? 0) >= 1

            let isPaused = (Int32(p.kp_proc.p_stat) == SSTOP)
            let isPinned = pinnedPIDs.contains(pid) || pinnedNames.contains(name)
            let proc = Process(
                id: pid,
                name: name,
                parentPID: parentPID,
                parentName: parentName,
                executablePath: executablePath,
                cpuUsage: cpuPercent,
                cpuHistory: cpuHistory,
                memoryMB: memMB,
                memoryHistory: memoryHistory,
                initialMemoryMB: initialMemory,
                isPaused: isPaused,
                isPinned: isPinned,
                isResourceHog: isResourceHog,
                hasMetrics: hasMetrics
            )
            updated.append(proc)
        }

        // Drop pins for processes that no longer exist to keep state tidy.
        let livePIDs = Set(updated.map(\.id))
        pinnedPIDs = pinnedPIDs.intersection(livePIDs)
        // Sync pinnedNames to only live processes (by name) so stale names don't accumulate.
        let liveNames = Set(updated.map(\.name))
        pinnedNames = pinnedNames.intersection(liveNames)
        UserDefaults.standard.set(Array(pinnedNames), forKey: "pinnedProcessNames")
        hogSamplesByPID = hogSamplesByPID.filter { livePIDs.contains($0.key) }

        // Update resource hogs and fire callbacks.
        let newHogs = updated.filter { $0.isResourceHog }
        let newHogNames = Set(newHogs.map(\.name))
        let prevHogNames = Set(resourceHogs.map(\.name))
        let allHogsCleared = newHogs.isEmpty && !resourceHogs.isEmpty
        resourceHogs = newHogs
        if !newHogNames.subtracting(prevHogNames).isEmpty {
            onNewHogDetected?()
        }
        if allHogsCleared {
            onResourceHogsCleared?()
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

    func togglePin(_ process: Process) {
        if pinnedNames.contains(process.name) {
            pinnedNames.remove(process.name)
            pinnedPIDs.remove(process.id)
        } else {
            pinnedNames.insert(process.name)
            pinnedPIDs.insert(process.id)
        }
        UserDefaults.standard.set(Array(pinnedNames), forKey: "pinnedProcessNames")
        refresh()
    }
}
