import MacrophoneKit
import SwiftUI

/// The last 50 dictations, on this iPhone only. Independent of the Mac's history.
/// Read as Notes and Mail read since Nov 1 2026: a search field, the days as sections (Today,
/// Yesterday, then dates), a row per dictation — where it went, when, its first two lines, how it
/// landed — swipes for Send Again, Copy and Delete, and a tap opens it as a page.
struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false
    @State private var query = ""

    var body: some View {
        NavigationStack {
            Group {
                if !model.settings.historyEnabled {
                    ContentUnavailableView {
                        Label("History is off", systemImage: "clock.badge.xmark")
                    } description: {
                        Text("Dictations aren't kept on this iPhone. Turn history on in Settings to keep the last 50.")
                    }
                } else if model.historyItems.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing yet", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("Your last 50 dictations will be here, on this iPhone only. Clearing them doesn't touch your Mac's history.")
                    }
                } else {
                    list
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: UUID.self) { id in HistoryPage(id: id) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !model.historyItems.isEmpty {
                        Button("Clear All", role: .destructive) { confirmClear = true }
                            .tint(Light.rose)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.doneButtonStyle()
                }
            }
            .confirmationDialog("Clear all history on this iPhone?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear All", role: .destructive) { model.clearHistory() }
            } message: {
                Text("Your Mac keeps its own history; this doesn't change it.")
            }
        }
        .tint(Light.cyan)
    }

    // MARK: The list

    private var shown: [HistoryItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return model.historyItems }
        return model.historyItems.filter {
            $0.text(cleaned: true).localizedCaseInsensitiveContains(q)
                || $0.dictation.raw.localizedCaseInsensitiveContains(q)
                || ($0.targetName ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    /// The items by the day they were spoken, newest day first, in the order they're kept.
    private var days: [(day: Date, items: [HistoryItem])] {
        let cal = Calendar.current
        var out: [(day: Date, items: [HistoryItem])] = []
        for item in shown.sorted(by: { $0.dictation.createdAt > $1.dictation.createdAt }) {
            let day = cal.startOfDay(for: item.dictation.createdAt)
            if let i = out.firstIndex(where: { $0.day == day }) { out[i].items.append(item) } else { out.append((day, [item])) }
        }
        return out
    }

    @ViewBuilder private var list: some View {
        let groups = days
        List {
            if groups.isEmpty {
                ContentUnavailableView.search(text: query)
                    .listRowBackground(Color.clear)
            }
            ForEach(groups, id: \.day) { group in
                Section {
                    ForEach(group.items) { item in
                        NavigationLink(value: item.id) {
                            HistoryRow(item: item)
                        }
                        .swipeActions(edge: .leading) {
                            Button { model.resend(item); Haptics.tick() } label: { Label("Send Again", systemImage: "arrow.uturn.right") }
                                .tint(Light.cyan)
                        }
                        .swipeActions(edge: .trailing) {
                            // Red by name: the stack's blue accent would otherwise win over the role.
                            Button(role: .destructive) { model.deleteHistoryItem(item.id) } label: { Label("Delete", systemImage: "trash") }
                                .tint(Light.rose)
                            Button { model.copy(item, cleaned: true); Haptics.tick() } label: { Label("Copy", systemImage: "doc.on.doc") }
                                .tint(Color(uiColor: .systemGray))
                        }
                        .contextMenu {
                            Button { model.copy(item, cleaned: true) } label: { Label("Copy", systemImage: "doc.on.doc") }
                            if item.hasCleaned {
                                Button { model.copy(item, cleaned: false) } label: { Label("Copy Raw", systemImage: "text.quote") }
                            }
                            Button { model.resend(item) } label: { Label("Send Again", systemImage: "arrow.uturn.right") }
                            Divider()
                            Button(role: .destructive) { model.deleteHistoryItem(item.id) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                } header: {
                    Text(Self.dayTitle(group.day))
                } footer: {
                    if group.day == groups.last?.day {
                        Text("Kept on this iPhone only — the last 50. Your Mac has its own history.")
                    }
                }
                .headerProminence(.increased)
            }
        }
        .searchable(text: $query, prompt: "Search")
    }

    /// "Today", "Yesterday", the weekday within the week, then the date (with the year when it's
    /// another year's).
    static func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let ago = cal.dateComponents([.day], from: day, to: cal.startOfDay(for: .now)).day ?? 99
        if ago < 7 { return day.formatted(.dateTime.weekday(.wide)) }
        if cal.isDate(day, equalTo: .now, toGranularity: .year) { return day.formatted(.dateTime.weekday(.wide).month(.wide).day()) }
        return day.formatted(.dateTime.month(.wide).day().year())
    }
}

/// How a dictation landed, as a glyph and its colour (the desktop widget's set).
enum HistoryMark {
    static func of(_ item: HistoryItem) -> (symbol: String, color: Color) {
        switch item.delivery {
        case .delivered:
            if let l = item.landed, !l.isSuccess {
                return l.copiedInstead ? ("doc.on.clipboard.fill", Light.ochre) : ("exclamationmark.circle.fill", Light.rose)
            }
            return item.landingUnconfirmed == true ? ("checkmark.circle", Light.ochre) : ("checkmark.circle.fill", Light.mint)
        case .duplicate: return ("checkmark.circle.fill", Light.mint)
        case .queued: return ("clock.fill", Light.ochre)
        case .failed: return ("exclamationmark.circle.fill", Light.rose)
        case .cleaning, .sending: return ("arrow.up.circle.fill", Light.cyan)
        case .copiedOnPhone: return ("doc.on.clipboard.fill", Ink.secondary)
        }
    }
}

/// One dictation in the list, as a message in Mail: where it went and its icon, the time and how it
/// landed, then its first two lines. At the accessibility text sizes the three stack, as Mail's do.
struct HistoryRow: View {
    @EnvironmentObject var model: AppModel
    var item: HistoryItem
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        HistoryIcon(item: item, size: 36)
                        name
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) { glyphs; time }
                    PreviewLines(text: item.text(cleaned: true), lines: 3)
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    HistoryIcon(item: item, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            name.layoutPriority(1)
                            Spacer(minLength: 6)
                            glyphs
                            time
                        }
                        PreviewLines(text: item.text(cleaned: true))
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.targetName.map { "To \($0)" } ?? "On this iPhone"), \(item.dictation.createdAt.formatted(date: .omitted, time: .shortened)), \(item.labels.joined(separator: ", "))")
        .accessibilityValue(item.text(cleaned: true))
    }

    /// Wraps rather than "…" (the app never cuts words with an ellipsis).
    private var name: some View {
        Text(item.targetName ?? "This iPhone")
            .font(.headline)
            .foregroundStyle(Ink.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The paper plane when it was sent, then how it landed.
    @ViewBuilder private var glyphs: some View {
        let mark = HistoryMark.of(item)
        if item.dictation.send == true {
            Image(systemName: "paperplane.fill")
                .font(.caption)
                .foregroundStyle(Ink.secondary)
                .accessibilityHidden(true)
        }
        Image(systemName: mark.symbol)
            .font(.footnote)
            .foregroundStyle(mark.color)
            .accessibilityHidden(true)
    }

    private var time: some View {
        Text(item.dictation.createdAt, format: .dateTime.hour().minute())
            .font(.subheadline)
            .foregroundStyle(Ink.secondary)
            .monospacedDigit()
            .fixedSize()
    }
}

/// A dictation's first lines, as Mail previews a message — but never cut with "…" (the app's
/// rule, as `FittedText`): past `lines` the words are clipped at a line's foot and the last line
/// fades out at its end.
struct PreviewLines: View {
    var text: String
    var lines = 2
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var natural: CGFloat = 0

    /// One subheadline line at this text size.
    private var line: CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
        return ceil(UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).lineHeight)
    }

    var body: some View {
        let cap = line * CGFloat(lines)
        let cut = natural > cap + 1
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Ink.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { natural = $0 }
            .frame(height: cut ? cap : nil, alignment: .top)
            .clipped()
            .mask {
                if cut {
                    VStack(spacing: 0) {
                        Rectangle().frame(height: cap - line)
                        LinearGradient(stops: [.init(color: .black, location: 0.72), .init(color: .clear, location: 1)],
                                       startPoint: .leading, endPoint: .trailing)
                    }
                } else {
                    Rectangle()
                }
            }
    }
}

/// The place's icon for a dictation: the app's own when the Mac sent it, its glyph on a tile, or
/// the iPhone for one that never left it.
struct HistoryIcon: View {
    @EnvironmentObject var model: AppModel
    var item: HistoryItem
    var size: CGFloat = 36

    var body: some View {
        if item.delivery != .copiedOnPhone, let t = item.dictation.target {
            PlaceIcon(target: t, icon: model.liveTarget(for: t)?.icon, size: size)
        } else {
            SettingsIcon(symbol: "iphone", color: Color(uiColor: .systemGray), size: size)
        }
    }
}

/// One dictation as a page, the way Notes opens a note: when it was said at the top, where it went,
/// the words in full and selectable, what happened on the way in small type under them; Cleaned |
/// Raw, Copy, Send Again and Delete in the bar at the foot.
struct HistoryPage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var id: UUID
    @State private var cleaned = true
    @State private var copied = false

    private var item: HistoryItem? { model.historyItems.first { $0.id == id } }

    var body: some View {
        Group {
            if let item { page(item) } else { Color.clear }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func page(_ item: HistoryItem) -> some View {
        let mark = HistoryMark.of(item)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(item.dictation.createdAt.formatted(.dateTime.weekday(.wide).month(.wide).day().year().hour().minute()))
                    .font(.footnote)
                    .foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 12) {
                    HistoryIcon(item: item, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.targetName ?? "This iPhone").font(.headline).foregroundStyle(Ink.ink)
                        Label(item.labels.first ?? "", systemImage: mark.symbol)
                            .font(.subheadline)
                            .foregroundStyle(mark.color)
                    }
                }
                .accessibilityElement(children: .combine)
                Text(item.text(cleaned: cleaned))
                    .font(.body)
                    .foregroundStyle(Ink.ink)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .id(cleaned)
                if !details(item).isEmpty {
                    Text(details(item).joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .navigationTitle(item.targetName ?? "This iPhone")
        .toolbar {
            if item.showsVersionToggle {
                ToolbarItem(placement: .principal) {
                    Picker("Version", selection: $cleaned) {
                        Text("Cleaned").tag(true)
                        Text("Raw").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityIdentifier("history-version")
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button(role: .destructive) {
                    model.deleteHistoryItem(item.id)
                    dismiss()
                } label: { Label("Delete", systemImage: "trash") }
                Spacer()
                Button {
                    model.copy(item, cleaned: cleaned)
                    Haptics.tick()
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                Button { model.resend(item); Haptics.tick() } label: { Label("Send Again", systemImage: "arrow.uturn.right") }
                    .accessibilityHint("Sends it to your Mac again. Your Mac ignores it if it already has it.")
            }
        }
    }

    /// What happened on the way: the spoken name, the cleanup, a delay, an early stop.
    private func details(_ item: HistoryItem) -> [String] {
        var out: [String] = []
        if let spoken = item.spokenPrefix { out.append("You said “\(spoken)” first") }
        if item.partialCleanup == true {
            out.append("Partly cleaned — the rest as spoken")
        } else if item.hasCleaned, item.dictation.cleanupLevel != .off {
            out.append("\(item.dictation.cleanupLevel.title) cleanup")
        }
        out.append(contentsOf: item.labels.dropFirst())
        if let mac = item.macName, item.delivery != .copiedOnPhone { out.append("On \(mac)") }
        return out
    }
}
