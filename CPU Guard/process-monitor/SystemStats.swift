//
//  SystemStats.swift
//  CPU Guard
//

import SwiftUI
import Darwin
import Combine

enum MemoryPressureLevel {
    case normal, warning, critical

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }

    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        }
    }
}

/// System-wide CPU / memory / swap numbers, the same ones Activity Monitor shows at the bottom.
@MainActor
final class SystemStatsMonitor: ObservableObject {
    @Published var cpuUser = 0.0       // percent
    @Published var cpuSystem = 0.0
    @Published var cpuIdle = 100.0

    @Published var memTotal = Double(ProcessInfo.processInfo.physicalMemory)   // bytes
    @Published var memUsed = 0.0
    @Published var memApp = 0.0
    @Published var memWired = 0.0
    @Published var memCompressed = 0.0
    @Published var memCached = 0.0

    @Published var swapUsed = 0.0
    @Published var swapTotal = 0.0
    @Published var pressure: MemoryPressureLevel = .normal

    private var timer: Timer?
    private var previousTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?

    var cpuTotal: Double { cpuUser + cpuSystem }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        readCPU()
        readMemory()
        readSwap()
        readPressure()
    }

    private func readCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let ticks = (user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
        defer { previousTicks = ticks }
        guard let prev = previousTicks else { return }

        let user = Double(ticks.user &- prev.user) + Double(ticks.nice &- prev.nice)
        let system = Double(ticks.system &- prev.system)
        let idle = Double(ticks.idle &- prev.idle)
        let total = user + system + idle
        guard total > 0 else { return }
        cpuUser = user / total * 100
        cpuSystem = system / total * 100
        cpuIdle = idle / total * 100
    }

    private func readMemory() {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let page = Double(getpagesize())
        let app = Double(vm.internal_page_count) - Double(vm.purgeable_count)
        memApp = max(app, 0) * page
        memWired = Double(vm.wire_count) * page
        memCompressed = Double(vm.compressor_page_count) * page
        memCached = (Double(vm.external_page_count) + Double(vm.purgeable_count)) * page
        // Same definition Activity Monitor uses for "Memory Used".
        memUsed = memApp + memWired + memCompressed
    }

    private func readSwap() {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            swapUsed = Double(swap.xsu_used)
            swapTotal = Double(swap.xsu_total)
        }
    }

    private func readPressure() {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return }
        switch level {
        case 4: pressure = .critical
        case 2: pressure = .warning
        default: pressure = .normal
        }
    }
}

struct SystemStatsBar: View {
    @ObservedObject var stats: SystemStatsMonitor

    private func bytes(_ value: Double) -> String {
        formatMemory(value / 1_048_576.0)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            stat("CPU", String(format: "%.1f%%", stats.cpuTotal),
                 detail: String(format: "User %.1f%% · System %.1f%% · Idle %.1f%%",
                                stats.cpuUser, stats.cpuSystem, stats.cpuIdle))

            stat("Memory", "\(bytes(stats.memUsed)) of \(bytes(stats.memTotal))",
                 detail: "App \(bytes(stats.memApp)) · Wired \(bytes(stats.memWired)) · Compressed \(bytes(stats.memCompressed))")

            stat("Swap", bytes(stats.swapUsed),
                 detail: "of \(bytes(stats.swapTotal))")

            VStack(alignment: .leading, spacing: 2) {
                Text("Memory Pressure")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                HStack(spacing: 5) {
                    Circle().fill(stats.pressure.color).frame(width: 8, height: 8)
                    Text(stats.pressure.label)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func stat(_ title: String, _ value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
            Text(detail)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
    }
}
