//
//  ProcessIconButton.swift
//  CPU Guard
//

import SwiftUI
import AppKit

@MainActor
private enum ProcessIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for proc: Process) -> NSImage {
        let path = proc.executablePath
        let key: String
        if let range = path.range(of: ".app/") {
            key = String(path[..<range.lowerBound]) + ".app"   // outermost app bundle
        } else {
            key = path
        }
        if let cached = cache[key] {
            return cached
        }
        let image: NSImage
        if key != "-", FileManager.default.fileExists(atPath: key) {
            image = NSWorkspace.shared.icon(forFile: key)
        } else {
            image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) ?? NSImage()
        }
        cache[key] = image
        return image
    }
}

/// Shows the app icon; on hover it turns into a pause button. Paused processes show a play button.
struct ProcessIconButton: View {
    let proc: Process
    let action: () -> Void
    /// True while the mouse is anywhere over the row's name cell, not just over the icon.
    var isRowHovered = false
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            if proc.isPaused {
                Image(systemName: "play.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 16))
            } else if hovering || isRowHovered {
                Image(systemName: "pause.circle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 16))
            } else {
                Image(nsImage: ProcessIconCache.icon(for: proc))
                    .resizable()
                    .frame(width: 18, height: 18)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Tracks whether the mouse is over the whole content and hands that state to the builder.
struct HoverReader<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering)
            .onHover { hovering = $0 }
    }
}
