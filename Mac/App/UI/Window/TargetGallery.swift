import MacrophoneKit
import SwiftUI

/// "Add a target": the apps Macrophone knows how to drive, plus any other app.
struct TargetGallery: View {
    @ObservedObject var store: ProfileStore
    /// The new profile, saved; the caller opens it in the editor.
    var added: (Profile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pickingApp = false

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add a Target").font(Typeface.serif(24)).foregroundStyle(Ink.ink)
                Text("Dictate straight into an app. Macrophone brings it forward, finds the message box, pastes, and sends — after a 2.5-second countdown you can cancel.")
                    .font(.system(size: 12.5)).foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Kicker("Ready-made")
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(ReadyMade.items) { item in
                            card(icon: item.spec.icon, title: item.name, line: item.line,
                                 installed: item.spec.isInstalled, exists: store.hasTarget(item),
                                 sends: item.spec.sendsByDefault) {
                                let p = ReadyMade.profile(for: item)
                                store.upsert(p)
                                added(p)
                            }
                        }
                    }
                    Kicker("More apps")
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(TargetCatalog.all.filter { s in !ReadyMade.items.contains { $0.spec.id == s.id } }) { spec in
                            card(icon: spec.icon, title: spec.name, line: spec.blurb, installed: spec.isInstalled,
                                 exists: false, sends: spec.sendsByDefault) {
                                let p = ReadyMade.profile(for: spec)
                                store.upsert(p)
                                added(p)
                            }
                        }
                        Button { pickingApp = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.app").font(.system(size: 20, weight: .light)).foregroundStyle(Ink.secondary)
                                    .frame(width: 34, height: 34)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Any app…").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.ink)
                                    Text("Pastes where the cursor is. You choose whether it sends.")
                                        .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.raised.opacity(0.5)))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Apps that reach other people, like Slack, never send on their own unless you turn it on.")
                        .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
            Rectangle().fill(Ink.line).frame(height: 1)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 620, height: 640)
        .background(Ink.ground)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $pickingApp) {
            AppPickerSheet(title: "Send to…") { app in
                let spec = TargetCatalog.spec(for: app.bundleID) ?? TargetCatalog.generic(bundleID: app.bundleID, name: app.name)
                let p = ReadyMade.profile(for: spec, name: app.name)
                store.upsert(p)
                added(p)
            }
        }
    }

    private func card(icon: NSImage?, title: String, line: String, installed: Bool, exists: Bool, sends: Bool,
                      add: @escaping () -> Void) -> some View {
        Button(action: add) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let icon { Image(nsImage: icon).resizable() } else {
                        Image(systemName: "app.dashed").font(.system(size: 20, weight: .light)).foregroundStyle(Ink.tertiary)
                    }
                }
                .frame(width: 34, height: 34)
                .opacity(installed ? 1 : 0.45)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.ink)
                        if exists { Chip(text: "Added", color: Light.mint, icon: "checkmark") }
                        else if !installed { Chip(text: "Not installed", color: Ink.tertiary) }
                        else if sends { Chip(text: "Sends", color: Light.cyan) }
                    }
                    Text(line).font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.raised.opacity(0.72)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(line)\(installed ? "" : " Not installed.")")
    }
}
