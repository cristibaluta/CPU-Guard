//
//  HelperDaemonProtocol.swift
//  CPU Guard
//
//  Created by Cristian Baluta on 22.08.2026.
//


import Foundation

// Protocols must be @objc and adopt NSXPCListenerDelegate / AnyObject
@objc(HelperDaemonProtocol)
public protocol HelperDaemonProtocol {
    /// Example method to query task info as root
    func getCPUUsage(for pid: Int32, with reply: @escaping (Double) -> Void)
}