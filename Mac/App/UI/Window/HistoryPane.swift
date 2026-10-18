import MacrophoneKit
import SwiftUI

struct HistoryPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings
    @State private var query = ""
    @State private var confirmClear = false
    @FocusState private var searchFocused: Bool

    private var items: [HistoryItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.history }
        return model.history.filter {
            $0.dictation.raw.localizedCaseInsensitiveContains(q)
                || ($0.dictation.cleaned ?? "").localizedCaseInsensitiveContains(q)
                || $0.profileName.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        PanePage {
            PaneHeader(title: "History", subtitle: "Your last 50 dictations. They stay on this Mac — separate from your iPhone's history.")

            HStack(spacing: Space.gap) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Ink.tertiary).font(.system(size: 12))
                        .accessibilityHidden(true)
                    TextField("Search dictations", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($searchFocused)
                        .accessibilityLabel("Search dictations")
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Ink.tertiary)
                                .frame(width: 18, height: 18).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .help("Clear the search")
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Ink.well))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Ink.lineStrong, lineWidth: 1))
                .fieldFocusRing(searchFocused)
                .onTapGesture { searchFocused = true }
                // ⌘F lands in the search, as everywhere on the Mac. The button draws nothing.
                .background(Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true))

                Toggle("Keep history", isOn: $settings.historyEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 12.5))
                    .fixedSize()
                    .help("When off, nothing is written to disk. Tools using the API can still read the latest dictation.")

                Button("Clear All…") { confirmClear = true }
                    .buttonStyle(PillButtonStyle(tint: Light.rose, filled: false))
                    .disabled(model.history.isEmpty)
                    .help("Delete every dictation kept on this Mac")
                    .confirmationDialog("Clear all history on this Mac?", isPresented: $confirmClear) {
                        Button("Clear All", role: .destructive) { model.clearHistory() }
                    } message: {
                        Text("Your iPhone's history isn't affected.")
                    }
            }

            if !settings.historyEnabled {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "eye.slash").foregroundStyle(Light.ochre)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    Text("History is off. Nothing is saved to disk; tools using the API can still read the latest dictation until Macrophone quits.")
                        .font(.system(size: 12.5)).foregroundStyle(Ink.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.plate, style: .continuous).fill(Light.ochre.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: Radius.plate, style: .continuous).strokeBorder(Light.ochre.opacity(0.22), lineWidth: 1))
                .accessibilityElement(children: .combine)
            }

            if items.isEmpty {
                empty
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(items) { item in
                        // With more than one phone, say which one each came from.
                        HistoryRow(item: item, device: model.peers.count > 1 ? item.dictation.sourceDevice : nil,
                                   onDelete: { model.deleteHistoryItem(item.id) })
                    }
                }
                .animation(Motion.reduceMotion ? nil : Motion.depart, value: items.map(\.id))
            }
        }
    }

    private var empty: some View {
        EmptyState(title: query.isEmpty ? (settings.historyEnabled ? "Nothing yet" : "History is off") : "No matches",
                   detail: query.isEmpty
                       ? (settings.historyEnabled ? "Dictate on your iPhone — it shows up here, newest first."
                                                  : "Turn Keep history on and the next dictation shows up here.")
                       : "Nothing here says “\(query.trimmingCharacters(in: .whitespaces))”. Try other words.") {
            FilamentView(peak: 0.15, thick: 1.6, tint: Ink.tertiary, glow: 0.3)
                .frame(width: 160, height: 24)
        }
    }
}

struct HistoryRow: View {
    let item: HistoryItem
    var device: String?
    var onDelete: () -> Void
    @State private var showRaw = false
    @State private var copied = false
    @State private var hover = false

    private var shown: String { showRaw ? item.dictation.raw : item.dictation.text }
    private var rtl: Bool { TextDirection.isRTL(shown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(timeLabel).font(Typeface.mono(10.5, .medium)).foregroundStyle(Ink.tertiary)
                Chip(text: item.profileName, color: Ink.secondary)
                    .help("Where it went")
                Chip(text: cleanupLabel, color: Ink.tertiary, icon: "wand.and.stars")
                    .help("The cleanup level, chosen on your iPhone")
                    .accessibilityLabel("Cleanup: \(item.dictation.cleanupLevel.title)")
                if item.delayed { Chip(text: "Delayed", color: Light.ochre, icon: "clock") }
                if item.dictation.stoppedEarly { Chip(text: "Stopped early", color: Light.ochre) }
                Spacer(minLength: 6)
                if item.hasCleanedVersion {
                    Picker("", selection: $showRaw) {
                        Text("Cleaned").tag(false)
                        Text("Raw").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .help("Raw is exactly what was heard; Cleaned is what was delivered.")
                    .accessibilityLabel("Version shown")
                }
                Button {
                    Clipboard.copyPlain(shown)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(copied ? Light.mint : Ink.secondary)
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(.borderless)
                .help(showRaw ? "Copy the raw transcript" : "Copy")
                .accessibilityLabel(showRaw ? "Copy the raw transcript" : "Copy")
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityLabel("More actions")
            }
            Text(shown)
                .font(Typeface.serif(15))
                .foregroundStyle(Ink.ink)
                .lineSpacing(3)
                .multilineTextAlignment(.leading) // leading is the right edge under .rightToLeft
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
                // Not .textSelection: a selectable Text is backed by an AppKit text view whose
                // layer can draw upside down when the row arrives mid-animation (seen live,
                // Oct 13 2026). Copy and Copy Raw are in the row's buttons.
            if !detailLine.isEmpty {
                Text(detailLine)
                    .font(.system(size: 11)).foregroundStyle(outcomeColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Space.inset).padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: Radius.plate, style: .continuous).fill(Ink.raised.opacity(hover ? 0.95 : 0.72)))
        .overlay(RoundedRectangle(cornerRadius: Radius.plate, style: .continuous).strokeBorder(hover ? Ink.lineStrong : Ink.line, lineWidth: 1))
        .onHover { hover = $0 }
        .animation(Motion.reduceMotion ? nil : .easeOut(duration: 0.15), value: hover)
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dictation, \(timeLabel), \(item.profileName)")
    }

    @ViewBuilder private var menuItems: some View {
        Button("Copy") { Clipboard.copyPlain(item.dictation.text) }
        if item.hasCleanedVersion { Button("Copy Raw Transcript") { Clipboard.copyPlain(item.dictation.raw) } }
        Divider()
        Button("Delete", role: .destructive, action: onDelete)
    }

    /// "Medium", "Custom", "No cleanup".
    private var cleanupLabel: String {
        item.dictation.cleanupLevel == .off ? "No cleanup" : item.dictation.cleanupLevel.title
    }

    private var detailLine: String {
        guard let device, !device.isEmpty else { return item.detail }
        return item.detail.isEmpty ? "From \(device)" : "\(item.detail) · from \(device)"
    }

    private var timeLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(item.receivedAt) { return item.receivedAt.clockTime }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d j:mm")
        return f.string(from: item.receivedAt)
    }

    private var outcomeColor: Color {
        switch item.outcome {
        case .failed: return Light.rose
        case .cancelled: return Ink.tertiary
        default: return Ink.tertiary
        }
    }
}
