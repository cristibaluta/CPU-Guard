//
//  PowerMonitor.swift
//  CPU Guard
//
//  Created by Cristian Baluta on 23.08.2026.
//

import Foundation
import IOKit.pwr_mgt

//func fetchSleepWakeHistory() -> String {
//    let task = Process()
//    task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
//    task.arguments = ["-g", "log"]
//
//    let pipe = Pipe()
//    task.standardOutput = pipe
//
//    do {
//        try task.run()
//        let data = pipe.fileHandleForReading.readDataToEndOfFile()
//        if let output = String(data: data, encoding: .utf8) {
//            // Filter output for DarkWake, Sleep, and Wake events
//            let logLines = output.components(separatedBy: .newlines)
//            let filtered = logLines.filter { $0.contains("DarkWake") || $0.contains("Wake from") }
//            return filtered.suffix(30).joined(separator: "\n")
//        }
//    } catch {
//        print("Failed to run pmset: \(error)")
//    }
//    return ""
//}

class PowerMonitor {
    private var rootPort: io_connect_t = 0
    private var notifyPortRef: IONotificationPortRef?

    func startMonitoring() {
        let appName = "com.example.PowerMonitor" as CFString
        rootPort = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(),
            &notifyPortRef,
            { (refcon, service, messageType, messageArgument) in
                let monitor = Unmanaged<PowerMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                monitor.handlePowerMessage(messageType: messageType)
            },
            &rootPort
        )

        if let notifyPortRef = notifyPortRef {
            CFRunLoopAddSource(
                CFRunLoopGetCurrent(),
                IONotificationPortGetRunLoopSource(notifyPortRef).takeUnretainedValue(),
                .defaultMode
            )
        }
    }

    private func handlePowerMessage(messageType: UInt32) {
        print("Computer wake status: \(messageType)")
//        switch messageType {
//        case UInt32(kIOMessageSystemWillSleep):
//            print("Mac going to sleep: \(Date())")
//        case UInt32(kIOMessageSystemHasPoweredOn):
//            print("Mac woke up: \(Date())")
//        default:
//            break
//        }
    }
}
