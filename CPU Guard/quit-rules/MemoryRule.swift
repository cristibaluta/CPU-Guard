//
//  MemoryRule.swift
//  CPU Guard
//

import Foundation
import Combine

/// Warn when the total resident memory of an app (including its helper processes)
/// goes above `limitMB`.
struct MemoryRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var bundleID: String
    var limitMB: Double = 4096
    var isEnabled = true
}

@MainActor
final class MemoryRulesStore: ObservableObject {
    static let shared = MemoryRulesStore()
    private static let key = "memoryRules.v1"

    @Published var rules: [MemoryRule] {
        didSet { save() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([MemoryRule].self, from: data) {
            rules = decoded
        } else {
            rules = []
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
