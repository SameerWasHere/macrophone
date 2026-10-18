import MacrophoneKit
import SwiftUI

/// Open an app (Oct 14 2026): every app installed on the Mac, by name. Tapping one opens it on the
/// Mac, brings it forward and makes it where you send. Reached from "More apps" at the end of the
/// Send to row. An open app has a Quit button (Oct 17 2026), asked to confirm: quitting can end an
/// agent's session, and the Mac may ask first (unsaved work, a running process).
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
                    ContentUnavailableView("Your Mac isn't connected", systemImage: "laptopcomputer.slash",
                                           description: Text("Open Macrophone on your Mac, then try again."))
                } else if !model.macAppsLoaded {
                    ProgressView("Asking your Mac").tint(Ink.secondary).foregroundStyle(Ink.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if shown.isEmpty, query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView("No apps found", systemImage: "app.dashed",
                                           description: Text("Your Mac didn't list any apps. Open the Applications folder on your Mac and try again."))
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(shown) { app in
                        HStack(spacing: 12) {
                            Button { open(app) } label: { AppRow(app: app, showsOpen: !model.canQuitApps) }
                                .buttonStyle(.plain)
                                .accessibilityHint(app.running ? "Brings \(app.name) forward on your Mac and sends there." : "Opens \(app.name) on your Mac and sends there.")
                            if app.running, model.canQuitApps {
                                Button(model.quitting.contains(app.bundleID) ? "Quitting…" : "Quit") { toQuit = app }
                                    .font(.footnote.weight(.semibold))
                                    .buttonStyle(.bordered)
                                    .tint(Light.ochre)
                                    .controlSize(.small)
                                    .disabled(model.quitting.contains(app.bundleID))
                                    .accessibilityLabel("Quit \(app.name)")
                                    .accessibilityHint("Quits \(app.name) on your Mac. It may ask there first.")
                            }
                        }
                        .listRowBackground(Ink.raised)
                    }
                    .scrollContentBackground(.hidden)
                    .confirmationDialog(toQuit.map { "Quit \($0.name) on your Mac?" } ?? "", isPresented: Binding(get: { toQuit != nil }, set: { if !$0 { toQuit = nil } }),
                                        titleVisibility: .visible, presenting: toQuit) { app in
                        Button("Quit \(app.name)", role: .destructive) { model.quitOnMac(app) }
                    } message: { app in
                        Text("Anything running in \(app.name) stops. If it has unsaved work or something running, your Mac asks first.")
                    }
                }
            }
            .background(Ink.ground)
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
                    Image(systemName: "app.dashed").font(.title2).foregroundStyle(Ink.tertiary).frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                }
                Text(app.name).font(.body).foregroundStyle(Ink.ink)
                Spacer(minLength: 8)
                if app.running, showsOpen {
                    Text("Open").font(.footnote).foregroundStyle(Ink.tertiary)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(app.running ? "\(app.name), open on your Mac" : app.name)
        }
    }
}
