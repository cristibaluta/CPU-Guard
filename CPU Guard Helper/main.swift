//
//  main.swift
//  CPU Guard Helper
//
//  Created by Cristian Baluta on 22.08.2026.
//

import Foundation

let helperToolMachServiceName = "ro.imagin.CPU-Guard-Helper"

let delegate = HelperDaemon()
// The MachServiceName MUST match your SMAppService plist configuration
let listener = NSXPCListener(machServiceName: helperToolMachServiceName)
listener.delegate = delegate
listener.resume()

// Keep the daemon runloop active
RunLoop.main.run()
