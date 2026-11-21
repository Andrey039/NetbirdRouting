import Foundation

/// Disk errors are propagated; a broken existing file must never be reset to defaults.
final class PresetStore {
    let fileURL: URL
    private let defaults: UserDefaults

    init(fileURL: URL = PresetStore.defaultURL, defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.defaults = defaults
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NetbirdRouting", isDirectory: true)
            .appendingPathComponent("presets.json")
    }

    static let initialPresets = [
        Preset(name: "non-local",
               regex: "^10\\.|^100\\.64\\.|^192\\.168\\.|^172\\.(1[6-9]|2[0-9]|3[01])\\.", invert: true),
        Preset(name: "core-prod", regex: "core-prod", invert: false),
    ]

    func load() throws -> [Preset] {
        do {
            let presets = try JSONDecoder().decode([Preset].self, from: Data(contentsOf: fileURL))
            var names = Set<String>()
            for preset in presets where !names.insert(preset.name).inserted {
                throw StoreError.duplicateName(preset.name)
            }
            return presets
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            try save(Self.initialPresets)
            return Self.initialPresets
        }
    }

    private enum StoreError: LocalizedError {
        case duplicateName(String)
        var errorDescription: String? {
            switch self {
            case .duplicateName(let name): return "Duplicate preset name: «\(name)»"
            }
        }
    }

    private func save(_ presets: [Preset]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(presets)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    @discardableResult
    func upsert(_ preset: Preset) throws -> [Preset] {
        if let error = preset.validationError { throw InvalidPresetError(message: "Regex «\(preset.name)»: \(error)") }
        var presets = try load()
        let previous = presets.first { $0.name == preset.name }
        if let index = presets.firstIndex(where: { $0.name == preset.name }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        try save(presets)
        // A remembered selection belongs to the old filter, not just the name.
        if let previous, previous.regex != preset.regex || previous.invert != preset.invert {
            forgetDisabled(for: preset)
        }
        return presets
    }

    @discardableResult
    func remove(_ preset: Preset) throws -> [Preset] {
        let presets = try load().filter { $0.name != preset.name }
        try save(presets)
        forgetDisabled(for: preset)
        return presets
    }

    /// Array order is display order; moving never changes settings or remembered IDs.
    @discardableResult
    func move(_ preset: Preset, before targetName: String?) throws -> [Preset] {
        var presets = try load()
        let original = presets
        guard targetName != preset.name,
              let index = presets.firstIndex(where: { $0.name == preset.name }),
              targetName == nil || presets.contains(where: { $0.name == targetName }) else { return presets }
        let moved = presets.remove(at: index)
        let destination = targetName.flatMap { name in presets.firstIndex { $0.name == name } } ?? presets.endIndex
        presets.insert(moved, at: destination)
        guard presets != original else { return presets }
        try save(presets)
        return presets
    }

    private func disabledKey(_ preset: Preset) -> String { "disabledByPreset:" + preset.name }
    func disabledIDs(for preset: Preset) -> [String] {
        defaults.stringArray(forKey: disabledKey(preset)) ?? []
    }
    func rememberDisabled(_ ids: [String], for preset: Preset) {
        defaults.set(ids, forKey: disabledKey(preset))
    }
    func forgetDisabled(for preset: Preset) {
        defaults.removeObject(forKey: disabledKey(preset))
        forgetPending(for: preset)
    }

    private func pendingKey(_ preset: Preset) -> String { "pendingByPreset:" + preset.name }

    func pendingOperation(for preset: Preset) throws -> PresetOperation? {
        guard let data = defaults.data(forKey: pendingKey(preset)) else { return nil }
        return try JSONDecoder().decode(PresetOperation.self, from: data)
    }

    func savePending(_ operation: PresetOperation) throws {
        defaults.set(try JSONEncoder().encode(operation), forKey: pendingKey(operation.preset))
    }

    func forgetPending(for preset: Preset) {
        defaults.removeObject(forKey: pendingKey(preset))
    }

    /// Reconcile against the actual post-command selection, including partial failures.
    /// Returns an error message only when CLI reported success but its result disagrees.
    func reconcilePending(for preset: Preset, entries: [NetEntry]) throws -> String? {
        guard let operation = try pendingOperation(for: preset) else { return nil }
        guard operation.preset.hasSameRoutes(as: preset) else {
            forgetPending(for: preset)
            return nil
        }
        let selected = Set(entries.filter(\.selected).map(\.id))
        let targets = Set(operation.ids)
        let original = Set(operation.restoreBefore)
        let remaining = operation.enable
            ? original.union(targets).subtracting(selected)
            : original.union(targets.subtracting(selected))
        if remaining.isEmpty { defaults.removeObject(forKey: disabledKey(preset)) }
        else { rememberDisabled(remaining.sorted(), for: preset) }
        forgetPending(for: preset)
        let verified = operation.enable ? targets.isSubset(of: selected) : targets.isDisjoint(with: selected)
        return operation.commandSucceeded == true && !verified
            ? "NetBird не подтвердил изменение всех сетей пресета «\(preset.name)». Список восстановления сохранён." : nil
    }
}
