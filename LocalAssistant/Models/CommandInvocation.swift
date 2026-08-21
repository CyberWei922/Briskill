import Foundation

enum InvocationCondition: String, CaseIterable, Hashable {
    case clear = "-clear"
}

struct InvocationOptions: Equatable {
    var conditions: Set<InvocationCondition> = []

    static let standard = InvocationOptions()

    var savesHistory: Bool {
        !conditions.contains(.clear)
    }
}

struct ParsedCommandArguments: Equatable {
    var values: [String: String]
    var fileURLs: [String: URL]
    var options: InvocationOptions

    static let empty = ParsedCommandArguments(
        values: [:],
        fileURLs: [:],
        options: .standard
    )
}

enum CommandInvocationParser {
    static func parse(
        _ rawArguments: String,
        parameters: [SkillParameterDefinition],
        suppliedParameterIDs: Set<String> = []
    ) -> ParsedCommandArguments {
        var tokens = tokenize(rawArguments)
        var conditions = Set<InvocationCondition>()

        while let last = tokens.last,
              !last.wasQuoted,
              let condition = InvocationCondition(rawValue: last.value.lowercased()) {
            conditions.insert(condition)
            tokens.removeLast()
        }

        var values: [String: String] = [:]
        var fileURLs: [String: URL] = [:]
        var tokenIndex = 0

        for (parameterIndex, parameter) in parameters.enumerated() {
            if suppliedParameterIDs.contains(parameter.id) {
                continue
            }
            guard tokenIndex < tokens.count else { break }

            if parameter.type == .paragraph {
                let remainingParameters = parameters[(parameterIndex + 1)...]
                let tokensToReserve = remainingParameters.reduce(into: 0) { count, parameter in
                    if parameter.required, !suppliedParameterIDs.contains(parameter.id) { count += 1 }
                }
                let availableCount = tokens.count - tokenIndex
                let consumedCount = max(1, availableCount - tokensToReserve)
                let endIndex = min(tokenIndex + consumedCount, tokens.count)
                values[parameter.id] = tokens[tokenIndex..<endIndex]
                    .map(\.value)
                    .joined(separator: " ")
                tokenIndex = endIndex
                continue
            }

            let token = tokens[tokenIndex]
            tokenIndex += 1
            if parameter.type.acceptsFiles {
                let expanded = (token.value as NSString).expandingTildeInPath
                let url = URL(fileURLWithPath: expanded).standardizedFileURL
                if FileManager.default.fileExists(atPath: url.path) {
                    fileURLs[parameter.id] = url
                }
            } else {
                values[parameter.id] = token.value
            }
        }

        return ParsedCommandArguments(
            values: values,
            fileURLs: fileURLs,
            options: InvocationOptions(conditions: conditions)
        )
    }

    private static func tokenize(_ input: String) -> [CommandToken] {
        var tokens: [CommandToken] = []
        var current = ""
        var quote: Character?
        var currentWasQuoted = false
        var isEscaping = false

        func appendCurrentToken() {
            guard !current.isEmpty else { return }
            tokens.append(CommandToken(value: current, wasQuoted: currentWasQuoted))
            current = ""
            currentWasQuoted = false
        }

        for character in input {
            if isEscaping {
                current.append(character)
                isEscaping = false
                continue
            }
            if character == "\\" {
                isEscaping = true
                continue
            }
            if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                    currentWasQuoted = true
                } else {
                    current.append(character)
                }
                continue
            }
            if character.isWhitespace, quote == nil {
                appendCurrentToken()
            } else {
                current.append(character)
            }
        }
        if isEscaping { current.append("\\") }
        appendCurrentToken()
        return tokens
    }
}

private struct CommandToken: Equatable {
    let value: String
    let wasQuoted: Bool
}
