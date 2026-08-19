import Foundation

@MainActor
final class SkillStore: ObservableObject {
    static let shared = SkillStore()

    @Published private(set) var skills: [UserSkill] = []
    @Published private(set) var lastError: String?

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    func save(_ skill: UserSkill) throws {
        if let index = skills.firstIndex(where: { $0.id == skill.id }) {
            skills[index] = skill
        } else {
            skills.insert(skill, at: 0)
        }
        try persist()
    }

    func delete(_ skill: UserSkill) throws {
        skills.removeAll { $0.id == skill.id }
        try persist()
    }

    private func load() {
        do {
            let url = try storageURL(createDirectory: false)
            guard fileManager.fileExists(atPath: url.path) else { return }
            let data = try Data(contentsOf: url)
            skills = try decoder.decode([UserSkill].self, from: data)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func persist() throws {
        do {
            let url = try storageURL(createDirectory: true)
            let data = try encoder.encode(skills)
            try data.write(to: url, options: .atomic)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func storageURL(createDirectory: Bool) throws -> URL {
        let baseURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: createDirectory
        )
        let directory = baseURL.appendingPathComponent("LocalAssistant/Skills", isDirectory: true)
        if createDirectory {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("skills.json")
    }
}
