import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class PrivacyPermissionCenter: ObservableObject {
    static let shared = PrivacyPermissionCenter()

    @Published private(set) var accessibilityGranted = false
    @Published private(set) var screenRecordingGranted = false

    private init() {
        refresh()
    }

    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    func requestAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        scheduleRefresh()
        AppConsole.shared.info("已请求辅助功能权限", category: "Privacy")
    }

    func requestScreenRecording() {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        refresh()
        scheduleRefresh()
        AppConsole.shared.info("已请求屏幕录制权限", category: "Privacy")
    }

    func openAccessibilitySettings() {
        openPrivacyPane(anchor: "Privacy_Accessibility")
    }

    func openScreenRecordingSettings() {
        openPrivacyPane(anchor: "Privacy_ScreenCapture")
    }

    private func scheduleRefresh() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            refresh()
            try? await Task.sleep(for: .seconds(2))
            refresh()
        }
    }

    private func openPrivacyPane(anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

struct AuthorizedLocationRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var originalPath: String
    var bookmarkData: Data
}

struct ResolvedAuthorizedLocation {
    let url: URL
    private let didStartSecurityScope: Bool

    init(url: URL, didStartSecurityScope: Bool) {
        self.url = url
        self.didStartSecurityScope = didStartSecurityScope
    }

    func stopAccessing() {
        if didStartSecurityScope {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

@MainActor
final class AuthorizedLocationStore: ObservableObject {
    static let shared = AuthorizedLocationStore()

    @Published private(set) var locations: [AuthorizedLocationRecord] = []

    private let defaults = UserDefaults.standard
    private let storageKey = "privacy.authorizedLocations"

    private init() {
        load()
    }

    func add(_ url: URL) throws {
        let standardizedURL = url.standardizedFileURL
        let bookmark = try standardizedURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.nameKey, .isDirectoryKey],
            relativeTo: nil
        )
        let record = AuthorizedLocationRecord(
            id: UUID(),
            displayName: standardizedURL.lastPathComponent,
            originalPath: standardizedURL.path,
            bookmarkData: bookmark
        )
        locations.removeAll { $0.originalPath == record.originalPath }
        locations.append(record)
        locations.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        persist()
        AppConsole.shared.success("已保存文件访问位置：\(standardizedURL.path)", category: "Privacy")
    }

    func remove(_ record: AuthorizedLocationRecord) {
        locations.removeAll { $0.id == record.id }
        persist()
        AppConsole.shared.info("已移除文件访问位置：\(record.originalPath)", category: "Privacy")
    }

    func removeAll() {
        locations = []
        persist()
        AppConsole.shared.info("已清除全部持久文件访问位置", category: "Privacy")
    }

    func beginAccessingLocations() -> [ResolvedAuthorizedLocation] {
        locations.compactMap { record in
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: record.bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { return nil }
            let didStart = url.startAccessingSecurityScopedResource()
            return ResolvedAuthorizedLocation(url: url, didStartSecurityScope: didStart)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([AuthorizedLocationRecord].self, from: data) else {
            return
        }
        locations = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(locations) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
