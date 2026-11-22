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
    private var lastRecordedTimestamp: Date = .distantPast
    private let sampleInterval: TimeInterval = 10.0
    private let cpuHistoryLimit = HistoryConfig.cpuSamples        // 5 minutes at 10s cadence
    private let memoryHistoryLimit = HistoryConfig.memorySamples  // 25 minutes at 10s cadence
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

    private var isSampling = false
    private var refreshQueued = false
    private let sampler = ProcessSampler()

    /// Reads the process list on a background task (hundreds of syscalls), then merges the
    /// result into the published state on the main actor.
    func refresh() {
        if isSampling {
            refreshQueued = true
            return
        }
        isSampling = true
        let sampler = self.sampler
        Task.detached(priority: .utility) { [weak self] in
            let snapshot = sampler.sample()
            await MainActor.run {
                guard let self else { return }
                self.isSampling = false
                self.apply(snapshot)
                if self.refreshQueued {
                    self.refreshQueued = false
                    self.refresh()
                }
            }
        }
    }

    private func apply(_ snapshot: ProcessSnapshot) {
        let now = snapshot.timestamp
        let elapsed = now.timeIntervalSince(previousTimestamp)
        // Only append history on timer cadence so chart windows map to real time.
        let shouldRecordSample = previousCPUTimes.isEmpty
            || now.timeIntervalSince(lastRecordedTimestamp) >= (sampleInterval * 0.9)
        if shouldRecordSample {
            lastRecordedTimestamp = now
        }
        var newCPUTimes: [Int32: UInt64] = [:]
        var newCPUHistoryByPID: [Int32: [Double]] = [:]
        var newMemoryHistoryByPID: [Int32: [Double]] = [:]

        var nameByPID: [Int32: String] = [:]
        for e in snapshot.entries {
            nameByPID[e.pid] = e.name
        }

        var updated: [Process] = []
        updated.reserveCapacity(snapshot.entries.count)
        for e in snapshot.entries {
            let pid = e.pid
            let name = e.name
            let parentName = nameByPID[e.parentPID] ?? "-"

            var memMB = 0.0
            var cpuPercent = 0.0
            let hasMetrics = e.hasMetrics
            // If proc_pidinfo failed (kernel_task, windowserver, etc.) the process is still
            // included, but with hasMetrics = false.
            if hasMetrics {
                memMB = e.memMB
                newCPUTimes[pid] = e.totalTicks
                if let prev = previousCPUTimes[pid], elapsed > 0, e.totalTicks >= prev {
                    // proc_taskinfo CPU totals are mach absolute ticks; convert to seconds.
                    let cpuSeconds = Double(e.totalTicks - prev) * secondsPerMachTick
                    cpuPercent = (cpuSeconds / elapsed) * 100.0
                }
            }

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

            let isPinned = pinnedPIDs.contains(pid) || pinnedNames.contains(name)
            updated.append(Process(
                id: pid,
                name: name,
                parentPID: e.parentPID,
                parentName: parentName,
                executablePath: e.path,
                cpuUsage: cpuPercent,
                cpuHistory: cpuHistory,
                memoryMB: memMB,
                memoryHistory: memoryHistory,
                initialMemoryMB: initialMemory,
                isPaused: e.isStopped,
                isPinned: isPinned,
                isResourceHog: isResourceHog,
                hasMetrics: hasMetrics
            ))
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
        let scores = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, historyCPUScore(for: $0)) })
        processes = updated.sorted {
            let lhsScore = scores[$0.id] ?? 0
            let rhsScore = scores[$1.id] ?? 0

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

        var procs = processes

        for (pid, info) in results {
            guard let index = procs.firstIndex(where: { $0.id == pid }) else { continue }

            let memMB = info.residentBytes / 1_048_576.0
            var cpuPercent = 0.0
            if let prevTicks = previousHelperCPUTimes[pid], elapsed > 0 {
                let deltaSeconds = (info.cpuTicks - prevTicks) * secondsPerMachTick
                cpuPercent = max(0, deltaSeconds / elapsed) * 100.0
            }
            previousHelperCPUTimes[pid] = info.cpuTicks

            procs[index].hasMetrics = true
            procs[index].cpuUsage = cpuPercent
            procs[index].memoryMB = memMB

            if initialMemoryByPID[pid] == nil {
                initialMemoryByPID[pid] = memMB
            }
            procs[index].initialMemoryMB = initialMemoryByPID[pid] ?? memMB

            if shouldRecordSample {
                // The synchronous pass already appended a 0 placeholder for this pid; replace
                // it rather than appending again now that we have a real reading.
                if !procs[index].cpuHistory.isEmpty {
                    procs[index].cpuHistory[procs[index].cpuHistory.count - 1] = cpuPercent
                }
                if !procs[index].memoryHistory.isEmpty {
                    procs[index].memoryHistory[procs[index].memoryHistory.count - 1] = memMB
                }
                // refresh() reads the histories back from these dictionaries on the next tick, so the
                // real values must be stored there too; otherwise the placeholder 0s are what
                // accumulates and only the latest point looks real.
                cpuHistoryByPID[pid] = procs[index].cpuHistory
                memoryHistoryByPID[pid] = procs[index].memoryHistory
            }

            registerHogSample(pid: pid, cpuPercent: cpuPercent, hasMetrics: true, shouldRecordSample: shouldRecordSample)
            procs[index].isResourceHog = (hogSamplesByPID[pid] ?? 0) >= 1
        }

        processes = procs
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

// MARK: - Background sampling

struct RawProcess: Sendable {
    let pid: Int32
    let parentPID: Int32
    let name: String
    let path: String
    let isStopped: Bool
    let hasMetrics: Bool
    let memMB: Double
    let totalTicks: UInt64
}

struct ProcessSnapshot: Sendable {
    let timestamp: Date
    let entries: [RawProcess]
}

/// Does the syscall-heavy part of a refresh. Only ever used by one task at a time
/// (ProcessMonitor serialises calls), so the path cache needs no locking.
final class ProcessSampler: @unchecked Sendable {
    private struct PathKey: Hashable {
        let pid: Int32
        let startSeconds: Int
    }
    private var pathCache: [PathKey: String] = [:]

    func sample() -> ProcessSnapshot {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        sysctl(&mib, 4, nil, &size, nil, 0)
        // Leave headroom: processes can appear between the two calls.
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 32
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * MemoryLayout<kinfo_proc>.stride
        sysctl(&mib, 4, &procs, &size, nil, 0)
        let count = size / MemoryLayout<kinfo_proc>.stride

        var newCache: [PathKey: String] = [:]
        var entries: [RawProcess] = []
        entries.reserveCapacity(count)

        for p in procs.prefix(count) {
            let pid = p.kp_proc.p_pid
            guard pid > 0 else { continue }

            let key = PathKey(pid: pid, startSeconds: Int(p.kp_proc.p_un.__p_starttime.tv_sec))
            let path: String
            if let cached = pathCache[key] {
                path = cached
            } else {
                var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
                path = pathLen > 0 ? String(cString: pathBuffer) : "-"
            }
            newCache[key] = path

            let name: String
            if path != "-" {
                name = URL(fileURLWithPath: path).lastPathComponent
            } else {
                name = withUnsafeBytes(of: p.kp_proc.p_comm) { ptr -> String in
                    String(cString: ptr.bindMemory(to: CChar.self).baseAddress!)
                }
            }
            guard !name.isEmpty else { continue }

            var taskInfo = proc_taskinfo()
            let infoSize = Int32(MemoryLayout<proc_taskinfo>.size)
            let ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, infoSize)
            let hasMetrics = ret == infoSize

            entries.append(RawProcess(
                pid: pid,
                parentPID: p.kp_eproc.e_ppid,
                name: name,
                path: path,
                isStopped: Int32(p.kp_proc.p_stat) == SSTOP,
                hasMetrics: hasMetrics,
                memMB: hasMetrics ? Double(taskInfo.pti_resident_size) / 1_048_576.0 : 0,
                totalTicks: hasMetrics ? taskInfo.pti_total_user + taskInfo.pti_total_system : 0
            ))
        }
        pathCache = newCache
        return ProcessSnapshot(timestamp: Date(), entries: entries)
    }
}
