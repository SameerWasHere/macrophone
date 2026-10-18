import MacrophoneKit
import SwiftUI

// Reader (Oct 18 2026, Sameer: "Reader mode should be an alternative to the window view but window
// should still be the default"): the watched window's words as real text — your text size, full
// width, selectable — instead of its picture. A terminal's own text in a monospaced face; any other
// app's words read off its window (the column you type in). It follows the newest line unless you
// scroll up; it shows what's on the window now, so scrolling the Mac's window (Scroll, or the keys)
// brings more. The keys and the mic work as they do over the picture.

/// The header's switch between the picture and the words (in the zoom-out / Window cluster).
struct WatchReaderButton: View {
    @ObservedObject var watcher: Watcher

    var body: some View {
        Button { watcher.setReading(!watcher.reading) } label: {
            Image(systemName: "text.alignleft")
                .font(.subheadline.weight(.semibold))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(WatchCellStyle(width: 44, tint: watcher.reading ? Light.cyan : Ink.ink))
        .disabled(watcher.phase != .live)
        .accessibilityLabel(watcher.reading ? "Show the window" : "Show as text")
        .accessibilityHint(watcher.reading ? "Back to the picture of \(watcher.name)'s window." : "Shows the words in \(watcher.name)'s window as text you can read and copy.")
        .accessibilityIdentifier("watch-reader")
    }
}

/// The words, on the same screen shape the picture sits in.
struct WatchReaderView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var watcher: Watcher
    /// He scrolled up to read back: the newest line no longer pulls the view down (for a while).
    @State private var heldAt = Date.distantPast
    @State private var copied = false

    private static let bottom = "reader-bottom"

    var body: some View {
        let page = model.readerPage
        ZStack(alignment: .bottomTrailing) {
            Ink.raised
            if let page, !page.lines.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(page.lines.joined(separator: "\n"))
                                .font(page.monospaced ? .system(.footnote, design: .monospaced) : .body)
                                .foregroundStyle(Ink.ink)
                                .lineSpacing(page.monospaced ? 1 : 3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if page.fromPicture {
                                Text("Read off the window — a word may be misread")
                                    .font(.caption)
                                    .foregroundStyle(Ink.tertiary)
                                    .padding(.top, 14)
                            }
                            Color.clear.frame(height: 52).id(Self.bottom)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                    }
                    .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in heldAt = Date() })
                    .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                    .onChange(of: page.lines.last) { _, _ in
                        // The newest line, unless he's reading back (a touch in the last eight seconds).
                        guard Date().timeIntervalSince(heldAt) > 8 else { return }
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                    }
                }
                copyButton(page)
            } else {
                VStack(spacing: 10) {
                    if page == nil {
                        ProgressView().tint(Ink.tertiary)
                        Text("Reading \(watcher.name)'s window…")
                    } else {
                        Image(systemName: "text.page.slash").font(.title3)
                        Text("No words on \(watcher.name)'s window right now")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: WatchLook.screen, style: .continuous))
        .padding(WatchLook.bezelWidth)
        .background(RoundedRectangle(cornerRadius: WatchLook.bezel, style: .continuous).fill(Ink.sunk))
        .overlay(RoundedRectangle(cornerRadius: WatchLook.bezel, style: .continuous).strokeBorder(Ink.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(watcher.name)'s window as text")
    }

    private func copyButton(_ page: ReaderPage) -> some View {
        Button {
            UIPasteboard.general.string = page.lines.joined(separator: "\n")
            Haptics.success()
            withAnimation(.easeOut(duration: 0.2)) { copied = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                withAnimation(.easeIn(duration: 0.3)) { copied = false }
            }
        } label: {
            Label(copied ? "Copied" : "Copy All", systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.footnote.weight(.semibold))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(WatchCellStyle(inset: 14))
        .watchGlass(Capsule())
        .padding(10)
        .accessibilityHint("Copies the text to this iPhone.")
    }
}
