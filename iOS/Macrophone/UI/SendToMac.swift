import MacrophoneKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// Photos, files and the clipboard, to and from the Mac (Oct 18 2026) — one set of menu items and
// pickers, used by Send to's ⋯ menu and the watch view's Window menu. A photo or file goes into
// the chat you send to (or the window you watch); the clipboard moves only when you ask.

/// The menu items, by what the Mac can do.
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
                Section {
                    Button { pick(photo: true, downloads: true) } label: { Label("Save a Photo to Mac's Downloads…", systemImage: "photo") }
                    Button { pick(photo: false, downloads: true) } label: { Label("Save a File to Mac's Downloads…", systemImage: "doc") }
                }
            } else {
                Section {
                    Button { pick(photo: true, downloads: false) } label: { Label("Send a Photo…", systemImage: "photo") }
                    Button { pick(photo: false, downloads: false) } label: { Label("Send a File…", systemImage: "doc") }
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
            Section {
                Button { model.copyMacClipboard() } label: {
                    Label("Copy Mac's Clipboard", systemImage: "arrow.down.doc")
                }
                Button { model.sendClipboardToMac() } label: {
                    Label("Send Clipboard to Mac", systemImage: "arrow.up.doc")
                }
            }
        }
    }

    private func pick(photo: Bool, downloads: Bool) {
        model.attachToDownloads = downloads
        if photo { pickingPhoto = true } else { pickingFile = true }
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
