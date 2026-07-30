struct PromptDefinition: Codable, Equatable {
    let key: String
    let type: PromptType
    let label: String?
    let defaultValue: String?
    let options: [PromptOption]?
    /// File patterns to detect. Accepts a single string or an array in YAML.
    /// Results are returned in pattern order (first pattern's matches first).
    let detectPatterns: [String]?
    let scriptCommand: String?

    enum CodingKeys: String, CodingKey {
        case key
        case type
        case label
        case defaultValue = "default"
        case options
        case detectPatterns = "detectPattern"
        case scriptCommand
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        type = try container.decode(PromptType.self, forKey: .type)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
        options = try container.decodeIfPresent([PromptOption].self, forKey: .options)
        scriptCommand = try container.decodeIfPresent(String.self, forKey: .scriptCommand)

        // detectPattern: accept String or [String]
        if container.contains(.detectPatterns) {
            if let array = try? container.decode([String].self, forKey: .detectPatterns) {
                detectPatterns = array
            } else if let single = try? container.decode(String.self, forKey: .detectPatterns) {
                detectPatterns = [single]
            } else {
                detectPatterns = nil
            }
        } else {
            detectPatterns = nil
        }
    }

    init(
        key: String,
        type: PromptType,
        label: String?,
        defaultValue: String?,
        options: [PromptOption]?,
        detectPatterns: [String]?,
        scriptCommand: String?
    ) {
        self.key = key
        self.type = type
        self.label = label
        self.defaultValue = defaultValue
        self.options = options
        self.detectPatterns = detectPatterns
        self.scriptCommand = scriptCommand
    }
}

enum PromptType: String, Codable {
    case fileDetect
    case input
    case select
    case script
}

struct PromptOption: Codable, Equatable {
    let value: String
    let label: String

    /// Find the index of the option whose `value` matches, returning 0 when absent.
    /// Used by single-select UIs to seed the cursor from a previously-stored answer.
    static func index(of value: String?, in options: [PromptOption]) -> Int {
        guard let value else { return 0 }
        return options.firstIndex { $0.value == value } ?? 0
    }
}
