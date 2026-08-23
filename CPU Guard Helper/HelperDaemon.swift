//
//  HelperDaemon.swift
//  CPU Guard
//
//  Created by Cristian Baluta on 22.08.2026.
//

import Foundation

class HelperDaemon: NSObject, HelperDaemonProtocol, NSXPCListenerDelegate {

    // Listener delegate method to validate and accept incoming connections
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: HelperDaemonProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    // Implementation of the protocol function (Runs as root)
    func getCPUUsage(for pid: Int32, with reply: @escaping (Double) -> Void) {
        var taskInfo = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, size)

        if ret == size {
            // Process task info succeeded because daemon is root
            let cpuTicks = Double(taskInfo.pti_total_user + taskInfo.pti_total_system)
            reply(cpuTicks)
        } else {
            reply(0.0)
        }
    }

    func getTaskInfo(forPIDs pids: [Int32], with reply: @escaping ([Int32], [Double], [Double], [Bool]) -> Void) {
        let expectedSize = Int32(MemoryLayout<proc_taskinfo>.size)

        var outPIDs: [Int32] = []
        var cpuTicks: [Double] = []
        var residentBytes: [Double] = []
        var success: [Bool] = []
        outPIDs.reserveCapacity(pids.count)
        cpuTicks.reserveCapacity(pids.count)
        residentBytes.reserveCapacity(pids.count)
        success.reserveCapacity(pids.count)

        for pid in pids {
            var taskInfo = proc_taskinfo()
            let ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, expectedSize)

            outPIDs.append(pid)
            if ret == expectedSize {
                cpuTicks.append(Double(taskInfo.pti_total_user + taskInfo.pti_total_system))
                residentBytes.append(Double(taskInfo.pti_resident_size))
                success.append(true)
            } else {
                // Still exited, permission-denied for some other reason, etc.
                cpuTicks.append(0)
                residentBytes.append(0)
                success.append(false)
            }
        }

        reply(outPIDs, cpuTicks, residentBytes, success)
    }

    func killProcess(pid: Int32, force: Bool, reply: @escaping (Bool, String?) -> Void) {
        // Determine signal: SIGKILL (-9) forces immediate termination; SIGTERM (-15) asks politely
        let signal = force ? SIGKILL : SIGTERM

        // Call POSIX kill()
        let result = kill(pid, signal)

        if result == 0 {
            reply(true, nil)
        } else {
            let errorMessage = String(cString: strerror(errno))
            reply(false, errorMessage)
        }
    }
}
