import MacrophoneKit
import SwiftUI

/// Open an app (Oct 14 2026): every app installed on the Mac, by name. Tapping one opens it on the
/// Mac, brings it forward and makes it where you send. Reached from "More apps" at the end of the
/// Send to row.
struct OpenAppSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

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
                        Button { open(app) } label: { AppRow(app: app) }
                            .listRowBackground(Ink.raised)
                            .accessibilityHint(app.running ? "Brings \(app.name) forward on your Mac and sends there." : "Opens \(app.name) on your Mac and sends there.")
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Ink.ground)
            .navigationTitle("Open an app")
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
                if app.running {
                    Text("Open").font(.footnote).foregroundStyle(Ink.tertiary)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(app.running ? "\(app.name), open on your Mac" : app.name)
        }
    }
}
