//
//  QuitRule.swift
//  CPU Guard
//

import Foundation

/// When one of the `triggers` quits (and none of the other triggers is still running),
/// every running app in `linked` is asked to quit.
struct QuitRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var isEnabled = true
    var triggers: [String]   // bundle identifiers
    var linked: [String]     // bundle identifiers
    var delay: TimeInterval = 2
    var forceQuitAfter: TimeInterval? = nil   // nil = never force quit

    /// Default rules used the first time the app runs. Afterwards rules are edited in the UI.
    static let defaults: [QuitRule] = [
        QuitRule(
            name: "Adobe Creative Cloud",
            triggers: [
                "com.adobe.Photoshop",
                "com.adobe.illustrator",
                "com.adobe.InDesign",
                "com.adobe.PremierePro.25",
                "com.adobe.AfterEffects",
                "com.adobe.Lightroom",
                "com.adobe.LightroomClassicCC7"
            ],
            linked: [
                "com.adobe.acc.AdobeCreativeCloud",
                "com.adobe.accmac",
                "com.adobe.CCXProcess",
                "com.adobe.CCLibrary",
                "com.adobe.AdobeDesktopService",
                "com.adobe.bridge14",
                "com.adobe.adobe-genuine-service"
            ]
        )
    ]
}
