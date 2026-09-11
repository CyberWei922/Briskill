import AppKit
import Foundation

struct BriskillRelease: Equatable {
    let version: String
    let name: String
    let pageURL: URL
}

enum BriskillUpdateStatus: Equatable {
    case idle
    case checking
    case upToDate(latestVersion: String)
    case updateAvailable(BriskillRelease)
    case unavailable(String)
}

@MainActor
final class BriskillUpdateChecker: ObservableObject {
    static let shared = BriskillUpdateChecker()

    static let projectURL = URL(string: "https://github.com/CyberWei922/Briskill")!
    static let changelogURL = projectURL.appendingPathComponent("blob/main/CHANGELOG.md")

    @Published private(set) var status: BriskillUpdateStatus = .idle

    private let automaticChecksKey = "updates.automaticChecksEnabled"
    private let lastCheckKey = "updates.lastCheckDate"
    private let latestReleaseEndpoint = URL(
        string: "https://api.github.com/repos/CyberWei922/Briskill/releases/latest"
    )!

    private init() {}

    var automaticChecksEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: automaticChecksKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: automaticChecksKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: automaticChecksKey) }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    func checkAutomaticallyIfNeeded() async {
        guard automaticChecksEnabled else { return }
        if let lastCheck = UserDefaults.standard.object(forKey: lastCheckKey) as? Date,
           Date().timeIntervalSince(lastCheck) < 24 * 60 * 60 {
            return
        }
        await checkForUpdates()
    }

    func checkForUpdates() async {
        guard status != .checking else { return }
        status = .checking

        var request = URLRequest(url: latestReleaseEndpoint)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Briskill/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw UpdateCheckError.invalidResponse
            }
            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode == 404 {
                    status = .unavailable(String(localized: "还没有可用于检查更新的 GitHub Release。"))
                    return
                }
                throw UpdateCheckError.httpStatus(httpResponse.statusCode)
            }

            let payload = try JSONDecoder().decode(GitHubReleasePayload.self, from: data)
            guard let pageURL = URL(string: payload.htmlURL) else {
                throw UpdateCheckError.invalidResponse
            }
            let releaseVersion = Self.normalizedVersion(payload.tagName)
            let releaseName = payload.name?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            let release = BriskillRelease(
                version: releaseVersion,
                name: releaseName ?? payload.tagName,
                pageURL: pageURL
            )
            status = Self.isVersion(releaseVersion, newerThan: currentVersion)
                ? .updateAvailable(release)
                : .upToDate(latestVersion: releaseVersion)
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
            AppConsole.shared.info("检查更新完成：最新版本 \(releaseVersion)", category: "Update")
        } catch {
            status = .unavailable(error.localizedDescription)
            AppConsole.shared.error("检查更新失败：\(error.localizedDescription)", category: "Update")
        }
    }

    func openProjectPage() {
        NSWorkspace.shared.open(Self.projectURL)
    }

    func openChangelog() {
        NSWorkspace.shared.open(Self.changelogURL)
    }

    func openRelease(_ release: BriskillRelease) {
        NSWorkspace.shared.open(release.pageURL)
    }

    private static func normalizedVersion(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    private static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let candidateParts = numericVersionParts(candidate)
        let currentParts = numericVersionParts(current)
        let count = max(candidateParts.count, currentParts.count)
        for index in 0..<count {
            let left = index < candidateParts.count ? candidateParts[index] : 0
            let right = index < currentParts.count ? currentParts[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func numericVersionParts(_ version: String) -> [Int] {
        version.split(separator: ".").map { component in
            Int(component.prefix(while: { $0.isNumber })) ?? 0
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct GitHubReleasePayload: Decodable {
    let tagName: String
    let name: String?
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
    }
}

private enum UpdateCheckError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            String(localized: "更新服务器返回了无法识别的数据。")
        case .httpStatus(let code):
            String(format: String(localized: "更新服务器返回错误（HTTP %lld）。"), code)
        }
    }
}
