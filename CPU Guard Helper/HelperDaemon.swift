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
}
