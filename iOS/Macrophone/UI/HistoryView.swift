import MacrophoneKit
import SwiftUI

/// The last 50 dictations, on this iPhone only. Independent of the Mac's history.
struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Group {
                if !model.settings.historyEnabled {
                    empty(title: "History is off",
                          body: "Dictations aren't kept on this iPhone. Turn history on in Settings to keep the last 50.")
                } else if model.historyItems.isEmpty {
                    empty(title: "Nothing yet",
                          body: "Your last 50 dictations will be here, on this iPhone only. Clearing them doesn't touch your Mac's history.")
                } else {
                    list
                }
            }
            .background(Ink.ground.ignoresSafeArea())
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !model.historyItems.isEmpty {
                        Button("Clear All", role: .destructive) { confirmClear = true }
                            .foregroundStyle(Light.rose)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .confirmationDialog("Clear all history on this iPhone?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear All", role: .destructive) { model.clearHistory() }
            } message: {
                Text("Your Mac keeps its own history; this doesn't change it.")
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(model.historyItems) { item in
                    HistoryRow(item: item,
                               onCopy: { model.copy(item, cleaned: $0) },
                               onResend: { model.resend(item) })
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { model.deleteHistoryItem(item.id) } label: { Label("Delete", systemImage: "trash") }
                        }
                }
            } footer: {
                Text("Kept on this iPhone only — the last 50. Your Mac has its own history.")
                    .font(.footnote)
                    .foregroundStyle(Ink.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func empty(title: String, body: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 34, weight: .light)).foregroundStyle(Ink.tertiary)
            Text(title).font(.serif(.title3)).foregroundStyle(Ink.ink)
            Text(body).font(.subheadline).foregroundStyle(Ink.tertiary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HistoryRow: View {
    var item: HistoryItem
    var onCopy: (Bool) -> Void
    var onResend: () -> Void
    @State private var showCleaned = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    Kicker(item.dictation.createdAt.formatted(.relative(presentation: .named))).fixedSize()
                    Spacer(minLength: 8)
                    if item.hasCleaned { VersionToggle(cleaned: $showCleaned, cleanedTitle: item.cleanedTitle).fixedSize() }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Kicker(item.dictation.createdAt.formatted(.relative(presentation: .named)))
                    if item.hasCleaned { VersionToggle(cleaned: $showCleaned, cleanedTitle: item.cleanedTitle) }
                }
            }
            ExpandableText(text: item.text(cleaned: showCleaned), font: .serif(.body))
                .id(showCleaned)
            labels
                .frame(maxWidth: .infinity, alignment: .leading)
            // Not a FlowRow: inside a List cell the buttons got measured at a sliver of width (iOS 27).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .glass(Radius.medium)
        .contextMenu {
            Button { onCopy(showCleaned) } label: { Label("Copy", systemImage: "doc.on.doc") }
            if item.hasCleaned {
                Button { onCopy(!showCleaned) } label: { Label(showCleaned ? "Copy Raw" : "Copy Cleaned", systemImage: "doc.on.doc") }
            }
            Button(action: onResend) { Label("Resend", systemImage: "arrow.clockwise") }
        }
    }

    @ViewBuilder private var actions: some View {
        CopyButton { onCopy(showCleaned) }.fixedSize()
        Button(action: onResend) { ChipLabel("Resend", systemImage: "arrow.clockwise") }
            .buttonStyle(ChipButtonStyle())
            .fixedSize()
    }

    private var labels: some View {
        FlowRow(spacing: 6) {
            ForEach(chips, id: \.0) { chip in
                Text(chip.0)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(chip.1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(chip.1.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(chip.1.opacity(0.3), lineWidth: 1))
            }
        }
    }

    private var chips: [(String, Color)] {
        var out: [(String, Color)] = []
        if let name = item.targetName {
            out.append((item.spokenPrefix.map { "→ \(name) · you said “\($0), …”" } ?? "→ \(name)", Light.cyan))
        } else if item.dictation.profileSource == .automatic {
            out.append(("Automatic", Light.violet))
        }
        switch item.delivery {
        case .delivered:
            out.append((item.wasDelayed ? "Delivered late" : "Delivered", Light.mint))
        case .duplicate: out.append(("On your Mac", Light.mint))
        case .copiedOnPhone: out.append(("Copied on iPhone", Light.mint))
        case .queued: out.append(("Queued", Light.ochre))
        case .cleaning, .sending: out.append(("Sending", Light.cyan))
        case .failed: out.append(("Not delivered", Light.rose))
        }
        if item.wasDelayed, item.delivery != .delivered, item.delivery != .queued { out.append(("Delayed", Light.ochre)) }
        if item.dictation.stoppedEarly { out.append(("Stopped early", Light.ochre)) }
        if item.partialCleanup == true {
            out.append(("Partly cleaned — the rest as spoken", Light.ochre))
        } else if item.hasCleaned, item.dictation.cleanupLevel != .off {
            out.append(("\(item.dictation.cleanupLevel.title) cleanup", Ink.tertiary))
        }
        return out
    }
}

/// Wraps chips onto as many lines as they need.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing
            rowH = max(rowH, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}
