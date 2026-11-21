//
//  QuitRulesStore.swift
//  CPU Guard
//

import Foundation
import Combine

@MainActor
final class QuitRulesStore: ObservableObject {
    static let shared = QuitRulesStore()
    private static let key = "quitRules.v1"

    @Published var rules: [QuitRule] {
        didSet { save() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([QuitRule].self, from: data) {
            rules = decoded
        } else {
            rules = QuitRule.defaults
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
