import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An installed app: name, bundle id, where it lives.
struct InstalledApp: Identifiable, Hashable {
    var name: String
    var bundleID: String
    var url: URL
    var id: String { bundleID }

    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }

    static func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static func at(_ url: URL) -> InstalledApp? {
        guard let b = Bundle(url: url), let id = b.bundleIdentifier else { return nil }
        let name = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        var display = FileManager.default.displayName(atPath: url.path)
        if display.hasSuffix(".app") { display = String(display.dropLast(4)) }
        return InstalledApp(name: display.isEmpty ? name : display, bundleID: id, url: url)
    }

    /// Apps in /Applications, ~/Applications and the system's, one level of folders deep.
    static func scan() -> [InstalledApp] {
        let fm = FileManager.default
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                     fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var found: [String: InstalledApp] = [:]
        for root in roots {
            guard let list = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in list {
                let url = URL(fileURLWithPath: root).appendingPathComponent(entry)
                if entry.hasSuffix(".app") {
                    if let a = at(url), found[a.bundleID] == nil { found[a.bundleID] = a }
                } else if !entry.hasPrefix("."), (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          let inner = try? fm.contentsOfDirectory(atPath: url.path) {
                    for e in inner where e.hasSuffix(".app") {
                        if let a = at(url.appendingPathComponent(e)), found[a.bundleID] == nil { found[a.bundleID] = a }
                    }
                }
            }
        }
        return found.values
            .filter { $0.bundleID != Bundle.main.bundleIdentifier }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @MainActor
    static func chooseWithPanel() -> InstalledApp? {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.prompt = "Choose"
        guard p.runModal() == .OK, let url = p.url else { return nil }
        return at(url)
    }
}

/// A searchable list of installed apps.
struct AppPickerSheet: View {
    var title: String
    var exclude: Set<String> = []
    var onPick: (InstalledApp) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [InstalledApp] = []
    @State private var query = ""

    private var filtered: [InstalledApp] {
        let list = apps.filter { !exclude.contains($0.bundleID) }
        guard !query.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Typeface.serif(20)).foregroundStyle(Ink.ink)
            TextField("Search apps", text: $query)
                .textFieldStyle(.roundedBorder)
            List(filtered) { app in
                Button {
                    onPick(app)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(nsImage: app.icon).resizable().frame(width: 22, height: 22)
                        Text(app.name).foregroundStyle(Ink.ink)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(RoundedRectangle(cornerRadius: 10).fill(Ink.sunk))
            HStack {
                Button("Other…") {
                    if let a = InstalledApp.chooseWithPanel() { onPick(a); dismiss() }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 400, height: 480)
        .background(Ink.ground)
        .preferredColorScheme(.dark)
        .task { apps = await Task.detached { InstalledApp.scan() }.value }
    }
}
