import MacrophoneKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// Photos, files and the clipboard, to and from the Mac (Oct 18 2026) — one set of menu items and
// pickers. A photo or file goes into the chat you send to (or the window you watch); the clipboard
// moves only when you ask.
//
// Attach (Nov 7 2026, Sameer: "doesn't have perspective on what should be easy to access vs buried
// in a menu"): the items had been behind an unlabelled ⋯ at rest, low in the Window menu while
// watching and in the cover bar's ⋯ — three places, none of them obvious. Now one paperclip,
// "Attach", in plain sight in every state: the Dock's options bar, the window's key row, the
// Duo deck's header, the cover's vertical bar.

/// The menu items, by what the Mac can do: Photo… · File… · Send Clipboard to Mac · Copy Mac's
/// Clipboard — what goes to the Mac first, what comes back last.
struct MacShareItems: View {
    @EnvironmentObject var model: AppModel
    @Binding var pickingPhoto: Bool
    @Binding var pickingFile: Bool

    var body: some View {
        if model.canAttach {
            // Save to Mac's Downloads (Oct 19 2026): where the place has no chat to paste into
            // (the clipboard, Finder, the whole screen) that's what a photo or file does, and the
            // items say so; everywhere else it's one more choice under them.
            if model.canSaveToDownloads, SaveToDownloads.isDefault(for: model.attachTarget) {
                Section("To your Mac's Downloads") {
                    Button { pick(photo: true, downloads: true) } label: { Label("Photo…", systemImage: "photo") }
                    Button { pick(photo: false, downloads: true) } label: { Label("File…", systemImage: "doc") }
                }
            } else {
                Section("Into \(Places.appName(model.attachTarget, in: model))") {
                    Button { pick(photo: true, downloads: false) } label: { Label("Photo…", systemImage: "photo") }
                    Button { pick(photo: false, downloads: false) } label: { Label("File…", systemImage: "doc") }
                    if model.canSaveToDownloads {
                        Menu {
                            Button { pick(photo: true, downloads: true) } label: { Label("A Photo…", systemImage: "photo") }
                            Button { pick(photo: false, downloads: true) } label: { Label("A File…", systemImage: "doc") }
                        } label: {
                            Label("Save to Mac's Downloads", systemImage: "square.and.arrow.down")
                        }
                    }
                }
            }
        }
        if model.canShareClipboard {
            Section("Clipboard") {
                Button { model.sendClipboardToMac() } label: {
                    Label("Send Clipboard to Mac", systemImage: "arrow.up.doc")
                }
                Button { model.copyMacClipboard() } label: {
                    Label("Copy Mac's Clipboard", systemImage: "arrow.down.doc")
                }
            }
        }
    }

    private func pick(photo: Bool, downloads: Bool) {
        model.attachToDownloads = downloads
        if photo { pickingPhoto = true } else { pickingFile = true }
    }
}

/// Attach: the paperclip, the share items in its menu. The pickers stay with whoever owns the
/// bindings (`macSharePickers`), outside any `ViewThatFits` that lays this out more than once.
struct AttachMenu: View {
    enum Style {
        /// The glyph and "Attach" (the Dock's options bar); `.glyph` where the word doesn't fit.
        case labelled, glyph
        /// A round glass button (the Send to panel's buttons).
        case round
        /// A glass cell of the window's key row or header (the caller draws the glass).
        case cell(height: CGFloat)
        /// A toolbar item (the vertical bar): the system draws it.
        case bar
    }

    @EnvironmentObject var model: AppModel
    var style: Style
    @Binding var pickingPhoto: Bool
    @Binding var pickingFile: Bool

    /// Anything to attach on this Mac (a Mac from before offers neither).
    /// While the link only looks up (the return grace, `looksConnected`) it keeps what the Mac
    /// offered last time (`bar.had.attach`), so the paperclip never pops out and back on a return;
    /// a reconnect keeps it in its place too (the key row holds its layout, `Phase.holdsLayout`).
    @MainActor static func available(_ model: AppModel) -> Bool {
        let now = model.canAttach || model.canShareClipboard
        let d = UserDefaults.standard
        if model.isConnected {
            if d.bool(forKey: "bar.had.attach") != now { d.set(now, forKey: "bar.had.attach") }
            return now
        }
        return (model.looksConnected || model.reconnecting) && d.bool(forKey: "bar.had.attach")
    }

    var body: some View {
        styled(Menu {
            MacShareItems(pickingPhoto: $pickingPhoto, pickingFile: $pickingFile)
        } label: {
            label
        })
        .accessibilityLabel("Attach")
        .accessibilityHint(hint)
        .accessibilityIdentifier("attach-menu")
    }

    @ViewBuilder private var label: some View {
        switch style {
        case .labelled:
            HStack(spacing: 6) {
                Image(systemName: "paperclip").font(.footnote.weight(.semibold)).foregroundStyle(Light.cyan)
                Text("Attach").font(.subheadline.weight(.medium)).foregroundStyle(Ink.ink)
            }
            .fixedSize()
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        case .glyph:
            Image(systemName: "paperclip").font(.subheadline.weight(.semibold)).foregroundStyle(Ink.ink)
                .frame(width: 44).frame(maxHeight: .infinity).contentShape(Rectangle())
        case .round:
            Image(systemName: "paperclip").font(.subheadline.weight(.bold)).frame(width: 20, height: 20)
        case .cell:
            Image(systemName: "paperclip").font(.subheadline.weight(.semibold))
        case .bar:
            Label("Attach", systemImage: "paperclip")
        }
    }

    @ViewBuilder private func styled<V: View>(_ menu: V) -> some View {
        switch style {
        case .labelled, .glyph: menu.buttonStyle(.plain)
        case .round: menu.nativeGlassButton().buttonBorderShape(.circle).controlSize(.small)
        case .cell(let height): menu.buttonStyle(WatchCellStyle(width: 42, height: height))
        case .bar: menu
        }
    }

    private var hint: String {
        let t = model.attachTarget
        if model.canAttach, model.canSaveToDownloads, SaveToDownloads.isDefault(for: t) {
            return "Saves a photo or file to your Mac's Downloads, or moves the clipboard."
        }
        return model.canAttach ? "Sends a photo or file into \(Places.appName(t, in: model)), or moves the clipboard." : "Moves the clipboard between your iPhone and your Mac."
    }
}

extension View {
    /// The photo and file pickers the share items open.
    func macSharePickers(photo: Binding<Bool>, file: Binding<Bool>, model: AppModel) -> some View {
        modifier(MacSharePickers(photo: photo, file: file, model: model))
    }
}

private struct MacSharePickers: ViewModifier {
    @Binding var photo: Bool
    @Binding var file: Bool
    let model: AppModel
    @State private var item: PhotosPickerItem?

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $photo, selection: $item, matching: .images, preferredItemEncoding: .compatible)
            .onChange(of: item) { _, picked in
                guard let picked else { return }
                item = nil
                Task {
                    guard let data = try? await picked.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                        model.explain("Couldn't read that photo")
                        return
                    }
                    model.sendPhoto(image)
                }
            }
            .fileImporter(isPresented: $file, allowedContentTypes: [.item]) { result in
                if case let .success(url) = result { model.sendFile(url) }
            }
    }
}
