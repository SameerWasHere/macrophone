import AppKit
import MacrophoneKit
import SwiftUI

/// Installs `macrophone` and `mp` into /usr/local/bin as links to the copy inside the app.
@MainActor
enum CLIInstaller {
    static var bundled: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/macrophone") }

    static var directory: URL {
        #if DEBUG
        if let d = ProcessInfo.processInfo.environment["MACROPHONE_CLI_DIR"] { return URL(fileURLWithPath: d) }
        #endif
        return URL(fileURLWithPath: "/usr/local/bin")
    }

    enum Status: Equatable { case notInstalled, installed, otherCopy(String) }

    static var status: Status {
        let link = directory.appendingPathComponent("macrophone").path
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else {
            return FileManager.default.fileExists(atPath: link) ? .otherCopy(link) : .notInstalled
        }
        return dest == bundled.path ? .installed : .otherCopy(dest)
    }

    /// Links without a password when the folder is writable, else asks for an admin password once.
    static func install() -> String? {
        let fm = FileManager.default
        let dir = directory
        let src = bundled.path
        guard fm.isExecutableFile(atPath: src) else { return "The command-line tool is missing from this copy of Macrophone." }
        if (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil, fm.isWritableFile(atPath: dir.path) {
            do {
                for name in ["macrophone", "mp"] {
                    let p = dir.appendingPathComponent(name).path
                    if (try? fm.destinationOfSymbolicLink(atPath: p)) != nil || fm.fileExists(atPath: p) { try fm.removeItem(atPath: p) }
                    try fm.createSymbolicLink(atPath: p, withDestinationPath: src)
                }
                return nil
            } catch {}
        }
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let script = """
        set src to "\(esc(src))"
        set dir to "\(esc(dir.path))"
        do shell script "mkdir -p " & quoted form of dir & " && ln -sf " & quoted form of src & " " & quoted form of (dir & "/macrophone") & " && ln -sf " & quoted form of src & " " & quoted form of (dir & "/mp") with prompt "Macrophone wants to install its command-line tool (macrophone and mp)." with administrator privileges
        """
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err {
            if (err[NSAppleScript.errorNumber] as? Int) == -128 { return "Cancelled." }
            return "Couldn't install: \(err[NSAppleScript.errorMessage] as? String ?? "unknown error")"
        }
        return nil
    }
}

struct DeveloperPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings
    @State private var reveal = false
    @State private var confirmRegenerate = false
    @State private var cliStatus = CLIInstaller.status
    @State private var cliMessage: String?

    private var port: UInt16 {
        if case .listening(let p) = model.apiState { return p }
        return APIConfig.load()?.port ?? Product.apiPort
    }

    private var masked: String { String(model.apiToken.prefix(6)) + String(repeating: "•", count: 22) }

    var body: some View {
        PanePage {
            PaneHeader(title: "Developer", subtitle: "Let scripts and agents read what you dictate — through a local API, the mp command and an MCP server. Only this Mac can reach it.")

            Plate {
                PlateRow(title: "Local API", subtitle: apiLine, subtitleColor: apiColor,
                         icon: "network", iconColor: apiColor == Light.mint ? Light.mint : Ink.secondary) {
                    Toggle("", isOn: $settings.apiEnabled).toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel("Local API")
                }
                PlateDivider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: Space.gap) {
                        Image(systemName: "key").font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.secondary)
                            .frame(width: 22).accessibilityHidden(true)
                        Text("Token").font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.ink)
                        Spacer()
                        Button(reveal ? "Hide" : "Show") { reveal.toggle() }
                            .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                            .help(reveal ? "Mask the token" : "Show the whole token")
                        Button("Regenerate…") { confirmRegenerate = true }
                            .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                            .help("Make a new token; the old one stops working")
                            .confirmationDialog("Make a new token?", isPresented: $confirmRegenerate) {
                                Button("Regenerate", role: .destructive) { model.regenerateToken() }
                            } message: {
                                Text("Anything using the old token stops working. The mp command and the MCP server pick up the new one by themselves.")
                            }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        CodePlate(text: reveal ? model.apiToken : masked, copyText: model.apiToken, copyLabel: "Copy")
                            .accessibilityLabel(reveal ? "API token" : "API token, masked")
                        Text("The mp command and the MCP server read it from ~/Library/Application Support/Macrophone/api.json, which only you can open.")
                            .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 22 + Space.gap)
                }
                .padding(.horizontal, Space.inset).padding(.vertical, 13)
                PlateDivider()
                PlateRow(title: "Command-line tool", subtitle: cliLine,
                         subtitleColor: cliStatus == .installed ? Light.mint : Ink.tertiary,
                         icon: "terminal", iconColor: cliStatus == .installed ? Light.mint : Ink.secondary) {
                    Button(cliStatus == .installed ? "Reinstall" : "Install…") {
                        cliMessage = CLIInstaller.install()
                        cliStatus = CLIInstaller.status
                    }
                    .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: cliStatus != .installed))
                }
                if let cliMessage {
                    Text(cliMessage).font(.system(size: 11.5)).foregroundStyle(Light.rose)
                        .padding(.leading, PlateDivider.rowInset).padding(.trailing, Space.inset).padding(.bottom, 12)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            PaneSection("Hook it up") {
                Plate {
                    VStack(alignment: .leading, spacing: 16) {
                        snippet("curl — the latest dictation", CodePlate(text: curl(reveal ? model.apiToken : masked), copyText: curl(model.apiToken)))
                        snippet("Claude Code", CodePlate(text: "claude mcp add macrophone -- macrophone mcp"))
                        snippet("Claude Desktop — claude_desktop_config.json", CodePlate(text: """
                        {
                          "mcpServers": {
                            "macrophone": {
                              "command": "/usr/local/bin/macrophone",
                              "args": ["mcp"]
                            }
                          }
                        }
                        """))
                        Text("In a terminal: mp prints the latest, mp wait waits for the next, mp list shows recent ones. Agents get two MCP tools: get_latest_dictation and wait_for_dictation.")
                            .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Link(destination: Product.docs) { Label("Read the API docs", systemImage: "book") }
                            .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                            .accessibilityLabel("Read the API docs on the web")
                    }
                    .padding(Space.inset)
                }
            }
        }
        .onAppear { cliStatus = CLIInstaller.status }
    }

    private func curl(_ token: String) -> String {
        "curl -s -H \"Authorization: Bearer \(token)\" \\\n  http://127.0.0.1:\(port)/v1/latest"
    }

    private func snippet(_ title: String, _ plate: CodePlate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.secondary)
            plate
        }
    }

    private var apiLine: String {
        switch model.apiState {
        case .listening(let p): return "On — 127.0.0.1:\(p), this Mac only, token required. Web pages are always refused."
        case .starting: return "Starting…"
        case .off: return "Off. The mp command and the MCP server can't read dictations."
        case .failed(let s): return s
        }
    }

    private var apiColor: Color {
        switch model.apiState {
        case .listening: return Light.mint
        case .failed: return Light.rose
        default: return Ink.tertiary
        }
    }

    private var cliLine: String {
        switch cliStatus {
        case .installed: return "macrophone and mp are in \(CLIInstaller.directory.path)."
        case .notInstalled: return "Adds macrophone and its short name mp to \(CLIInstaller.directory.path). Asks for your password once."
        case .otherCopy: return "mp points at another copy of Macrophone. Reinstall to use this one."
        }
    }
}
