//
//  AboutView.swift
//  CPU Guard
//

import SwiftUI
import AppKit

struct AboutView: View {
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    private var name: String { (info["CFBundleName"] as? String) ?? "CPU Guard" }
    private var version: String { (info["CFBundleShortVersionString"] as? String) ?? "1.0" }
    private var build: String { (info["CFBundleVersion"] as? String) ?? "1" }
    private var copyright: String { (info["NSHumanReadableCopyright"] as? String) ?? "" }

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text(name)
                .font(.system(size: 20, weight: .semibold))
            Text("Version \(version) (\(build))")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            if !copyright.isEmpty {
                Text(copyright)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }
        }
        .padding(32)
        .frame(minWidth: 300, minHeight: 240)
    }
}
