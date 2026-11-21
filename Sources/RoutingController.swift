import Foundation

/// Main-thread application state. UI controllers render it, never own routing state.
final class RoutingController {
    private let client: NetbirdRunning
    let store: PresetStore
    private(set) var entries: [NetEntry] = []
    private(set) var presets: [Preset] = []
    private(set) var connection: NetbirdConnection = .unknown
    var connected: Bool { connection == .connected }
    private(set) var lastRefreshAt: Date?
    private(set) var hasLoadedNetworks = false
    private(set) var isBusy = false
    private(set) var networkError: String?
    private(set) var connectionError: String?
    private(set) var presetError: String?
    private(set) var recoveryError: String?
    var onChange: (() -> Void)?
    var onCommandError: ((String) -> Void)?
    private enum Action {
        case command([String])
        case preset(Preset, revision: Int, enable: Bool)
    }
    private var pendingActions: [Action] = []
    private var revisions: [String: Int] = [:]
    private var timer: Timer?

    init(client: NetbirdRunning = NetbirdClient(), store: PresetStore = PresetStore()) {
        self.client = client
        self.store = store
        reloadPresets()
    }

    var important: Bool {
        hasActiveImportantPreset(presets, entries: entries, connected: connected)
    }

    var activeImportantNames: [String] {
        presets.filter { $0.highImportance && $0.isOn(in: entries) }.map(\.name)
    }

    var invalidPresetNames: [String] { presets.filter { $0.validationError != nil }.map(\.name) }

    var indicator: RoutingIndicator { indicator(at: Date()) }

    func indicator(at now: Date) -> RoutingIndicator {
        guard connection != .unknown, let lastRefreshAt,
              now.timeIntervalSince(lastRefreshAt) <= 20 else { return .unknown }
        guard presetError == nil, invalidPresetNames.isEmpty else { return .unknown }
        if connection == .disconnected { return .disconnected }
        guard hasLoadedNetworks, networkError == nil, recoveryError == nil else { return .unknown }
        return important ? .important : .normal
    }

    var statusDescription: String {
        switch indicator {
        case .normal: return "NetBird подключён • важных сетей нет"
        case .important: return "NetBird подключён • важные пресеты: " + activeImportantNames.joined(separator: ", ")
        case .disconnected: return "NetBird отключён"
        case .unknown:
            let reason = connectionError ?? networkError ?? presetError ?? recoveryError
                ?? (!invalidPresetNames.isEmpty ? "Ошибка regex: " + invalidPresetNames.joined(separator: ", ") : nil)
                ?? (lastRefreshAt == nil ? "Ожидание первого опроса" : "Данные устарели")
            return "Состояние неизвестно • " + reason
        }
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    func stop() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }

    func reloadPresets() {
        readPresets()
        onChange?()
    }

    private func adoptPresets(_ updated: [Preset]) {
        for name in Set(presets.map(\.name)).union(updated.map(\.name)) {
            let before = presets.first { $0.name == name }
            let after = updated.first { $0.name == name }
            let unchanged: Bool
            if let before, let after { unchanged = before.hasSameRoutes(as: after) }
            else { unchanged = false }
            if !unchanged {
                revisions[name, default: 0] += 1
                if let before { store.forgetDisabled(for: before) }
            }
        }
        presets = updated
    }

    private func readPresets() {
        do {
            adoptPresets(try store.load())
            presetError = nil
        } catch {
            // Keep last known presets and their importance instead of silently resetting.
            presetError = "presets.json: \(error.localizedDescription)"
        }
    }

    func savePreset(_ preset: Preset) throws {
        adoptPresets(try store.upsert(preset))
        presetError = nil
        onChange?()
    }

    func removePreset(_ preset: Preset) throws {
        adoptPresets(try store.remove(preset))
        presetError = nil
        onChange?()
    }

    func movePreset(_ preset: Preset, before targetName: String?) throws {
        adoptPresets(try store.move(preset, before: targetName))
        presetError = nil
        onChange?()
    }

    /// Apply the network list and connection result together, not as mixed-age state.
    func refresh() {
        guard !isBusy else { onChange?(); return } // Also repaint stale state during a long operation.
        isBusy = true
        onChange?()
        client.run(["networks", "list"]) { [weak self] networks in
            guard let self else { return }
            self.client.run(["status", "--json"]) { [weak self] status in
                guard let self else { return }
                do {
                    guard networks.succeeded else {
                        throw NetworkListError(detail: "CLI (\(networks.code)): \(networks.output.prefix(200))")
                    }
                    self.entries = try parseNetworks(networks.output)
                    self.hasLoadedNetworks = true
                    self.networkError = nil
                } catch {
                    self.entries = []
                    self.hasLoadedNetworks = false
                    self.networkError = error.localizedDescription
                }
                self.connection = status.succeeded ? parseNetbirdConnection(status.output) : .unknown
                self.connectionError = self.connection == .unknown
                    ? (status.succeeded ? "Не удалось разобрать статус NetBird" : "netbird status (\(status.code)): \(status.output.prefix(200))") : nil
                if self.connection != .unknown { self.lastRefreshAt = Date() }
                self.readPresets()
                let warnings = self.hasLoadedNetworks && self.presetError == nil ? self.reconcileOperations() : []
                self.isBusy = false
                self.onChange?()
                for warning in warnings { self.onCommandError?(warning) }
                self.runNextAction()
            }
        }
    }

    func perform(_ arguments: [String]) {
        enqueue(.command(arguments))
    }

    func togglePreset(_ preset: Preset, enable: Bool) {
        enqueue(.preset(preset, revision: revisions[preset.name, default: 0], enable: enable))
    }

    private func applyPreset(_ preset: Preset, revision: Int, enable: Bool) {
        readPresets() // Also detect edits made by another process or in presets.json.
        if let presetError { onCommandError?(presetError); return }
        guard revisions[preset.name] == revision,
              let current = presets.first(where: { $0.name == preset.name }), current.hasSameRoutes(as: preset) else {
            onCommandError?("Пресет «\(preset.name)» изменён или удалён. Ожидавшее действие отменено; повторите его для текущих настроек.")
            return
        }
        guard hasLoadedNetworks else {
            onCommandError?("Сети не загружены. Обновите данные и повторите действие.")
            return
        }
        if let error = current.validationError { onCommandError?("Regex «\(current.name)»: \(error)"); return }
        do {
            guard try store.pendingOperation(for: current) == nil else {
                onCommandError?("Предыдущая операция «\(current.name)» ещё не проверена. Сначала обновите данные.")
                return
            }
            let filter = current.filter
            let matching = entries.filter { filter.matches($0) }
            let remembered = store.disabledIDs(for: current)
            let ids: [String]
            if enable {
                if remembered.isEmpty {
                    ids = matching.map(\.id)
                } else {
                    let saved = Set(remembered)
                    ids = matching.filter { saved.contains($0.id) }.map(\.id)
                    guard !ids.isEmpty else {
                        onCommandError?("Сохранённые сети пресета «\(current.name)» не найдены. Автоматическое включение других сетей отменено. Проверьте фильтр и доступные сети.")
                        return
                    }
                }
            } else {
                ids = matching.filter(\.selected).map(\.id)
            }
            guard !ids.isEmpty else { return }
            let operation = PresetOperation(preset: current, enable: enable, ids: ids, restoreBefore: remembered)
            try store.savePending(operation)
            let base = enable ? ["networks", "select", "-a"] : ["networks", "deselect"]
            execute(base + ids, operation: operation, revision: revision)
        } catch {
            recoveryError = error.localizedDescription
            onChange?()
            onCommandError?("Не удалось подготовить операцию: \(error.localizedDescription)")
        }
    }

    private func reconcileOperations() -> [String] {
        var notifications: [String] = []
        var errors: [String] = []
        for preset in presets {
            do {
                if let warning = try store.reconcilePending(for: preset, entries: entries) {
                    notifications.append(warning)
                    errors.append(warning)
                }
            } catch { errors.append("Список восстановления «\(preset.name)»: \(error.localizedDescription)") }
        }
        recoveryError = errors.first
        return notifications
    }

    private func enqueue(_ action: Action) {
        pendingActions.append(action)
        if !isBusy {
            if !hasLoadedNetworks { refresh() } else { runNextAction() }
        }
    }

    private func runNextAction() {
        while !isBusy, !pendingActions.isEmpty {
            switch pendingActions.removeFirst() {
            case .command(let arguments): execute(arguments)
            case .preset(let preset, let revision, let enable): applyPreset(preset, revision: revision, enable: enable)
            }
        }
    }

    private func execute(_ arguments: [String], operation: PresetOperation? = nil, revision: Int? = nil) {
        isBusy = true
        recoveryError = nil
        onChange?()
        client.run(arguments) { [weak self] result in
            guard let self else { return }
            if var operation {
                self.readPresets()
                do {
                    // Never let an old completion resurrect invalidated state after an edit/delete.
                    if self.presetError == nil, self.revisions[operation.preset.name] == revision,
                       let pending = try self.store.pendingOperation(for: operation.preset), pending.id == operation.id {
                        operation.commandSucceeded = result.succeeded
                        try self.store.savePending(operation)
                    }
                } catch { self.recoveryError = error.localizedDescription }
            }
            self.isBusy = false
            // Refresh after failures too: the CLI may have partially applied a batch.
            self.refresh()
            if !result.succeeded {
                self.onCommandError?("netbird CLI (\(result.code)): \(result.output.prefix(600))")
            }
        }
    }
}
