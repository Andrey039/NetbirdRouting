import AppKit

final class TrayController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let routing: RoutingController
    private let manager: ManagerController
    private let titles = Dictionary(uniqueKeysWithValues: RoutingIndicator.allCases.map { ($0, trayLetterRTitle(state: $0)) })
    private weak var countsItem: NSMenuItem?
    private weak var connectionItem: NSMenuItem?

    init(routing: RoutingController, manager: ManagerController) {
        self.routing = routing
        self.manager = manager
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        render()
    }

    func render() {
        statusItem.button?.image = nil
        statusItem.button?.attributedTitle = titles[routing.indicator]!
        statusItem.button?.toolTip = routing.statusDescription
        connectionItem?.title = routing.statusDescription
        countsItem?.title = routing.networkError == nil
            ? "Enabled: \(routing.entries.filter(\.selected).count)/\(routing.entries.count)" : "Сети недоступны"
        // Update existing views in place. Never rebuild an open menu under the pointer.
        for item in statusItem.menu?.items ?? [] {
            guard let row = item.view as? PresetRowView,
                  let index = routing.presets.firstIndex(where: { $0.name == row.presetName }) else { continue }
            let preset = routing.presets[index]
            row.toggleSwitch.isOn = preset.isOn(in: routing.entries)
            row.toggleSwitch.isEnabled = routing.hasLoadedNetworks && preset.validationError == nil
            row.showValidationError(preset.validationError)
        }
    }

    @objc private func openManager() { manager.show() }
    @objc private func refresh() { routing.reloadPresets(); routing.refresh() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        routing.reloadPresets()
        routing.refresh()
        menu.removeAllItems()
        let title = NSMenuItem(title: "NetBird Routing", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let connection = NSMenuItem(title: routing.statusDescription, action: nil, keyEquivalent: "")
        connection.isEnabled = false
        connectionItem = connection
        menu.addItem(connection)
        let counts = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        counts.isEnabled = false
        countsItem = counts
        menu.addItem(counts)
        if let error = routing.presetError {
            let errorItem = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }
        menu.addItem(.separator())
        addItem("Open manager…", action: #selector(openManager), to: menu)
        addItem("Refresh", action: #selector(refresh), key: "r", to: menu)
        if !routing.presets.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for preset in routing.presets {
                let row = PresetRowView(preset: preset, isOn: preset.isOn(in: routing.entries), target: self,
                                        toggleAction: #selector(togglePreset(_:)), deleteAction: #selector(deletePreset(_:)),
                                        editAction: #selector(editPreset(_:)))
                row.dragHandle.onDrag = { [weak self, weak row] point, finished in
                    guard let self, let row,
                          let current = self.routing.presets.first(where: { $0.name == row.presetName }) else { return }
                    self.dragPreset(current, at: point, finished: finished)
                }
                row.dragHandle.onCancel = { [weak self] in self?.clearInsertionMarker() }
                let item = NSMenuItem()
                item.view = row
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        render()
    }

    private func addItem(_ title: String, action: Selector, key: String = "", to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    // Names are stable identities. Array indices become incorrect after reload/delete.
    private func preset(for control: NSControl) -> Preset? {
        guard let row = control.superview as? PresetRowView else { return nil }
        return routing.presets.first { $0.name == row.presetName }
    }

    @objc private func togglePreset(_ sender: ToggleSwitch) {
        guard let preset = preset(for: sender) else { return }
        routing.togglePreset(preset, enable: sender.isOn)
    }

    @objc private func editPreset(_ sender: IconButton) {
        guard let preset = preset(for: sender) else { return }
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in self?.manager.editPreset(preset) }
    }

    private var presetRows: [PresetRowView] {
        statusItem.menu?.items.compactMap { $0.view as? PresetRowView } ?? []
    }

    private func clearInsertionMarker() {
        for row in presetRows { row.insertionEdge = nil }
    }

    private func dragPreset(_ preset: Preset, at point: NSPoint, finished: Bool) {
        let rows = presetRows
        let frames = rows.compactMap { row -> (name: String, frame: NSRect)? in
            guard let window = row.window else { return nil }
            return (row.presetName, window.convertToScreen(row.convert(row.bounds, to: nil)))
        }
        clearInsertionMarker()
        guard let target = PresetDropTarget.at(point, rows: frames) else { return }
        let targetName: String?
        switch target {
        case .before(let name):
            targetName = name
            rows.first { $0.presetName == name }?.insertionEdge = .maxY
        case .end:
            targetName = nil
            rows.last?.insertionEdge = .minY
        }
        guard finished else { return }
        // mouseUp has been consumed. Rebind contents in the existing menu slots:
        // no cancelTracking, item removal, relayout, or stale preset captures.
        // Run synchronously: main-queue work may wait until menu tracking ends.
        do {
            try routing.movePreset(preset, before: targetName)
            PresetRowView.applyOrder(routing.presets, to: rows, entries: routing.entries)
            render()
        } catch {
            // Only a persistence failure requires leaving the menu for an alert.
            clearInsertionMarker()
            statusItem.menu?.cancelTracking()
            DispatchQueue.main.async { [weak self] in self?.manager.showError(error.localizedDescription) }
        }
    }

    @objc private func deletePreset(_ sender: IconButton) {
        guard let preset = preset(for: sender) else { return }
        do {
            try routing.removePreset(preset)
        } catch {
            statusItem.menu?.cancelTracking()
            DispatchQueue.main.async { [weak self] in self?.manager.showError(error.localizedDescription) }
            return
        }
        // Removing the menu item can move Quit underneath the pointer on mouseUp.
        if let item = statusItem.menu?.items.first(where: { $0.view === sender.superview }) {
            item.view = nil
            item.title = "«\(preset.name)» — удалён"
            item.isEnabled = false
        }
    }
}
