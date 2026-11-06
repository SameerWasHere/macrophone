import MacrophoneKit
import SwiftUI

/// Open an app (Oct 14 2026): every app installed on the Mac, by name. Tapping one opens it on the
/// Mac, brings it forward and makes it where you send. Reached from "More apps" at the end of the
/// Send to row. An open app has a Quit button (Oct 17 2026), asked to confirm: quitting can end an
/// agent's session, and the Mac may ask first (unsaved work, a running process). A native sheet
/// since Nov 1 2026: the open apps first, then the rest, as Launchpad's search would list them.
struct OpenAppSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var toQuit: MacApp?

    private var shown: [MacApp] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.macApps }
        return model.macApps.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !model.isConnected {
                    EmptyState(symbol: "laptopcomputer.slash", title: "\(model.pairedMac?.name ?? "Your Mac") isn't connected",
                               message: "Its apps show up here once it is — make sure Macrophone is open on it.") {
                        WakeMacAction()
                    }
                } else if !model.macAppsLoaded {
                    ProgressView("Asking your Mac")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if shown.isEmpty, query.trimmingCharacters(in: .whitespaces).isEmpty {
                    EmptyState(symbol: "app.dashed", title: "No apps found",
                               message: "Your Mac didn't list any apps this time.") {
                        Button("Try Again") { Haptics.press(); model.requestMacApps() }
                            .emptyStateButton()
                    }
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    list
                }
            }
            .navigationTitle("Open an App")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search your Mac's apps")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.doneButtonStyle() }
            }
        }
        .tint(Light.cyan)
        .onAppear { model.requestMacApps() }
    }

    private var list: some View {
        let open = shown.filter(\.running), rest = shown.filter { !$0.running }
        return List {
            if !open.isEmpty {
                Section("Open on your Mac") { ForEach(open) { row($0) } }
            }
            if !rest.isEmpty {
                Section("Applications") { ForEach(rest) { row($0) } }
            }
        }
        .confirmationDialog(toQuit.map { "Quit \($0.name) on your Mac?" } ?? "", isPresented: Binding(get: { toQuit != nil }, set: { if !$0 { toQuit = nil } }),
                            titleVisibility: .visible, presenting: toQuit) { app in
            Button("Quit \(app.name)", role: .destructive) { model.quitOnMac(app) }
        } message: { app in
            Text("Anything running in \(app.name) stops. If it has unsaved work or something running, your Mac asks first.")
        }
    }

    private func row(_ app: MacApp) -> some View {
        HStack(spacing: 12) {
            Button { open(app) } label: { AppRow(app: app, showsOpen: !model.canQuitApps) }
                .buttonStyle(.plain)
                .accessibilityHint(app.running ? "Brings \(app.name) forward on your Mac and sends there." : "Opens \(app.name) on your Mac and sends there.")
            if app.running, model.canQuitApps {
                Button(model.quitting.contains(app.bundleID) ? "Quitting…" : "Quit") { toQuit = app }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(Light.rose)
                    .controlSize(.small)
                    .disabled(model.quitting.contains(app.bundleID))
                    .accessibilityLabel("Quit \(app.name)")
                    .accessibilityHint("Quits \(app.name) on your Mac. It may ask there first.")
            }
        }
    }

    private func open(_ app: MacApp) {
        model.openOnMac(app)
        dismiss()
    }

    private struct AppRow: View {
        var app: MacApp
        /// "Open" beside an open app (when there's no Quit button to say it).
        var showsOpen = true
        var body: some View {
            HStack(spacing: 12) {
                if let img = IconCache.image(app.icon) {
                    Image(uiImage: img).resizable().interpolation(.high).scaledToFit().frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                } else {
                    SettingsIcon(symbol: "app.dashed", color: Color(uiColor: .systemGray), size: 32)
                }
                Text(app.name).font(.body).foregroundStyle(Ink.ink)
                Spacer(minLength: 8)
                if app.running, showsOpen {
                    Text("Open").font(.subheadline).foregroundStyle(Ink.secondary)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(app.running ? "\(app.name), open on your Mac" : app.name)
        }
    }
}
