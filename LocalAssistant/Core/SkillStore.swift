import Foundation

struct LocalAssistantSkillPackage: Codable {
    static let formatIdentifier = "com.localassistant.skill"
    static let currentSchemaVersion = 1

    let format: String
    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String
    let skill: UserSkill
}

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
        let previousSkills = skills
        if let index = skills.firstIndex(where: { $0.id == skill.id }) {
            skills[index] = skill
        } else {
            skills.insert(skill, at: 0)
        }
        do {
            try persist()
        } catch {
            skills = previousSkills
            throw error
        }
        AppConsole.shared.success("技能已保存：\(skill.name)（\(skill.id.uuidString)）", category: "SkillStore")
    }

    func delete(_ skill: UserSkill) throws {
        let previousSkills = skills
        skills.removeAll { $0.id == skill.id }
        do {
            try persist()
        } catch {
            skills = previousSkills
            throw error
        }
        AppConsole.shared.warning("技能已删除：\(skill.name)", category: "SkillStore")
    }

    func exportPackageData(for skill: UserSkill) throws -> Data {
        let package = LocalAssistantSkillPackage(
            format: LocalAssistantSkillPackage.formatIdentifier,
            schemaVersion: LocalAssistantSkillPackage.currentSchemaVersion,
            exportedAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            skill: skill
        )
        let data = try encoder.encode(package)
        AppConsole.shared.info("已生成技能导出包：\(skill.name)，字节数=\(data.count)", category: "SkillStore")
        return data
    }

    private func load() {
        do {
            let url = try storageURL(createDirectory: false)
            guard fileManager.fileExists(atPath: url.path) else { return }
            let data = try Data(contentsOf: url)
            skills = try decoder.decode([UserSkill].self, from: data)
            lastError = nil
            AppConsole.shared.info("已加载 \(skills.count) 个本地技能", category: "SkillStore")
        } catch {
            lastError = error.localizedDescription
            AppConsole.shared.error("本地技能加载失败：\(error.localizedDescription)", category: "SkillStore")
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
            AppConsole.shared.error("本地技能写入失败：\(error.localizedDescription)", category: "SkillStore")
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
