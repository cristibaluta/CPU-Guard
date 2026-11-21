//
//  ResponsibleProcess.swift
//  CPU Guard
//

import Foundation
import Darwin

/// Finds the process that is "responsible" for another one (the same notion Activity Monitor uses).
/// For example the WebKit WebContent / Networking / GPU XPC services launched for Safari
/// report Safari as their responsible process, although launchd is their real parent.
enum ResponsibleProcess {
    private typealias ResponsibilityFn = @convention(c) (pid_t) -> pid_t

    private static let function: ResponsibilityFn? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibilityFn.self)
    }()

    /// Returns the responsible pid, or nil if unknown or the process is responsible for itself.
    static func pid(for pid: pid_t) -> pid_t? {
        guard let function else { return nil }
        let result = function(pid)
        return result > 0 && result != pid ? result : nil
    }
}
