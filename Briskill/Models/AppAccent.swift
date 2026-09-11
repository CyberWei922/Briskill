import AppKit
import SwiftUI

enum AppAccent: String, CaseIterable, Identifiable {
    case system
    case purple
    case blue
    case cyan
    case green
    case orange
    case pink

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: String(localized: "跟随系统")
        case .purple: String(localized: "紫色")
        case .blue: String(localized: "蓝色")
        case .cyan: String(localized: "青色")
        case .green: String(localized: "绿色")
        case .orange: String(localized: "橙色")
        case .pink: String(localized: "粉色")
        }
    }

    var color: Color {
        switch self {
        case .system: Color(nsColor: .controlAccentColor)
        case .purple: .indigo
        case .blue: .blue
        case .cyan: .cyan
        case .green: .green
        case .orange: .orange
        case .pink: .pink
        }
    }

    static func resolve(_ rawValue: String) -> AppAccent {
        AppAccent(rawValue: rawValue) ?? .purple
    }
}

enum AppAppearance {
    static func apply(_ rawValue: String) {
        NSApplication.shared.appearance = nsAppearance(for: rawValue)

        // Existing hosting windows can otherwise retain a stale effective
        // appearance after a forced light/dark mode is removed.
        for window in NSApplication.shared.windows {
            window.appearance = nil
            window.contentView?.needsDisplay = true
        }
    }

    private static func nsAppearance(for rawValue: String) -> NSAppearance? {
        switch rawValue {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: String(localized: "跟随系统")
        case .simplifiedChinese: String(localized: "简体中文")
        case .english: "English"
        }
    }

    static func applyForNextLaunch(_ rawValue: String) {
        let defaults = UserDefaults.standard
        guard let language = AppLanguage(rawValue: rawValue), language != .system else {
            defaults.removeObject(forKey: "AppleLanguages")
            return
        }
        defaults.set([language.rawValue], forKey: "AppleLanguages")
    }

    static func restartApplication() {
        guard let bundleURL = Bundle.main.bundleURL as URL? else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundleURL.path]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }
}
