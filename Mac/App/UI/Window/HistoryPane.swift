import AppKit
import MacrophoneKit
import SwiftUI

/// History as Mail's message list (Nov 7 2026): the days as sections, a row = the place's icon,
/// the app's name in bold and the time, the window's title under it as Mail's subject, then two
/// lines of the words. A click opens a row in place (every word, Cleaned | Raw, Copy); a right
/// click or a swipe copies or deletes; Delete deletes. Search is in the toolbar (⌘F).
struct HistoryPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings
    @State private var query = ""
    @State private var confirmClear = false
    @State private var selection: UUID?

    private var items: [HistoryItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.history }
        return model.history.filter {
            $0.dictation.raw.localizedCaseInsensitiveContains(q)
                || ($0.dictation.cleaned ?? "").localizedCaseInsensitiveContains(q)
                || $0.profileName.localizedCaseInsensitiveContains(q)
        }
    }

    /// The days, newest first: Today, Yesterday, then the date.
    private var days: [(title: String, items: [HistoryItem])] {
        let cal = Calendar.current
        var out: [(String, [HistoryItem])] = []
        for item in items {
            let title = Self.dayTitle(item.receivedAt, cal)
            if let last = out.indices.last, out[last].0 == title { out[last].1.append(item) } else { out.append((title, [item])) }
        }
        return out
    }

    static func dayTitle(_ d: Date, _ cal: Calendar = .current) -> String {
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "EEEEMMMMd" : "EEEEMMMMdy")
        return f.string(from: d)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !settings.historyEnabled, !model.history.isEmpty {
                PaneBanner(symbol: "clock.badge.xmark", title: "History is off",
                           detail: "Nothing new is saved. Tools using the API can still read the latest dictation until Macrophone quits.") {
                    Button("Turn On") { settings.historyEnabled = true }
                }
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
            }
            if items.isEmpty {
                empty.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .searchable(text: $query, placement: .toolbar, prompt: "Search")
        .modifier(FindFocusesSearch())
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.environment["MACROPHONE_HISTORY_OPEN"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { selection = model.history.first?.id }
            }
            #endif
        }
        .confirmationDialog("Clear all history on this Mac?", isPresented: $confirmClear) {
            Button("Clear All", role: .destructive) { model.clearHistory() }
        } message: {
            Text("Your iPhone's history isn't affected.")
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(days, id: \.title) { day in
                Section(day.title) {
                    ForEach(day.items) { item in
                        HistoryRow(item: item, model: model, open: selection == item.id,
                                   device: model.peers.count > 1 || item.dictation.sourceDevice == DeskDictation.source ? item.dictation.sourceDevice : nil)
                            .tag(item.id)
                            .contextMenu { menu(item) }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { delete(item.id) } label: { Label("Delete", systemImage: "trash") }
                            }
                            .swipeActions(edge: .leading) {
                                Button { Clipboard.copyPlain(item.dictation.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                                    .tint(.accentColor)
                            }
                    }
                }
            }
        }
        .listStyle(.inset)
        .onDeleteCommand { if let s = selection { delete(s) } }
        .animation(Motion.reduceMotion ? nil : Motion.settle, value: selection)
        .animation(Motion.reduceMotion ? nil : Motion.depart, value: items.map(\.id))
    }

    @ViewBuilder private func menu(_ item: HistoryItem) -> some View {
        Button("Copy") { Clipboard.copyPlain(item.dictation.text) }
        if item.hasCleanedVersion { Button("Copy Raw Transcript") { Clipboard.copyPlain(item.dictation.raw) } }
        Divider()
        Button("Delete", role: .destructive) { delete(item.id) }
    }

    private func delete(_ id: UUID) {
        if selection == id { selection = nil }
        model.deleteHistoryItem(id)
    }

    /// The list's foot, as Finder's status bar: Keep history, how many, Clear All.
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Toggle("Keep history", isOn: $settings.historyEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 12))
                    .fixedSize()
                    .help("When off, nothing is written to disk. Tools using the API can still read the latest dictation.")
                Spacer()
                Text(countLine).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Clear All…") { confirmClear = true }
                    .controlSize(.small)
                    .disabled(model.history.isEmpty)
                    .help("Delete every dictation kept on this Mac")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .background(.bar)
    }

    private var countLine: String {
        let n = items.count
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { return n == 1 ? "1 match" : "\(n) matches" }
        if n == 0 { return "Kept on this Mac" }
        return n == 1 ? "1 dictation · kept on this Mac" : "\(n) dictations · kept on this Mac"
    }

    @ViewBuilder private var empty: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            ContentUnavailableView.search(text: q)
        } else if !settings.historyEnabled {
            ContentUnavailableView {
                Label("History is off", systemImage: "clock.badge.xmark")
            } description: {
                Text("Turn it on and your next dictation shows up here.")
            } actions: {
                Button("Turn On History") { settings.historyEnabled = true }
            }
        } else {
            ContentUnavailableView {
                Label("No dictations yet", systemImage: "waveform")
            } description: {
                Text(settings.deskDictation && settings.deskKey != .off
                     ? "Dictate on your iPhone, or hold \(settings.deskKey.short) on this Mac — your last 50 show up here, newest first."
                     : "Dictate on your iPhone — your last 50 show up here, newest first.")
            }
        }
    }
}

/// ⌘F lands in the toolbar's search, as everywhere on the Mac (macOS 15 and later).
private struct FindFocusesSearch: ViewModifier {
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .searchFocused($focused)
                .background(Button("") { focused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true))
        } else {
            content
        }
    }
}

/// Where a dictation went, as History shows it: the app's own icon when it can be found, else a
/// symbol for the place ("Clipboard", "Where I'm typing").
@MainActor
enum HistoryPlace {
    private static var icons: [String: NSImage?] = [:]

    static func app(_ profile: String) -> String { Paster.appName(fromTitle: profile) }

    /// "Terminal — claude ~/app" → "claude ~/app".
    static func title(_ profile: String) -> String? {
        guard let r = profile.range(of: " — ") else { return nil }
        let t = String(profile[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    static func symbol(_ profile: String) -> String {
        switch profile {
        case TargetRef.clipboard.displayName, "Clipboard": return "doc.on.clipboard"
        case TargetRef.frontApp.displayName, "Where I'm typing": return "text.cursor"
        default: return "app"
        }
    }

    static func icon(_ profile: String, model: AppModel) -> NSImage? {
        let name = app(profile)
        if let hit = icons[name] { return hit }
        var found: NSImage?
        if let t = model.targets.first(where: { Paster.appName(fromTitle: $0.title) == name || $0.title == name }),
           let i = TargetIcons.image(bundleID: t.bundleID, size: 32) {
            found = i
        } else if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }), let i = app.icon {
            found = i
        } else {
            for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities"] {
                let path = "\(dir)/\(name).app"
                if FileManager.default.fileExists(atPath: path) { found = NSWorkspace.shared.icon(forFile: path); break }
            }
        }
        icons[name] = found
        return found
    }
}

struct HistoryRow: View {
    let item: HistoryItem
    let model: AppModel
    /// Selected: every word, Cleaned | Raw, Copy.
    var open: Bool
    var device: String?
    @State private var showRaw = false
    @State private var copied = false

    private var shown: String { showRaw ? item.dictation.raw : item.dictation.text }
    private var rtl: Bool { TextDirection.isRTL(shown) }
    private var appName: String { HistoryPlace.app(item.profileName) }
    private var windowTitle: String? { HistoryPlace.title(item.profileName) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            placeIcon
                .frame(width: 28, height: 28)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(appName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if item.delayed { Chip(text: "Delayed", color: Light.ochre, icon: "clock") }
                    if item.dictation.stoppedEarly { Chip(text: "Stopped early", color: Light.ochre) }
                    Spacer(minLength: 8)
                    mark
                    Text(item.receivedAt.clockTime).font(Typeface.digits(11)).foregroundStyle(.secondary)
                        .fixedSize()
                }
                if let windowTitle {
                    Text(windowTitle).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                }
                Text(shown)
                    .font(.system(size: 12))
                    .foregroundStyle(open ? Color.primary : Color.secondary)
                    .lineLimit(open ? nil : 2)
                    .multilineTextAlignment(.leading) // leading is the right edge under .rightToLeft
                    .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                    .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    // Not .textSelection: a selectable Text is backed by an AppKit text view whose
                    // layer can draw upside down when the row arrives mid-animation (seen live,
                    // Oct 13 2026). Copy and Copy Raw are in the row's menu.
                if item.outcome == .failed, !detailLine.isEmpty {
                    Text(detailLine).font(.system(size: 11)).foregroundStyle(Light.rose)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if open { openBar.padding(.top, 6) }
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(appName), \(item.receivedAt.clockTime). \(item.dictation.text)")
    }

    @ViewBuilder private var placeIcon: some View {
        if let i = HistoryPlace.icon(item.profileName, model: model) {
            Image(nsImage: i).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .accessibilityHidden(true)
        } else {
            SettingsIcon(HistoryPlace.symbol(item.profileName), color: MacTint.gray, size: 24)
                .frame(width: 28, height: 28)
        }
    }

    /// Sent (a paper plane), failed, cancelled — Mail's status column.
    @ViewBuilder private var mark: some View {
        switch item.outcome {
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Light.rose).font(.system(size: 11))
                .help(item.detail).accessibilityLabel("Failed")
        case .cancelled:
            Image(systemName: "xmark.circle").foregroundStyle(.secondary).font(.system(size: 11))
                .help(item.detail).accessibilityLabel("Cancelled")
        default:
            if item.detail.hasPrefix("Sent") {
                Image(systemName: "paperplane.fill").foregroundStyle(.secondary).font(.system(size: 10))
                    .help(item.detail).accessibilityLabel("Sent")
            }
        }
    }

    /// The open row's foot: where and how it went, Cleaned | Raw, Copy.
    private var openBar: some View {
        HStack(spacing: 10) {
            Text(detailLine.isEmpty ? cleanupLabel : "\(detailLine) · \(cleanupLabel)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if item.hasCleanedVersion {
                Picker("Version", selection: $showRaw) {
                    Text("Cleaned").tag(false)
                    Text("Raw").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("Raw is exactly what was heard; Cleaned is what was delivered.")
            }
            Button {
                Clipboard.copyPlain(shown)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .controlSize(.small)
            .help(showRaw ? "Copy the raw transcript" : "Copy")
        }
    }

    private var cleanupLabel: String {
        item.dictation.cleanupLevel == .off ? "No cleanup" : "Cleanup: \(item.dictation.cleanupLevel.title)"
    }

    private var detailLine: String {
        guard let device, !device.isEmpty else { return item.detail }
        return item.detail.isEmpty ? "From \(device)" : "\(item.detail) · from \(device)"
    }
}
