//
//  Process.swift
//  CPU Guard
//
//  Created by Cristian Baluta on 22.08.2026.
//

import Foundation

/// History windows. Samples are recorded every `ProcessMonitor.sampleInterval` (10 s).
enum HistoryConfig {
    static let cpuSamples = 30       // 5 minutes
    static let memorySamples = 150   // 25 minutes
}

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

    var status: String {
        isPaused ? "Paused" : "Running"
    }
    var pinSortRank: Int {
        isPinned ? 1 : 0
    }
    var pauseSortRank: Int {
        isPaused ? 1 : 0
    }
}
