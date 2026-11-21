import AppKit
/// Native text uses AppKit's font hinting and the actual display backing scale.
/// Unlike the old 36px bitmap, it is never resampled or fractionally positioned by us.
func trayLetterRTitle(state: RoutingIndicator = .normal) -> NSAttributedString {
    let color: NSColor
    switch state {
    case .normal: color = NSColor(srgbRed: 0.10, green: 0.72, blue: 0.32, alpha: 1)
    case .important: color = NSColor(srgbRed: 0.90, green: 0.20, blue: 0.21, alpha: 1)
    case .disconnected: color = .secondaryLabelColor
    case .unknown: color = NSColor(srgbRed: 0.96, green: 0.68, blue: 0.08, alpha: 1)
    }
    return NSAttributedString(string: "R", attributes: [
        .font: NSFont.systemFont(ofSize: 16, weight: .bold),
        .foregroundColor: color,
    ])
}

enum PresetDropTarget: Equatable {
    case before(String)
    case end

    /// Frames are in screen coordinates, ordered top to bottom.
    static func at(_ point: NSPoint, rows: [(name: String, frame: NSRect)]) -> Self? {
        guard let first = rows.first else { return nil }
        let area = rows.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        guard area.insetBy(dx: 0, dy: -6).contains(point) else { return nil }
        for row in rows where point.y >= row.frame.midY { return .before(row.name) }
        return .end
    }
}

/// Live validation and preview are shared by preset creation and editing.
final class PresetEditorView: NSStackView, NSTextFieldDelegate {
    let nameField: NSTextField
    let regexField: NSTextField
    let invertButton = NSButton(checkboxWithTitle: "Invert", target: nil, action: nil)
    let importanceButton = NSButton(checkboxWithTitle: "Высокая важность", target: nil, action: nil)
    let feedback = NSTextField(wrappingLabelWithString: "")
    private let entries: [NetEntry]
    private weak var saveButton: NSButton?

    var preset: Preset {
        Preset(name: nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
               regex: regexField.stringValue, invert: invertButton.state == .on,
               highImportance: importanceButton.state == .on)
    }

    init(existing: Preset?, regex: String, invert: Bool, entries: [NetEntry], saveButton: NSButton) {
        nameField = NSTextField(string: existing?.name ?? "")
        regexField = NSTextField(string: existing?.regex ?? regex)
        self.entries = entries
        self.saveButton = saveButton
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 210))
        orientation = .vertical
        alignment = .leading
        spacing = 8
        nameField.placeholderString = "Preset name"
        nameField.isEditable = existing == nil
        regexField.placeholderString = "Regex"
        nameField.delegate = self
        regexField.delegate = self
        invertButton.state = (existing?.invert ?? invert) ? .on : .off
        invertButton.target = self
        invertButton.action = #selector(updateValidation)
        importanceButton.state = existing?.highImportance == true ? .on : .off
        feedback.font = .systemFont(ofSize: 11)
        feedback.maximumNumberOfLines = 4
        for view in [nameField, regexField, invertButton, importanceButton, feedback] { addArrangedSubview(view) }
        for field in [nameField, regexField, feedback] { field.widthAnchor.constraint(equalToConstant: 400).isActive = true }
        feedback.heightAnchor.constraint(equalToConstant: 64).isActive = true
        updateValidation()
    }

    required init?(coder: NSCoder) { fatalError() }
    func controlTextDidChange(_ notification: Notification) { updateValidation() }

    @objc func updateValidation() {
        let value = preset
        let regexError = value.validationError
        let error = regexError.map { "Ошибка regex: " + $0 } ?? (value.name.isEmpty ? "Введите имя пресета" : nil)
        saveButton?.isEnabled = error == nil
        regexField.textColor = regexError == nil ? .textColor : .systemRed
        regexField.toolTip = regexError
        feedback.textColor = error == nil ? .secondaryLabelColor : .systemRed
        if let error {
            feedback.stringValue = error
        } else {
            let filter = value.filter
            let matches = entries.filter { filter.matches($0) }
            feedback.stringValue = "Совпало сетей: \(matches.count) • включено: \(matches.filter(\.selected).count)"
                + (matches.isEmpty ? "" : "\n" + matches.prefix(2).map(\.id).joined(separator: "\n"))
        }
        feedback.toolTip = feedback.stringValue
    }
}

/// Explicit tracking keeps the status menu open until mouseUp. Starting a system
/// NSDraggingSession would dismiss the menu, losing its drop destinations.
final class PresetDragHandle: NSView {
    var onDrag: ((NSPoint, Bool) -> Void)?
    var onCancel: (() -> Void)?
    override var intrinsicContentSize: NSSize { NSSize(width: 20, height: 24) }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setFill()
        for x in [7.0, 12.0] {
            for y in [7.0, 12.0, 17.0] {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 2, height: 2)).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let origin = window.convertPoint(toScreen: event.locationInWindow)
        var dragging = false
        NSCursor.closedHand.push()
        defer { NSCursor.pop(); onCancel?() }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                                          until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .keyDown {
                if next.keyCode == 53 { return } // Escape cancels without saving.
                continue
            }
            let point = window.convertPoint(toScreen: next.locationInWindow)
            if !dragging, hypot(point.x - origin.x, point.y - origin.y) >= 4 { dragging = true }
            if dragging { onDrag?(point, next.type == .leftMouseUp) }
            if next.type == .leftMouseUp { return }
        }
    }
}

// NSSwitch loses its color in status menus, so render our own switch.
final class ToggleSwitch: NSControl {
    var isOn: Bool { didSet { needsDisplay = true } }
    private let trackSize = NSSize(width: 38, height: 22)

    init(isOn: Bool, target: AnyObject?, action: Selector?) {
        self.isOn = isOn
        super.init(frame: NSRect(origin: .zero, size: trackSize))
        self.target = target
        self.action = action
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { trackSize }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        isOn.toggle()
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11)
        (isOn ? NSColor.systemOrange : NSColor.tertiaryLabelColor.withAlphaComponent(0.6)).setFill()
        track.fill()
        let diameter = trackSize.height - 4
        let x = isOn ? bounds.maxX - diameter - 2 : 2
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: 2, width: diameter, height: diameter)).fill()
    }
}

// Dispatch on mouseDown: menu tracking swallows standard NSButton actions.
final class IconButton: NSControl {
    private let symbol: String
    private var isPressed = false
    var highlightColor: NSColor = .systemRed
    private static let size = NSSize(width: 28, height: 24)

    init(symbol: String, target: AnyObject?, action: Selector?, tag: Int) {
        self.symbol = symbol
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        self.target = target
        self.action = action
        self.tag = tag
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { Self.size }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        display()
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }
    override func mouseUp(with event: NSEvent) { isPressed = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if isPressed {
            highlightColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 5, yRadius: 5).fill()
        }
        let color: NSColor = !isEnabled ? .disabledControlTextColor : (isPressed ? .white : .secondaryLabelColor)
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?.withSymbolConfiguration(config) else { return }
        image.draw(at: NSPoint(x: (bounds.width - image.size.width) / 2, y: (bounds.height - image.size.height) / 2),
                   from: .zero, operation: .sourceOver, fraction: 1)
    }
}

final class PresetRowView: NSView {
    private(set) var presetName: String
    private let label = NSTextField(labelWithString: "")
    let toggleSwitch: ToggleSwitch
    private let trashButton: IconButton
    private let editButton: IconButton
    let dragHandle = PresetDragHandle()
    var insertionEdge: NSRectEdge? { didSet { needsDisplay = true } }

    static func title(for preset: Preset) -> String {
        preset.name + (preset.highImportance ? " ⚠︎" : "")
    }

    init(preset: Preset, isOn: Bool, target: AnyObject,
         toggleAction: Selector, deleteAction: Selector, editAction: Selector) {
        presetName = preset.name
        toggleSwitch = ToggleSwitch(isOn: isOn, target: target, action: toggleAction)
        trashButton = IconButton(symbol: "trash", target: target, action: deleteAction, tag: 0)
        editButton = IconButton(symbol: "gearshape", target: target, action: editAction, tag: 0)
        super.init(frame: NSRect(x: 0, y: 0, width: 364, height: 26))
        label.stringValue = Self.title(for: preset)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = preset.name
        showValidationError(preset.validationError)
        editButton.toolTip = "Preset settings"
        editButton.highlightColor = .systemOrange
        trashButton.toolTip = "Delete preset"
        dragHandle.toolTip = "Перетащите, чтобы изменить порядок (Esc — отмена)"
        for view in [dragHandle, label, toggleSwitch, editButton, trashButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            dragHandle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            dragHandle.centerYAnchor.constraint(equalTo: centerYAnchor),
            dragHandle.widthAnchor.constraint(equalToConstant: 20),
            dragHandle.heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: dragHandle.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: toggleSwitch.leadingAnchor, constant: -8),
            trashButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trashButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            trashButton.widthAnchor.constraint(equalToConstant: 28),
            trashButton.heightAnchor.constraint(equalToConstant: 24),
            editButton.trailingAnchor.constraint(equalTo: trashButton.leadingAnchor, constant: -4),
            editButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            editButton.widthAnchor.constraint(equalToConstant: 28),
            editButton.heightAnchor.constraint(equalToConstant: 24),
            toggleSwitch.trailingAnchor.constraint(equalTo: editButton.leadingAnchor, constant: -8),
            toggleSwitch.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Keep menu items and view geometry fixed while rebinding their contents.
    /// This allows repeated drops without dismissing the tracking menu.
    static func applyOrder(_ presets: [Preset], to rows: [PresetRowView], entries: [NetEntry]) {
        guard rows.count == presets.count,
              Set(rows.map(\.presetName)) == Set(presets.map(\.name)) else { return }
        for (row, preset) in zip(rows, presets) {
            row.presetName = preset.name
            row.label.stringValue = title(for: preset)
            row.label.toolTip = preset.name
            row.showValidationError(preset.validationError)
            row.toggleSwitch.isOn = preset.isOn(in: entries)
            row.insertionEdge = nil
        }
    }

    func showValidationError(_ message: String?) {
        label.textColor = message == nil ? .labelColor : .systemRed
        label.toolTip = message.map { "\(presetName)\nОшибка regex: \($0)" } ?? presetName
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let insertionEdge else { return }
        NSColor.controlAccentColor.setFill()
        let y = insertionEdge == .maxY ? bounds.maxY - 2 : bounds.minY
        NSRect(x: 6, y: y, width: bounds.width - 12, height: 2).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if trashButton.frame.contains(point) { trashButton.mouseDown(with: event); return }
        if editButton.frame.contains(point) { editButton.mouseDown(with: event); return }
        if dragHandle.frame.contains(point) { dragHandle.mouseDown(with: event); return }
        guard toggleSwitch.isEnabled else { return }
        toggleSwitch.isOn.toggle()
        if let action = toggleSwitch.action { NSApp.sendAction(action, to: toggleSwitch.target, from: toggleSwitch) }
    }
}
