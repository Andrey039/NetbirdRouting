import AppKit

final class ManagerController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let window: NSWindow
    private let routing: RoutingController
    private let tableView = NSTableView()
    private let filterField = NSTextField()
    private let invertCheck = NSButton(checkboxWithTitle: "Invert", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private var filtered: [NetEntry] = []
    private var selectedResourceIDs = Set<String>()
    private var restoringSelection = false

    init(routing: RoutingController) {
        self.routing = routing
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "NetBird Routing — networks"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1000, height: 350)
        window.center()
        buildInterface()
        render()
    }

    private func buildInterface() {
        guard let content = window.contentView else { return }
        filterField.placeholderString = "Regex filter, e.g. core-prod|10\\.236\\..*"
        filterField.stringValue = UserDefaults.standard.string(forKey: "regexFilter") ?? ""
        filterField.delegate = self
        invertCheck.state = UserDefaults.standard.bool(forKey: "invertFilter") ? .on : .off
        invertCheck.target = self
        invertCheck.action = #selector(filterChanged)
        let filterRow = NSStackView(views: [filterField, invertCheck])
        filterRow.spacing = 8

        let buttons = NSStackView(views: [
            button("Refresh", #selector(refresh)), button("Select visible", #selector(selectVisible)),
            button("Clear", #selector(clearSelection)), button("Enable selected", #selector(enableSelected)),
            button("Disable selected", #selector(disableSelected)), button("Disable ALL", #selector(disableAll)),
            button("Enable ALL", #selector(enableAll)), button("Save preset…", #selector(savePresetAs)),
        ])
        buttons.spacing = 8

        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 20
        for (id, title, width) in [("id", "Resource ID", 440.0), ("net", "Network / Domains", 300.0), ("state", "Status", 110.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = tableView
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        for view in [filterRow, buttons, scroll, statusLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            filterRow.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            filterRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            filterRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.topAnchor.constraint(equalTo: filterRow.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        routing.refresh()
    }

    @objc private func refresh() { routing.reloadPresets(); routing.refresh() }
    func controlTextDidChange(_ notification: Notification) { filterChanged() }

    @objc private func filterChanged() {
        UserDefaults.standard.set(filterField.stringValue, forKey: "regexFilter")
        UserDefaults.standard.set(invertCheck.state == .on, forKey: "invertFilter")
        render()
    }

    func render() {
        let filter = NetworkFilter(filterField.stringValue, invert: invertCheck.state == .on)
        filterField.textColor = filter.validationError == nil ? .textColor : .systemRed
        filterField.toolTip = filter.validationError
        filtered = routing.entries.filter { filter.matches($0) }
        // reloadData emits selection notifications: don't let them erase saved IDs.
        restoringSelection = true
        tableView.reloadData()
        let indices = IndexSet(filtered.enumerated().compactMap { selectedResourceIDs.contains($0.element.id) ? $0.offset : nil })
        tableView.selectRowIndexes(indices, byExtendingSelection: false)
        restoringSelection = false
        updateStatus()
    }

    private func updateStatus() {
        let filterError = NetworkFilter(filterField.stringValue).validationError.map { "Ошибка regex: " + $0 }
        let error = filterError ?? routing.networkError ?? routing.presetError
        let summary = "\(routing.entries.count) networks • \(routing.entries.filter(\.selected).count) enabled • \(filtered.count) shown • \(tableView.selectedRowIndexes.count) selected"
        statusLabel.stringValue = error ?? (routing.isBusy ? "Updating… • " + summary : summary)
        statusLabel.textColor = error == nil ? .secondaryLabelColor : .systemRed
        statusLabel.toolTip = error
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !restoringSelection else { return }
        selectedResourceIDs = Set(selectedIDs)
        updateStatus()
    }

    private var selectedIDs: [String] {
        tableView.selectedRowIndexes.compactMap { filtered[safe: $0]?.id }.sorted()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let entry = filtered[safe: row] else { return nil }
        let label: NSTextField
        switch tableColumn?.identifier.rawValue {
        case "id": label = NSTextField(labelWithString: entry.id)
        case "net": label = NSTextField(labelWithString: entry.info)
        case "state":
            label = NSTextField(labelWithString: entry.selected ? "● enabled" : "○ disabled")
            label.textColor = entry.selected ? .systemGreen : .secondaryLabelColor
        default: return nil
        }
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = label.stringValue
        return label
    }

    @objc private func selectVisible() {
        tableView.selectRowIndexes(IndexSet(integersIn: 0..<filtered.count), byExtendingSelection: false)
    }
    @objc private func clearSelection() { selectedResourceIDs.removeAll(); tableView.deselectAll(nil) }
    @objc private func enableSelected() {
        guard !selectedIDs.isEmpty else { return }
        routing.perform(["networks", "select", "-a"] + selectedIDs)
    }
    @objc private func disableSelected() {
        guard !selectedIDs.isEmpty else { return }
        routing.perform(["networks", "deselect"] + selectedIDs)
    }
    @objc private func enableAll() { routing.perform(["networks", "select", "all"]) }
    @objc private func disableAll() {
        let alert = NSAlert()
        alert.messageText = "Deselect ALL networks?"
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { routing.perform(["networks", "deselect", "all"]) }
    }

    @objc private func savePresetAs() { editPreset(nil) }

    func editPreset(_ existing: Preset?) {
        let alert = NSAlert()
        alert.messageText = existing == nil ? "Save current filter as preset" : "Preset settings"
        alert.informativeText = "Высокая важность: R станет красной при подключённом NetBird, если включена хотя бы одна сеть пресета."
        let save = alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let editor = PresetEditorView(existing: existing, regex: filterField.stringValue,
                                      invert: invertCheck.state == .on, entries: routing.entries, saveButton: save)
        alert.accessoryView = editor
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let preset = editor.preset
        let trimmedName = preset.name
        guard !trimmedName.isEmpty, preset.validationError == nil else {
            showError(preset.validationError ?? "Введите имя пресета")
            return
        }
        // Do not silently replace a different existing preset with the same name.
        if existing == nil, routing.presets.contains(where: { $0.name == trimmedName }) {
            let replace = NSAlert()
            replace.messageText = "Replace preset «\(trimmedName)»?"
            replace.addButton(withTitle: "Replace")
            replace.addButton(withTitle: "Cancel")
            guard replace.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            try routing.savePreset(preset)
        } catch { showError("Could not save presets.json: \(error.localizedDescription)") }
    }

    func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "NetBird Routing"
        alert.informativeText = message
        // The Manager may be closed; a sheet attached to an invisible window is invisible too.
        alert.runModal()
    }
}
