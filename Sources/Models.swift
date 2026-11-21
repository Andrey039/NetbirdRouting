import Foundation

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct NetEntry: Equatable {
    let id: String
    let info: String
    let selected: Bool
}

/// Compile once per filter, not once per field of every network.
struct NetworkFilter {
    let pattern: String
    let invert: Bool
    private let expression: NSRegularExpression?
    let validationError: String?

    init(_ pattern: String, invert: Bool = false) {
        self.pattern = pattern
        self.invert = invert
        // Empty Manager filter means "show all"; empty preset regex is rejected separately.
        if pattern.isEmpty {
            expression = nil
            validationError = nil
            return
        }
        do {
            expression = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            validationError = nil
        } catch {
            expression = nil
            validationError = error.localizedDescription
        }
    }

    func matches(_ text: String) -> Bool {
        guard validationError == nil else { return false }
        if pattern.isEmpty { return true }
        guard let expression else { return false }
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    func matches(_ entry: NetEntry) -> Bool {
        // An invalid inverted regex must not accidentally select every network.
        guard validationError == nil else { return false }
        let matched = matches(entry.id) || matches(entry.info)
        return invert ? !matched : matched
    }
}

struct Preset: Codable, Equatable {
    let name: String
    let regex: String
    let invert: Bool
    let highImportance: Bool

    init(name: String, regex: String, invert: Bool, highImportance: Bool = false) {
        self.name = name
        self.regex = regex
        self.invert = invert
        self.highImportance = highImportance
    }

    enum CodingKeys: String, CodingKey { case name, regex, invert, highImportance }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        regex = try values.decode(String.self, forKey: .regex)
        invert = try values.decode(Bool.self, forKey: .invert)
        highImportance = try values.decodeIfPresent(Bool.self, forKey: .highImportance) ?? false
    }

    var filter: NetworkFilter { NetworkFilter(regex, invert: invert) }

    var validationError: String? {
        regex.isEmpty ? "Regex не должен быть пустым" : filter.validationError
    }

    func hasSameRoutes(as other: Preset) -> Bool {
        name == other.name && regex == other.regex && invert == other.invert
    }

    func isOn(in entries: [NetEntry]) -> Bool {
        let matcher = filter
        return entries.contains { $0.selected && matcher.matches($0) }
    }
}

func hasActiveImportantPreset(_ presets: [Preset], entries: [NetEntry], connected: Bool) -> Bool {
    connected && presets.contains { $0.highImportance && $0.isOn(in: entries) }
}

func netbirdIsConnected(_ text: String) -> Bool {
    parseNetbirdConnection(text) == .connected
}

enum NetbirdConnection: Equatable { case unknown, disconnected, connected }
enum RoutingIndicator: CaseIterable, Hashable { case normal, important, disconnected, unknown }

func parseNetbirdConnection(_ text: String) -> NetbirdConnection {
    struct Status: Decodable {
        struct Management: Decodable { let connected: Bool }
        let management: Management?
        let daemonStatus: String?
    }
    guard let data = text.data(using: .utf8),
          let status = try? JSONDecoder().decode(Status.self, from: data) else { return .unknown }
    if let daemonStatus = status.daemonStatus {
        switch daemonStatus {
        case "Disconnected", "Connecting", "NeedsLogin", "Idle": return .disconnected
        case "Connected": return status.management?.connected == true ? .connected : .unknown
        default: return .unknown
        }
    }
    guard let management = status.management else { return .unknown }
    return management.connected ? .connected : .disconnected
}

struct InvalidPresetError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct NetworkListError: LocalizedError {
    let detail: String
    var errorDescription: String? { "Не удалось разобрать список сетей NetBird: " + detail }
}

/// Validate complete records; never confuse an unknown response with an empty list.
/// Format and empty sentinel match NetBird 0.82.1 client/cmd/networks.go.
func parseNetworks(_ text: String) throws -> [NetEntry] {
    let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    if lines == ["No networks available."] { return [] }
    guard !lines.isEmpty else { throw NetworkListError(detail: "пустой ответ") }
    var entries: [NetEntry] = []
    var seenIDs = Set<String>()
    var currentID: String?
    var currentInfo: String?
    var currentSelected: Bool?
    var resolvedIPs = false
    var sawHeader = false

    func flush() throws {
        if let id = currentID {
            guard !id.isEmpty, let info = currentInfo, !info.isEmpty, let selected = currentSelected,
                  seenIDs.insert(id).inserted else { throw NetworkListError(detail: "неполная или повторная запись «\(id)»") }
            entries.append(NetEntry(id: id, info: info, selected: selected))
        }
        currentID = nil
        currentInfo = nil
        currentSelected = nil
        resolvedIPs = false
    }

    for line in lines {
        if line == "Available Networks:", !sawHeader, currentID == nil, entries.isEmpty {
            sawHeader = true
        } else if line.hasPrefix("- ID: ") {
            try flush()
            currentID = String(line.dropFirst("- ID: ".count))
        } else if line.hasPrefix("Network: "), currentID != nil, currentInfo == nil {
            currentInfo = String(line.dropFirst("Network: ".count))
        } else if line.hasPrefix("Domains: "), currentID != nil, currentInfo == nil {
            currentInfo = String(line.dropFirst("Domains: ".count))
        } else if line.hasPrefix("Status: "), currentID != nil, currentSelected == nil {
            switch line.dropFirst("Status: ".count) {
            case "Selected": currentSelected = true
            case "Not Selected": currentSelected = false
            default: throw NetworkListError(detail: "неизвестный статус «\(line)»")
            }
        } else if (line == "Resolved IPs:" || line == "Resolved IPs: -"), currentID != nil, currentSelected != nil, !resolvedIPs {
            resolvedIPs = true
        } else if resolvedIPs, line.hasPrefix("["), line.contains("]: ") {
            continue // Domain -> IP mapping is not needed to select network IDs.
        } else {
            throw NetworkListError(detail: "неизвестная строка «\(line.prefix(120))»")
        }
    }
    try flush()
    guard !entries.isEmpty else { throw NetworkListError(detail: "нет записей и нет подтверждения пустого списка") }
    return entries
}

/// Written before invoking the CLI; recovery never replays a network command.
struct PresetOperation: Codable {
    let id: UUID
    let preset: Preset
    let enable: Bool
    let ids: [String]
    let restoreBefore: [String]
    var commandSucceeded: Bool?

    init(preset: Preset, enable: Bool, ids: [String], restoreBefore: [String]) {
        id = UUID()
        self.preset = preset
        self.enable = enable
        self.ids = ids
        self.restoreBefore = restoreBefore
    }
}
