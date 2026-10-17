import AppKit
import MacrophoneKit
import SwiftUI
import UniformTypeIdentifiers

enum Diagnostics {
    static var macModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    @MainActor
    static func header(_ model: AppModel) -> [(String, String)] {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let listener: String
        switch model.listenerState {
        case .ready(let p): listener = "ready (port \(p))"
        case .starting: listener = "starting"
        case .failed(let e): listener = "failed: \(e)"
        }
        let api: String
        switch model.apiState {
        case .listening(let p): api = "listening on 127.0.0.1:\(p)"
        case .off: api = "off"
        case .starting: api = "starting"
        case .failed(let s): api = "failed: \(s)"
        }
        return [
            ("App", "\(Product.name) \(AppPaths.appVersion) (\(AppPaths.buildNumber))\(AppPaths.isDebugBuild ? " debug" : "")"),
            ("macOS", "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"),
            ("Mac model", macModel),
            ("Network listener", listener),
            ("Local API", api),
            ("Paired phones", "\(model.peers.count) (\(model.connected.count) connected\(model.remotePeers.isEmpty ? "" : ", \(model.remotePeers.count) from away"))"),
            ("Remote access", model.settings.remoteAccess ? "on, port \(model.settings.remotePort), \(model.remoteAddresses.count) address(es), Tailscale \(model.tailscaleAddress == nil ? "not running" : "running")" : "off"),
            ("Send to", AppModel.kind(model.settings.selection)),
            ("Apps with somewhere to type", "\(model.targets.count)"),
            ("Accessibility granted", model.accessibilityGranted ? "yes" : "no"),
            ("History", model.settings.historyEnabled ? "on (\(model.history.count) items)" : "off"),
        ]
    }
}

/// Read it before you send it: the whole log, then Save or Share.
struct DiagnosticsView: View {
    @ObservedObject var model: AppModel
    var close: () -> Void
    @State private var text = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Share Diagnostics").font(Typeface.serif(24)).foregroundStyle(Ink.ink)
                Text("This is everything that will be shared. It never includes what you dictated, your pairing keys or your API token.")
                    .font(.system(size: 12.5)).foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 18)
            ScrollView {
                Text(text)
                    .font(Typeface.mono(11, .regular))
                    .foregroundStyle(Ink.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.sunk))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.line, lineWidth: 1))
            HStack(spacing: 10) {
                Button(copied ? "Copied" : "Copy") {
                    Clipboard.copyPlain(text); copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                }
                .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                Spacer()
                Button("Close", action: close).buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                Button("Save…") { save() }
                    .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                ShareButton(text: text, fileName: fileName)
                    .frame(width: 92, height: 28)
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 20)
        .frame(minWidth: 560, minHeight: 480)
        .background(Ink.ground)
        .preferredColorScheme(.dark)
        .onAppear { text = model.log.export(header: Diagnostics.header(model)) }
    }

    private var fileName: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"
        return "Macrophone diagnostics \(f.string(from: Date())).txt"
    }

    private func save() {
        let p = NSSavePanel()
        p.nameFieldStringValue = fileName
        p.allowedContentTypes = [.plainText]
        if p.runModal() == .OK, let url = p.url { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }
}

/// The system share menu (Mail, Messages, AirDrop…), sharing the log as a .txt file.
struct ShareButton: NSViewRepresentable {
    let text: String
    let fileName: String

    func makeNSView(context: Context) -> NSButton {
        let b = NSButton(title: "Share…", target: context.coordinator, action: #selector(Coordinator.share(_:)))
        b.bezelStyle = .rounded
        b.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        b.imagePosition = .imageLeading
        b.keyEquivalent = "\r"
        return b
    }

    func updateNSView(_ b: NSButton, context: Context) { context.coordinator.parent = self }
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: ShareButton
        init(parent: ShareButton) { self.parent = parent }
        @objc func share(_ sender: NSButton) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(parent.fileName)
            try? parent.text.write(to: url, atomically: true, encoding: .utf8)
            NSSharingServicePicker(items: [url]).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
