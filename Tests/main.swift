import AppKit

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: " + message) }
    checks += 1
}

func expectFailure(_ message: String, _ action: () throws -> Void) {
    do { try action(); fatalError("FAIL: " + message) } catch { checks += 1 }
}

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("NetbirdRoutingTests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let suite = "NetbirdRoutingTests." + UUID().uuidString
let preferences = UserDefaults(suiteName: suite)!
defer { preferences.removePersistentDomain(forName: suite) }

let legacy = Data(#"[{"name":"Prod","regex":"prod","invert":false}]"#.utf8)
let old = try JSONDecoder().decode([Preset].self, from: legacy)
check(!old[0].highImportance, "legacy preset importance defaults to false")
let prod = Preset(name: "Прод", regex: "prod", invert: false, highImportance: true)
let decoded = try JSONDecoder().decode(Preset.self, from: JSONEncoder().encode(prod))
check(decoded == prod, "preset JSON roundtrip")
check(PresetRowView.title(for: prod) == "Прод ⚠︎", "importance marker follows preset name")
check(PresetRowView.title(for: old[0]) == "Prod", "ordinary preset has no marker")
let on = NetEntry(id: "core-prod", info: "10.0.0.0/24", selected: true)
let off = NetEntry(id: "core-prod", info: "10.0.0.0/24", selected: false)
let dev = NetEntry(id: "dev", info: "10.1.0.0/24", selected: true)
// Reuse actual AppKit view slots: reordering must not replace menu items/views.
let ordinary = Preset(name: "Dev", regex: "dev", invert: false)
let actionTarget = NSObject()
let unusedAction = NSSelectorFromString("unused:")
let firstSlot = PresetRowView(preset: prod, isOn: true, target: actionTarget,
                              toggleAction: unusedAction, deleteAction: unusedAction, editAction: unusedAction)
let secondSlot = PresetRowView(preset: ordinary, isOn: false, target: actionTarget,
                               toggleAction: unusedAction, deleteAction: unusedAction, editAction: unusedAction)
let firstItem = NSMenuItem()
let secondItem = NSMenuItem()
firstItem.view = firstSlot
secondItem.view = secondSlot
let firstHandle = firstSlot.dragHandle
let firstFrame = firstSlot.frame
firstSlot.insertionEdge = .maxY
PresetRowView.applyOrder([ordinary, prod], to: [firstSlot, secondSlot], entries: [on])
check(firstSlot.presetName == "Dev" && secondSlot.presetName == "Прод", "open row identities follow reordered presets")
check(firstItem.view === firstSlot && secondItem.view === secondSlot, "menu items retain original views after drop")
check(firstSlot.dragHandle === firstHandle && firstSlot.frame == firstFrame, "drag handle and row geometry remain stable")
check(!firstSlot.toggleSwitch.isOn && secondSlot.toggleSwitch.isOn, "switch states follow new contents")
check(firstSlot.subviews.compactMap { $0 as? NSTextField }.first?.stringValue == "Dev", "first label updates in place")
check(secondSlot.subviews.compactMap { $0 as? NSTextField }.first?.stringValue == "Прод ⚠︎", "importance marker follows moved preset")
check(firstSlot.insertionEdge == nil && secondSlot.insertionEdge == nil, "drop clears insertion markers")
PresetRowView.applyOrder([prod, ordinary], to: [firstSlot, secondSlot], entries: [on])
check(firstSlot.presetName == "Прод" && secondSlot.presetName == "Dev", "second drop reuses the same open row slots")
check(firstSlot.toggleSwitch.isOn && !secondSlot.toggleSwitch.isOn, "second drop rebinds controls to current preset")
PresetRowView.applyOrder([ordinary], to: [firstSlot, secondSlot], entries: [])
check(firstSlot.presetName == "Прод", "changed row count does not partially rebind menu")
PresetRowView.applyOrder([ordinary, old[0]], to: [firstSlot, secondSlot], entries: [])
check(firstSlot.presetName == "Прод", "changed membership does not misbind existing controls")
check(hasActiveImportantPreset([prod], entries: [on], connected: true), "active connected important preset is red")
check(!hasActiveImportantPreset([prod], entries: [on], connected: false), "disconnected is green")
check(!hasActiveImportantPreset([prod], entries: [off], connected: true), "disabled preset is green")
check(!hasActiveImportantPreset([prod], entries: [dev], connected: true), "nonmatching network is green")
check(!hasActiveImportantPreset(old, entries: [on], connected: true), "ordinary preset is green")
check(!hasActiveImportantPreset([prod], entries: [], connected: true), "empty networks are green")
check(hasActiveImportantPreset([prod], entries: [off, on], connected: true), "partially enabled preset is red")
let inverted = Preset(name: "Inverted", regex: "dev", invert: true, highImportance: true)
check(hasActiveImportantPreset([inverted], entries: [on], connected: true), "inverted preset matches")
check(!hasActiveImportantPreset([inverted], entries: [dev], connected: true), "inverted preset excludes")
check(!prod.isOn(in: []), "unloaded preset is not ON")
check(netbirdIsConnected(#"{"management":{"connected":true}}"#), "connected status")
check(!netbirdIsConnected(#"{"management":{"connected":false}}"#), "disconnected status")
check(!netbirdIsConnected("invalid") && !netbirdIsConnected("{}"), "invalid status is not connected")
check(!netbirdIsConnected(#"{"management":{"connected":1}}"#), "status expects a boolean, not a number")
let greenTitle = trayLetterRTitle()
let redTitle = trayLetterRTitle(state: .important)
check(greenTitle.string == "R" && redTitle.string == "R", "status uses native text in both states")
check((greenTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 16, "native status font is 16pt")
check(!(greenTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor).isEqual(redTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil)), "important state preserves distinct red color")
let dragRows: [(name: String, frame: NSRect)] = [
    ("A", NSRect(x: 100, y: 200, width: 200, height: 26)),
    ("B", NSRect(x: 100, y: 174, width: 200, height: 26)),
    ("C", NSRect(x: 100, y: 148, width: 200, height: 26)),
]
check(PresetDropTarget.at(NSPoint(x: 150, y: 225), rows: dragRows) == .before("A"), "drop at top inserts first")
check(PresetDropTarget.at(NSPoint(x: 150, y: 201), rows: dragRows) == .before("B"), "lower half inserts after hovered row")
check(PresetDropTarget.at(NSPoint(x: 150, y: 190), rows: dragRows) == .before("B"), "upper half inserts before hovered row")
check(PresetDropTarget.at(NSPoint(x: 150, y: 150), rows: dragRows) == .end, "drop at bottom appends")
check(PresetDropTarget.at(NSPoint(x: 50, y: 200), rows: dragRows) == nil, "drop outside menu cancels")
check(PresetDropTarget.at(NSPoint(x: 150, y: 100), rows: dragRows) == nil, "drop near Quit does not reorder")
check(PresetDropTarget.at(NSPoint(x: 150, y: 250), rows: dragRows) == nil, "drop above preset area cancels")
check(PresetDropTarget.at(.zero, rows: []) == nil, "empty menu has no drop destination")
check(NetworkFilter("[").validationError != nil, "invalid regex has an explicit validation error")
check(!NetworkFilter("[").matches("literal [ value"), "invalid regex does not fall back to literal")
check(!NetworkFilter("[", invert: true).matches(on), "invalid inverted regex must not match all networks")
check(parseNetbirdConnection(#"{"daemonStatus":"Disconnected"}"#) == .disconnected, "explicit disconnected status does not require management")
check(parseNetbirdConnection("invalid") == .unknown, "malformed JSON is unknown, not disconnected")
check(parseNetbirdConnection(#"{"daemonStatus":"Connected","management":{"connected":false}}"#) == .unknown, "inconsistent connection status is unknown")
check(parseNetbirdConnection(#"{"daemonStatus":"Unexpected","management":{"connected":true}}"#) == .unknown, "unknown daemon status is not connected")
let colors = RoutingIndicator.allCases.map { trayLetterRTitle(state: $0).attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor }
check(Set(colors).count == 4, "all four indicators have distinct colors")
let editorSave = NSButton(title: "Save", target: nil, action: nil)
let editor = PresetEditorView(existing: nil, regex: "[", invert: true, entries: [on, dev], saveButton: editorSave)
editor.nameField.stringValue = "Preview"
editor.updateValidation()
check(!editorSave.isEnabled && editor.feedback.stringValue.contains("Ошибка regex"), "editor blocks saving invalid regex with inline error")
editor.regexField.stringValue = "prod"
editor.invertButton.state = .off
editor.updateValidation()
check(editorSave.isEnabled && editor.feedback.stringValue.contains("Совпало сетей: 1 • включено: 1"), "valid regex re-enables Save and previews counts")
check(editor.feedback.stringValue.contains(on.id), "preview includes matching resource examples")
editor.invertButton.state = .on
editor.updateValidation()
check(editor.feedback.stringValue.contains(dev.id) && !editor.feedback.stringValue.contains(on.id), "preview respects inversion")
editor.nameField.stringValue = " "
editor.updateValidation()
check(!editorSave.isEnabled, "editor cannot save blank name")
editor.nameField.stringValue = "Preview"
editor.regexField.stringValue = ""
editor.updateValidation()
check(!editorSave.isEnabled, "editor cannot save empty preset regex")
check(NetworkFilter("PROD").matches(on), "case-insensitive regex")
// README examples: invert negates the combined ID/info match, not each field.
let prodDomain = NetEntry(id: "office", info: "prod.example.test", selected: true)
check(!NetworkFilter("prod|uat", invert: true).matches(on), "inverted alternatives exclude matching ID")
check(!NetworkFilter("prod|uat", invert: true).matches(prodDomain), "inverted alternatives exclude matching info")
check(NetworkFilter("prod|uat", invert: true).matches(dev), "inverted alternatives retain unrelated network")
check(NetworkFilter("^(?!.*prod).*$").matches(on), "negative lookahead on info does not exclude matching ID")
let privateIPv4 = NetworkFilter(#"^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)"#, invert: true)
for prefix in ["10.20.0.0/16", "192.168.1.0/24", "172.16.0.0/16", "172.31.0.0/16"] {
    check(!privateIPv4.matches(NetEntry(id: "office", info: prefix, selected: true)), "Non-local excludes \(prefix)")
}
for prefix in ["172.15.0.0/16", "172.32.0.0/16", "100.64.0.0/10", "2001:db8::/32", "example.test"] {
    check(privateIPv4.matches(NetEntry(id: "office", info: prefix, selected: true)), "Non-local retains \(prefix)")
}
check(NetworkFilter("").matches(dev) && !NetworkFilter("", invert: true).matches(dev), "empty/inverted filter")
check(NetworkFilter("10\\.0").matches(on), "filter matches network info")
check(NetworkFilter("^(?!dev).*").matches(on.id) && !NetworkFilter("^(?!dev).*").matches(dev.id), "NSRegularExpression supports negative lookahead")

let selectedOutput = """
  - ID: core-prod
    Network: 10.0.0.0/24
    Status: Selected
  - ID: dev
    Domains: dev.example.test
    Status: Not Selected
"""
let deselectedOutput = selectedOutput.replacingOccurrences(of: "Status: Selected", with: "Status: Not Selected")
let parsed = try parseNetworks(selectedOutput)
check(parsed.count == 2 && parsed[0] == on && !parsed[1].selected, "network list parser")
check(parsed[1].info == "dev.example.test", "domain resource parser")
check((try? parseNetworks(selectedOutput.replacingOccurrences(of: "\n", with: "\r\n"))) == parsed, "CRLF input")
check((try? parseNetworks("No networks available.\n")) == [], "explicit empty list sentinel")
expectFailure("empty output is not a verified empty list") { _ = try parseNetworks("") }
expectFailure("unknown status is not disabled") { _ = try parseNetworks("- ID: test\nNetwork: 10.0.0.0/24\nStatus: UnexpectedSelected") }
expectFailure("missing status rejects truncated output") { _ = try parseNetworks("- ID: test\nNetwork: 10.0.0.0/24") }
expectFailure("unknown output fails") { _ = try parseNetworks("unexpected format") }
expectFailure("header without records fails") { _ = try parseNetworks("Available Networks:") }
expectFailure("duplicate IDs fail") { _ = try parseNetworks(selectedOutput + "\n" + selectedOutput) }
expectFailure("mixed empty sentinel and records fails") { _ = try parseNetworks("No networks available.\n" + selectedOutput) }
expectFailure("missing network info fails") { _ = try parseNetworks("- ID: test\nStatus: Selected") }
expectFailure("truncated final record invalidates the entire snapshot") {
    _ = try parseNetworks(selectedOutput + "\n- ID: truncated\nNetwork: 10.0.0.0/24")
}
let domainOutput = "Available Networks:\n- ID: example.test for test\nDomains: example.test\nStatus: Selected\nResolved IPs:\n[example.test]: 192.0.2.1"
check((try? parseNetworks(domainOutput))?.first?.selected == true, "real CLI header and resolved-IP block supported")

let store = PresetStore(fileURL: temporary.appendingPathComponent("data/presets.json"), defaults: preferences)
check((try? store.load()) == PresetStore.initialPresets, "first load creates defaults")
try store.upsert(prod)
check((try? store.load().contains(prod)) == true, "upsert persists importance")
store.rememberDisabled([on.id], for: prod)
let initialOrder = try store.load()
let movedUp = try store.move(prod, before: "core-prod")
check(movedUp.map(\.name) == ["non-local", "Прод", "core-prod"], "move up swaps adjacent presets")
check((try? store.load()) == movedUp, "new order persists on disk")
check(movedUp[1] == prod && store.disabledIDs(for: prod) == [on.id], "move preserves settings and remembered IDs")
check((try? store.move(prod, before: nil)) == initialOrder, "drop at end restores order")
let movedFirst = try store.move(prod, before: "non-local")
check(movedFirst.map(\.name) == ["Прод", "non-local", "core-prod"], "drag can skip multiple rows")
_ = try store.move(prod, before: nil)
check((try? store.move(initialOrder[0], before: nil))?.map(\.name) == ["core-prod", "Прод", "non-local"], "drag first to end adjusts index after removal")
_ = try store.move(initialOrder[0], before: "core-prod")
let unchangedBytes = try Data(contentsOf: store.fileURL)
check((try? store.move(initialOrder[0], before: "core-prod")) == initialOrder, "drop in current slot is a no-op")
check((try? store.move(prod, before: nil)) == initialOrder, "last preset stays last when appended")
check((try? store.move(prod, before: prod.name)) == initialOrder, "drop before self is a no-op")
check((try? store.move(prod, before: "Missing")) == initialOrder, "missing destination is ignored")
check((try? store.move(Preset(name: "Missing", regex: "x", invert: false), before: nil)) == initialOrder, "missing source is ignored")
check((try? Data(contentsOf: store.fileURL)) == unchangedBytes, "invalid moves do not rewrite the file")
let normalProd = Preset(name: prod.name, regex: prod.regex, invert: false)
try store.upsert(normalProd)
check(store.disabledIDs(for: prod) == [on.id], "importance change preserves remembered selection")
let changed = Preset(name: prod.name, regex: "dev", invert: false)
try store.upsert(changed)
check(store.disabledIDs(for: prod).isEmpty, "filter change invalidates remembered selection")
store.rememberDisabled([on.id], for: prod)
try store.remove(changed)
check(store.disabledIDs(for: prod).isEmpty && (try? store.load().contains(changed)) == false, "removal clears remembered selection")

let corrupt = Data("this is not JSON".utf8)
try corrupt.write(to: store.fileURL)
let invalidPreset = Preset(name: "Broken", regex: "[", invert: true, highImportance: true)
let beforeInvalidUpsert = try Data(contentsOf: store.fileURL)
expectFailure("upsert rejects malformed regex") { _ = try store.upsert(invalidPreset) }
check((try? Data(contentsOf: store.fileURL)) == beforeInvalidUpsert, "invalid upsert never changes the file")
expectFailure("corrupt load must fail") { _ = try store.load() }
expectFailure("upsert cannot overwrite a corrupt file") { _ = try store.upsert(prod) }
expectFailure("delete cannot overwrite a corrupt file") { _ = try store.remove(prod) }
expectFailure("move cannot overwrite a corrupt file") { _ = try store.move(prod, before: "core-prod") }
check((try? Data(contentsOf: store.fileURL)) == corrupt, "corrupt file stays byte-identical")
let duplicateNames = try JSONEncoder().encode([prod, prod])
try duplicateNames.write(to: store.fileURL)
expectFailure("duplicate names are not valid stable identities") { _ = try store.load() }
check((try? Data(contentsOf: store.fileURL)) == duplicateNames, "duplicate-name file is not overwritten")

final class MockNetbird: NetbirdRunning {
    struct Request {
        let arguments: [String]
        let completion: (CommandResult) -> Void
    }
    var requests: [Request] = []
    func run(_ arguments: [String], completion: @escaping (CommandResult) -> Void) {
        requests.append(Request(arguments: arguments, completion: completion))
    }
    func respond(_ expected: [String], code: Int32 = 0, output: String = "") {
        check(!requests.isEmpty, "request exists: \(expected)")
        let request = requests.removeFirst()
        check(request.arguments == expected, "expected \(expected), got \(request.arguments)")
        request.completion(CommandResult(code: code, output: output))
    }
    func snapshot(_ output: String, networkCode: Int32 = 0, connected: Bool = true) {
        respond(["networks", "list"], code: networkCode, output: output)
        respond(["status", "--json"], output: "{\"management\":{\"connected\":\(connected)}}")
    }
}

let stateStore = PresetStore(fileURL: temporary.appendingPathComponent("state/presets.json"), defaults: preferences)
try stateStore.upsert(prod)
let mock = MockNetbird()
let routing = RoutingController(client: mock, store: stateStore)
check(routing.indicator == .unknown, "startup is yellow until status is known")
var errors: [String] = []
routing.onCommandError = { errors.append($0) }
routing.refresh()
check(routing.isBusy && !routing.hasLoadedNetworks, "initial refresh is in progress")
routing.refresh()
check(mock.requests.count == 1, "duplicate refresh is coalesced")
routing.togglePreset(prod, enable: false)
check(mock.requests.count == 1, "click during polling is queued")
mock.snapshot(selectedOutput)
check(routing.important, "coherent connected snapshot makes important preset red")
check(routing.indicator == .important && routing.statusDescription.contains("Прод"), "red tooltip names the important active preset")
check(routing.indicator(at: routing.lastRefreshAt!.addingTimeInterval(21)) == .unknown, "stale snapshot becomes yellow")
check(mock.requests.first?.arguments == ["networks", "deselect", on.id], "queued toggle executes after refresh")
check(stateStore.disabledIDs(for: prod).isEmpty, "disabled IDs are not committed before command success")
mock.respond(["networks", "deselect", on.id], code: 1, output: "denied")
check(errors.count == 1 && stateStore.disabledIDs(for: prod).isEmpty, "failed disable does not save IDs")
mock.snapshot(selectedOutput)
routing.togglePreset(prod, enable: false)
mock.respond(["networks", "deselect", on.id])
check(stateStore.disabledIDs(for: prod).isEmpty, "exit zero alone does not commit disabled IDs")
mock.snapshot(deselectedOutput)
check(stateStore.disabledIDs(for: prod) == [on.id], "verified disable remembers IDs")
check(!routing.important, "disabled important preset becomes green")
check(routing.indicator == .normal, "connected without important networks is green")
routing.togglePreset(prod, enable: true)
mock.respond(["networks", "select", "-a", on.id], code: 1, output: "denied")
mock.snapshot(deselectedOutput)
check(stateStore.disabledIDs(for: prod) == [on.id], "failed enable keeps remembered IDs")
routing.togglePreset(prod, enable: true)
mock.respond(["networks", "select", "-a", on.id])
check(stateStore.disabledIDs(for: prod) == [on.id], "exit zero alone does not forget remembered IDs")
// Queue another user action during the mandatory post-command refresh.
routing.perform(["networks", "deselect", "all"])
mock.snapshot(selectedOutput)
check(stateStore.disabledIDs(for: prod).isEmpty, "verified enable forgets remembered IDs")
mock.respond(["networks", "deselect", "all"])
mock.snapshot(deselectedOutput)
check(!routing.isBusy && mock.requests.isEmpty, "queued manual action and refresh drain fully")

stateStore.rememberDisabled(["removed-network", on.id], for: prod)
routing.togglePreset(prod, enable: true)
mock.respond(["networks", "select", "-a", on.id])
mock.snapshot(selectedOutput, connected: false)
check(!routing.important && !routing.connected, "disconnect resets red")
check(routing.indicator == .disconnected && routing.statusDescription == "NetBird отключён", "known disconnect is gray")
routing.refresh()
mock.snapshot("network failure", networkCode: 1)
check(routing.entries.isEmpty && !routing.hasLoadedNetworks && routing.networkError != nil, "network failure clears stale entries")
check(routing.indicator == .unknown, "network failure while connected is yellow")
routing.togglePreset(prod, enable: false)
mock.snapshot("network failure", networkCode: 1)
check(errors.count == 3 && mock.requests.isEmpty, "failed reload rejects preset action explicitly")
routing.refresh()
mock.snapshot(selectedOutput)
check(routing.networkError == nil && routing.important, "successful refresh recovers from errors")
// Failed and malformed status replies are distinct from a confirmed disconnect.
routing.refresh()
mock.respond(["networks", "list"], output: selectedOutput)
mock.respond(["status", "--json"], code: 1, output: "unavailable")
check(routing.indicator == .unknown && routing.statusDescription.contains("unavailable"), "CLI status failure is yellow with reason")
routing.refresh()
mock.respond(["networks", "list"], output: selectedOutput)
mock.respond(["status", "--json"], output: "invalid JSON")
check(routing.connection == .unknown && routing.indicator == .unknown, "invalid JSON is yellow, not gray")
routing.refresh()
mock.snapshot(selectedOutput)
check(routing.indicator == .important, "valid status restores red after status errors")
var reorderNotices = 0
routing.onChange = { reorderNotices += 1 }
try routing.movePreset(prod, before: "core-prod")
check(routing.presets.map(\.name) == ["non-local", "Прод", "core-prod"], "controller publishes new order")
check(reorderNotices == 1 && routing.important && mock.requests.isEmpty, "reorder notifies UI without changing routes or importance")
let reopenedStore = PresetStore(fileURL: stateStore.fileURL, defaults: preferences)
check((try? reopenedStore.load()) == routing.presets, "order survives store recreation")
try corrupt.write(to: stateStore.fileURL)
expectFailure("controller cannot reorder a corrupt file") { try routing.movePreset(prod, before: nil) }
check(routing.presets.map(\.name) == ["non-local", "Прод", "core-prod"], "failed reorder keeps current state")
routing.reloadPresets()
check(routing.presetError != nil && routing.presets.contains(prod), "reload error preserves last known important presets")
check(routing.indicator == .unknown, "preset read error is yellow, not a false green")
try JSONEncoder().encode([prod, invalidPreset]).write(to: stateStore.fileURL)
routing.reloadPresets()
check(routing.invalidPresetNames == ["Broken"] && routing.indicator == .unknown, "legacy invalid regex stays editable and makes status yellow")
let requestsBeforeInvalidToggle = mock.requests.count
routing.togglePreset(invalidPreset, enable: true)
check(mock.requests.count == requestsBeforeInvalidToggle && errors.last?.contains("Regex «Broken»") == true, "invalid preset never sends a CLI mutation")

// Regression cases from the logic review. All commands below use MockNetbird.
func scenario(regex: String = "^[abc]$") throws -> (Preset, RoutingController, MockNetbird, PresetStore) {
    let name = "Scenario-" + UUID().uuidString
    let preset = Preset(name: name, regex: regex, invert: false, highImportance: true)
    let store = PresetStore(fileURL: temporary.appendingPathComponent(name + "/presets.json"), defaults: preferences)
    try store.upsert(preset)
    let mock = MockNetbird()
    return (preset, RoutingController(client: mock, store: store), mock, store)
}

func scenarioList(_ selected: Set<String>) -> String {
    "Available Networks:\n" + ["a", "b", "c"].map {
        "- ID: \($0)\nNetwork: 10.0.0.1/32\nStatus: \(selected.contains($0) ? "Selected" : "Not Selected")"
    }.joined(separator: "\n")
}

do {
    let (p, state, cli, saved) = try scenario()
    var messages: [String] = []
    state.onCommandError = { messages.append($0) }
    state.refresh(); cli.snapshot(scenarioList([]))
    saved.rememberDisabled(["removed"], for: p)
    state.togglePreset(p, enable: true)
    check(cli.requests.isEmpty && !state.isBusy, "stale restore list never enables other matching networks")
    check(messages.last?.contains("не найдены") == true && saved.disabledIDs(for: p) == ["removed"], "stale restore is explained and retained")
}
do {
    let (p, state, cli, saved) = try scenario()
    state.refresh(); cli.snapshot(scenarioList([]))
    state.togglePreset(p, enable: true)
    cli.respond(["networks", "select", "-a", "a", "b", "c"])
    cli.snapshot(scenarioList(["a", "b", "c"]))
    check(saved.disabledIDs(for: p).isEmpty, "first activation without saved list still selects matching networks")
    check((try? saved.pendingOperation(for: p)) == nil, "verified operation clears its journal")
}
do {
    let (p, state, cli, saved) = try scenario()
    state.refresh(); cli.snapshot(scenarioList(["a", "b"]))
    state.togglePreset(p, enable: false)
    check((try? saved.pendingOperation(for: p))?.ids == ["a", "b"], "snapshot is journaled before deselect starts")
    cli.respond(["networks", "deselect", "a", "b"], code: 1, output: "partial failure")
    cli.snapshot(scenarioList(["b"]))
    check(saved.disabledIDs(for: p) == ["a"], "partial disable records only observed disabled routes")
    state.togglePreset(p, enable: false)
    cli.respond(["networks", "deselect", "b"])
    cli.snapshot(scenarioList([]))
    check(saved.disabledIDs(for: p) == ["a", "b"], "retry merges rather than overwrites original restore list")
    state.togglePreset(p, enable: true)
    cli.respond(["networks", "select", "-a", "a", "b"])
    cli.snapshot(scenarioList(["a", "b"]))
    check(saved.disabledIDs(for: p).isEmpty && !state.entries.first(where: { $0.id == "c" })!.selected,
          "restore recovers original a,b without enabling originally disabled c")
}
do {
    let (p, state, cli, saved) = try scenario()
    state.refresh(); cli.snapshot(scenarioList([]))
    saved.rememberDisabled(["a", "b"], for: p)
    state.togglePreset(p, enable: true)
    cli.respond(["networks", "select", "-a", "a", "b"], code: 1, output: "partial failure")
    cli.snapshot(scenarioList(["a"]))
    check(saved.disabledIDs(for: p) == ["b"], "partial enable retains only routes still needing restore")
    state.togglePreset(p, enable: true)
    cli.respond(["networks", "select", "-a", "b"])
    cli.snapshot(scenarioList(["a", "b"]))
    check(saved.disabledIDs(for: p).isEmpty, "partial enable retry completes original selection")
}
do {
    let (p, state, cli, saved) = try scenario()
    state.refresh(); cli.snapshot(scenarioList(["a", "b"]))
    state.togglePreset(p, enable: false)
    cli.respond(["networks", "deselect", "a", "b"])
    cli.snapshot("unavailable", networkCode: 1)
    check((try? saved.pendingOperation(for: p)) != nil && saved.disabledIDs(for: p).isEmpty,
          "failed verification retains uncommitted journal")
    let nextCLI = MockNetbird()
    let restarted = RoutingController(client: nextCLI, store: saved)
    restarted.refresh(); nextCLI.snapshot(scenarioList(["b"]))
    check(saved.disabledIDs(for: p) == ["a"], "journal reconciles partial changes after controller restart")
    check(nextCLI.requests.isEmpty, "journal recovery never replays a network command")
    check(restarted.recoveryError != nil && restarted.indicator == .unknown,
          "reported CLI success without full state change is not accepted silently")
}
do {
    let (p, state, cli, saved) = try scenario(regex: "^a$")
    state.refresh(); cli.snapshot(scenarioList(["a"]))
    state.togglePreset(p, enable: false)
    let edited = Preset(name: p.name, regex: "^b$", invert: false)
    try state.savePreset(edited)
    cli.respond(["networks", "deselect", "a"])
    cli.snapshot(scenarioList(["b"]))
    check(saved.disabledIDs(for: edited).isEmpty && (try? saved.pendingOperation(for: edited)) == nil,
          "old completion cannot repopulate restore data invalidated by filter edit")
}
do {
    let (p, state, cli, _) = try scenario(regex: "^a$")
    var messages: [String] = []
    state.onCommandError = { messages.append($0) }
    state.refresh()
    state.togglePreset(p, enable: false)
    try state.savePreset(Preset(name: p.name, regex: "^b$", invert: false))
    cli.snapshot(scenarioList(["a", "b"]))
    check(cli.requests.isEmpty && messages.last?.contains("отменено") == true,
          "queued old-filter action is canceled instead of mutating the edited filter")
}
do {
    let (p, state, cli, _) = try scenario(regex: "^a$")
    var messages: [String] = []
    state.onCommandError = { messages.append($0) }
    state.refresh(); state.togglePreset(p, enable: false)
    try state.savePreset(Preset(name: p.name, regex: "^b$", invert: false))
    try state.savePreset(p)
    cli.snapshot(scenarioList(["a"]))
    check(cli.requests.isEmpty && !messages.isEmpty, "edit then revert still invalidates the queued revision")
}
do {
    let (p, state, cli, saved) = try scenario(regex: "^a$")
    state.refresh(); state.togglePreset(p, enable: false)
    try state.savePreset(Preset(name: p.name, regex: p.regex, invert: p.invert, highImportance: false))
    cli.snapshot(scenarioList(["a"]))
    cli.respond(["networks", "deselect", "a"])
    cli.snapshot(scenarioList([]))
    check(saved.disabledIDs(for: p) == ["a"], "importance-only edit does not cancel the routing action")
}
do {
    let (p, state, cli, saved) = try scenario(regex: "^a$")
    state.refresh(); cli.snapshot(scenarioList(["a"]))
    state.togglePreset(p, enable: false)
    try state.removePreset(p)
    try state.savePreset(p)
    cli.respond(["networks", "deselect", "a"])
    cli.snapshot(scenarioList([]))
    check(saved.disabledIDs(for: p).isEmpty && (try? saved.pendingOperation(for: p)) == nil,
          "delete and recreate with identical name/filter cannot revive old operation state")
}
do {
    let (p, state, cli, saved) = try scenario(regex: "^a$")
    state.refresh(); cli.snapshot(scenarioList(["a"]))
    state.togglePreset(p, enable: false)
    let external = Preset(name: p.name, regex: "^b$", invert: false)
    try JSONEncoder().encode([external]).write(to: saved.fileURL, options: .atomic)
    cli.respond(["networks", "deselect", "a"])
    cli.snapshot(scenarioList(["b"]))
    check(saved.disabledIDs(for: external).isEmpty && state.presets == [external],
          "external filter edit is detected before recording an old completion")
}
do {
    let (p, state, cli, _) = try scenario()
    state.refresh(); cli.snapshot(scenarioList(["a"]))
    check(state.indicator == .important, "baseline important route is red")
    state.refresh(); cli.snapshot("unknown output")
    check(!state.hasLoadedNetworks && state.networkError != nil && state.indicator == .unknown,
          "unknown CLI format is yellow/unavailable, never empty green")
    state.togglePreset(p, enable: false)
    cli.snapshot("Available Networks:")
    check(cli.requests.isEmpty, "invalid refresh never authorizes a queued preset mutation")
    state.refresh(); cli.snapshot("No networks available.")
    check(state.hasLoadedNetworks && state.entries.isEmpty && state.indicator == .normal,
          "explicit valid empty output remains distinct from parse failure")
}

// Real process tests use only harmless local fixture commands, never NetBird.
func awaitResult(_ client: NetbirdClient, _ arguments: [String]) -> CommandResult {
    var result: CommandResult?
    client.run(arguments) { value in
        check(Thread.isMainThread, "CLI completion uses main thread")
        result = value
    }
    let limit = Date().addingTimeInterval(5)
    while result == nil && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    guard let result else { fatalError("CLI fixture did not complete") }
    return result
}
let echo = awaitResult(NetbirdClient(executable: "/bin/echo"), ["fixture"])
check(echo.succeeded && echo.output == "fixture\n", "CLI captures output")
let missing = awaitResult(NetbirdClient(executable: temporary.appendingPathComponent("missing").path), [])
check(missing.code == -1, "launch failure reaches completion")
let failure = awaitResult(NetbirdClient(executable: "/usr/bin/false"), [])
check(!failure.succeeded, "nonzero CLI exit is retained")
let timeout = awaitResult(NetbirdClient(executable: "/bin/sleep", timeout: 0.1), ["3"])
check(timeout.code == -2 && timeout.output.contains("timeout"), "stuck CLI is killed at deadline")

print("PASS: \(checks) checks (models, persistence, state/queue, process fixtures, icons)")
