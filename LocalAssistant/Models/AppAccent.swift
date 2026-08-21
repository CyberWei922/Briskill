import AppKit
import SwiftUI

enum AppAccent: String, CaseIterable, Identifiable {
    case purple
    case blue
    case cyan
    case green
    case orange
    case pink

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .purple: "紫色"
        case .blue: "蓝色"
        case .cyan: "青色"
        case .green: "绿色"
        case .orange: "橙色"
        case .pink: "粉色"
        }
    }

    var color: Color {
        switch self {
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
