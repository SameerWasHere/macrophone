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
            PaneHeader(title: "Developer", subtitle: "Scripts and agents can read what you dictate through a local API, a command-line tool and an MCP server. Only this Mac can reach it.")

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Local API")
                Plate {
                    PlateRow(title: "Local API", subtitle: apiLine, subtitleColor: apiColor,
                             icon: "network", iconColor: apiColor == Light.mint ? Light.mint : Ink.secondary) {
                        Toggle("", isOn: $settings.apiEnabled).toggleStyle(.switch).labelsHidden()
                    }
                    PlateDivider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Token").font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.ink)
                            Spacer()
                            Button(reveal ? "Hide" : "Show") { reveal.toggle() }.buttonStyle(.borderless)
                            Button("Regenerate…") { confirmRegenerate = true }.buttonStyle(.borderless)
                                .confirmationDialog("Make a new token?", isPresented: $confirmRegenerate) {
                                    Button("Regenerate", role: .destructive) { model.regenerateToken() }
                                } message: {
                                    Text("Anything using the old token stops working. The command-line tool and MCP server pick up the new one by themselves.")
                                }
                        }
                        CodePlate(text: reveal ? model.apiToken : masked, copyText: model.apiToken)
                        Text("Also saved for local tools in ~/Library/Application Support/Macrophone/api.json (readable only by you).")
                            .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                    }
                    .padding(16)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Command-line tool")
                Plate {
                    PlateRow(title: "macrophone and mp",
                             subtitle: cliLine,
                             subtitleColor: cliStatus == .installed ? Light.mint : Ink.tertiary,
                             icon: "terminal") {
                        Button(cliStatus == .installed ? "Reinstall" : "Install…") {
                            cliMessage = CLIInstaller.install()
                            cliStatus = CLIInstaller.status
                        }
                        .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: cliStatus != .installed))
                    }
                    if let cliMessage {
                        Text(cliMessage).font(.system(size: 11.5)).foregroundStyle(Light.rose)
                            .padding(.horizontal, 16).padding(.bottom, 10)
                    }
                    PlateDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        snippetTitle("Try it")
                        CodePlate(text: "mp              # the latest dictation\nmp wait | pbcopy   # wait for the next one\nmp watch --json  # every new one, as JSON lines")
                    }
                    .padding(16)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("MCP server")
                Plate {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Gives Claude and other agents three tools: get the latest dictation, list recent ones, and wait for the next.")
                            .font(.system(size: 12.5)).foregroundStyle(Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 6) {
                            snippetTitle("Claude Code")
                            CodePlate(text: "claude mcp add macrophone -- macrophone mcp")
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            snippetTitle("Claude Desktop — claude_desktop_config.json")
                            CodePlate(text: """
                            {
                              "mcpServers": {
                                "macrophone": {
                                  "command": "/usr/local/bin/macrophone",
                                  "args": ["mcp"]
                                }
                              }
                            }
                            """)
                        }
                    }
                    .padding(16)
                }
            }

            ClaudeKeySection()

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("HTTP")
                Plate {
                    VStack(alignment: .leading, spacing: 6) {
                        snippetTitle("curl")
                        CodePlate(text: curl(reveal ? model.apiToken : masked), copyText: curl(model.apiToken))
                        Text("Also /v1/history?limit=10, /v1/next?timeout=60 (waits for the next one), /v1/stream (server-sent events) and /v1/status. Requests from web pages are always refused.")
                            .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Link("Read the API docs", destination: Product.docs)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Light.teal)
                            .padding(.top, 4)
                    }
                    .padding(16)
                }
            }
        }
        .onAppear { cliStatus = CLIInstaller.status }
    }

    private func curl(_ token: String) -> String {
        "curl -s -H \"Authorization: Bearer \(token)\" \\\n  http://127.0.0.1:\(port)/v1/latest"
    }

    private func snippetTitle(_ s: String) -> some View {
        Text(s).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.secondary)
    }

    private var apiLine: String {
        switch model.apiState {
        case .listening(let p): return "Listening on 127.0.0.1:\(p) — this Mac only, token required."
        case .starting: return "Starting…"
        case .off: return "Off. The command-line tool and MCP server can't read dictations."
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
        case .installed: return "Installed in \(CLIInstaller.directory.path)."
        case .notInstalled: return "Adds macrophone and its short name mp to \(CLIInstaller.directory.path). Asks for your password once."
        case .otherCopy: return "Points at another copy of Macrophone. Reinstall to use this one."
        }
    }
}

/// Developer › Claude API key: for profiles that "Ask Claude".
struct ClaudeKeySection: View {
    @State private var saved = ClaudeKey.load()
    @State private var draft = ""
    @State private var testing = false
    @State private var result: String?
    @State private var resultOK = false
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Claude API key")
            Plate {
                PlateRow(title: "Anthropic API key",
                         subtitle: "Used only by automations with an “Ask Claude” action. Those send what you dictate to Anthropic; billing is on your account. Kept in your keychain, never in diagnostics.",
                         icon: saved == nil ? "key" : "key.fill", iconColor: saved == nil ? Ink.secondary : Light.mint) { EmptyView() }
                PlateDivider()
                VStack(alignment: .leading, spacing: 10) {
                    if let saved {
                        HStack(spacing: 10) {
                            Text(ClaudeKey.masked(saved)).font(Typeface.mono(12, .regular)).foregroundStyle(Ink.ink)
                            Spacer()
                            Button(testing ? "Testing…" : "Test Key") { test(saved) }
                                .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                                .disabled(testing)
                            Button("Remove…") { confirmRemove = true }
                                .buttonStyle(PillButtonStyle(tint: Light.rose, filled: false))
                                .confirmationDialog("Remove your API key?", isPresented: $confirmRemove) {
                                    Button("Remove", role: .destructive) { ClaudeKey.delete(); self.saved = nil; result = nil }
                                } message: { Text("Automations that ask Claude will stop until you add a key again.") }
                        }
                    } else {
                        HStack(spacing: 10) {
                            SecureField("sk-ant-…", text: $draft)
                                .textFieldStyle(.roundedBorder)
                                .font(Typeface.mono(12, .regular))
                                .onSubmit(saveDraft)
                            Button("Save") { saveDraft() }
                                .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: true))
                                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).count < 20)
                        }
                        Link("Get a key at console.anthropic.com", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Light.teal)
                    }
                    if let result {
                        Label(result, systemImage: resultOK ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 11.5)).foregroundStyle(resultOK ? Light.mint : Light.rose)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Test Key asks Anthropic which models the key can use — it costs nothing.")
                        .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                }
                .padding(16)
            }
        }
    }

    private func saveDraft() {
        let k = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k.count >= 20 else { return }
        if ClaudeKey.save(k) {
            saved = k
            draft = ""
            test(k)
        } else {
            result = "Couldn't save it to the keychain."
            resultOK = false
        }
    }

    private func test(_ key: String) {
        testing = true
        result = nil
        Task {
            let r = await ClaudeClient.test(key: key, session: DeliveryEngine.claudeSession)
            testing = false
            switch r {
            case .success: result = "Works — Claude accepted the key."; resultOK = true
            case .failure(let f): result = f.title + ". " + f.detail; resultOK = false
            }
        }
    }
}
