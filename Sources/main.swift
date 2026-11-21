import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

if let command = arguments.first {
    switch command {
    case "--preset-add":
        guard arguments.count >= 3 else {
            fail("usage: --preset-add <name> <regex> [invert] [--high-importance]")
        }
        let name = arguments[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let options = arguments.dropFirst(3)
        guard !name.isEmpty, !arguments[2].isEmpty,
              options.allSatisfy({ ["invert", "--high-importance"].contains($0) }) else {
            fail("Invalid preset name, regex or options")
        }
        do {
            try PresetStore().upsert(Preset(name: name, regex: arguments[2],
                                           invert: options.contains("invert"),
                                           highImportance: options.contains("--high-importance")))
            exit(0)
        } catch { fail(error.localizedDescription, code: 1) }
    case "--dump":
        guard arguments.count == 1 else { fail("usage: --dump") }
        var result: CommandResult?
        NetbirdClient().run(["networks", "list"]) { result = $0 }
        while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard result!.succeeded else { fail(result!.output, code: 1) }
        let entries: [NetEntry]
        do { entries = try parseNetworks(result!.output) }
        catch { fail(error.localizedDescription, code: 1) }
        let enabled = entries.filter(\.selected)
        print("exit=\(result!.code) total=\(entries.count) enabled=\(enabled.count)")
        for entry in enabled.prefix(30) { print("  [on] \(entry.id)  (\(entry.info))") }
        exit(0)
    case "--self-test":
        fail("Tests are separate from the application. Run ./test.sh")
    default:
        fail("Unknown argument: \(command)")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let routing = RoutingController()
    var manager: ManagerController!
    var tray: TrayController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        manager = ManagerController(routing: routing)
        tray = TrayController(routing: routing, manager: manager)
        routing.onChange = { [weak self] in
            self?.manager.render()
            self?.tray.render()
        }
        routing.onCommandError = { [weak self] message in self?.manager.showError(message) }
        routing.start()
    }

    func applicationWillTerminate(_ notification: Notification) { routing.stop() }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
