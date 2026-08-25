//
//  Process.swift
//  CPU Guard
//
//  Created by Cristian Baluta on 08/05/2026.
//

import Foundation
import Darwin
import Combine

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
    private let sampleInterval: TimeInterval = 10.0
    private let cpuHistoryLimit = 60     // 5 minutes at 5s cadence
    private let memoryHistoryLimit = 300 // 25 minutes at 5s cadence
    private let cpuMinHogPercent = 100.0
    private let secondsPerMachTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (Double(info.numer) / Double(info.denom)) / 1_000_000_000.0
    }()

    // Privileged helper fallback: proc_pidinfo fails for processes owned by other users
    // (WindowServer, kernel daemons, etc.) unless we ask the root daemon. Ticks returned by
    // the helper are tracked separately from `previousCPUTimes` since they're only ever
    // populated for pids the unprivileged path can't read.
    private let daemonManager: DaemonManager?
    private var previousHelperCPUTimes: [Int32: Double] = [:]

    init(daemonManager: DaemonManager? = nil) {
        self.daemonManager = daemonManager
    }

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
            guard pid > 0 else {
                continue
            }

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
            registerHogSample(pid: pid, cpuPercent: cpuPercent, hasMetrics: hasMetrics, shouldRecordSample: shouldRecordSample)
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
        previousHelperCPUTimes = previousHelperCPUTimes.filter { livePIDs.contains($0.key) }

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
        refreshHogAggregates()

        // proc_pidinfo fails for processes we don't own (WindowServer, root daemons, ...).
        // Ask the privileged helper for those specifically, in one batched round trip.
        let missingPIDs = updated.filter { !$0.hasMetrics }.map(\.id)
        if let daemonManager, !missingPIDs.isEmpty {
            daemonManager.fetchTaskInfo(forPIDs: missingPIDs) { [weak self] results in
                self?.applyHelperResults(results, elapsed: elapsed, shouldRecordSample: shouldRecordSample)
            }
        }
    }

    /// Patches in CPU/memory for processes the unprivileged pass above couldn't read, using
    /// results from the privileged helper daemon. Runs after `refresh()`'s synchronous pass
    /// already published `processes`, so this updates entries in place rather than rebuilding
    /// the array, and overwrites the placeholder (0%, not-yet-a-hog) values that pass recorded
    /// for these pids.
    private func applyHelperResults(_ results: [Int32: (cpuTicks: Double, residentBytes: Double)],
                                     elapsed: TimeInterval,
                                     shouldRecordSample: Bool) {
        guard !results.isEmpty else { return }

        for (pid, info) in results {
            guard let index = processes.firstIndex(where: { $0.id == pid }) else { continue }

            let memMB = info.residentBytes / 1_048_576.0
            var cpuPercent = 0.0
            if let prevTicks = previousHelperCPUTimes[pid], elapsed > 0 {
                let deltaSeconds = (info.cpuTicks - prevTicks) * secondsPerMachTick
                cpuPercent = max(0, deltaSeconds / elapsed) * 100.0
            }
            previousHelperCPUTimes[pid] = info.cpuTicks

            processes[index].hasMetrics = true
            processes[index].cpuUsage = cpuPercent
            processes[index].memoryMB = memMB

            if initialMemoryByPID[pid] == nil {
                initialMemoryByPID[pid] = memMB
            }
            processes[index].initialMemoryMB = initialMemoryByPID[pid] ?? memMB

            if shouldRecordSample {
                // The synchronous pass already appended a 0 placeholder for this pid; replace
                // it rather than appending again now that we have a real reading.
                if !processes[index].cpuHistory.isEmpty {
                    processes[index].cpuHistory[processes[index].cpuHistory.count - 1] = cpuPercent
                }
                if !processes[index].memoryHistory.isEmpty {
                    processes[index].memoryHistory[processes[index].memoryHistory.count - 1] = memMB
                }
            }

            registerHogSample(pid: pid, cpuPercent: cpuPercent, hasMetrics: true, shouldRecordSample: shouldRecordSample)
            processes[index].isResourceHog = (hogSamplesByPID[pid] ?? 0) >= 1
        }

        refreshHogAggregates()
    }

    private func registerHogSample(pid: Int32, cpuPercent: Double, hasMetrics: Bool, shouldRecordSample: Bool) {
        guard shouldRecordSample else {
            return
        }
        if cpuPercent > cpuMinHogPercent && hasMetrics {
            hogSamplesByPID[pid] = (hogSamplesByPID[pid] ?? 0) + 1
        } else {
            hogSamplesByPID[pid] = 0
        }
    }

    private func refreshHogAggregates() {
        let newHogs = processes.filter { $0.isResourceHog }
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

    func killProcess(pid: Int32, force: Bool, reply: @escaping (Bool, String?) -> Void) {
        daemonManager?.killProcess(pid: pid, force: force, reply: reply)
    }
}
