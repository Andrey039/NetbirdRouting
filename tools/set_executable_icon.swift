// Finder icons for standalone Mach-O files live in macOS metadata, not the binary.
// Never apply this to a file inside a signed .app bundle.
import AppKit

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: set_executable_icon.swift <standalone-executable> <icon.icns>\n".utf8))
    exit(2)
}

let executable = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
let iconURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard !executable.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }),
      FileManager.default.isExecutableFile(atPath: executable.path),
      let icon = NSImage(contentsOf: iconURL) else {
    FileHandle.standardError.write(Data("Expected a standalone executable outside .app and a readable icon.\n".utf8))
    exit(1)
}
guard NSWorkspace.shared.setIcon(icon, forFile: executable.path, options: []) else {
    FileHandle.standardError.write(Data("Failed to set the Finder icon on \(executable.path)\n".utf8))
    exit(1)
}
print("Finder icon set: \(executable.path)")
