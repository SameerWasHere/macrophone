import MacrophoneKit
import SwiftUI

// Your agents, at a glance (Oct 17 2026): every session the Mac knows of — Claude Code and Codex
// by what they say themselves, other windows while the Mac reads them asking — with where each
// is: waiting on you, your turn, or working. A tap watches its window (and sends there), where
// its answers wait. Above Send to on the main screen, only while there are any.
//
//   ┌──────────────────────────────────────────────┐
//   │ AGENTS                                       │
//   │ ● Claude Code · Macrophone        Terminal   │  ember: waiting on you
//   │   Run git push origin main?                  │
//   │ ● Codex · api                     Terminal   │  mint: your turn
//   │   Your turn · Tests pass, 3 files changed    │
//   │ ● Claude Code · site              Claude     │
//   │   Working · 4 min                            │  violet: working
//   └──────────────────────────────────────────────┘

struct AgentsPanel: View {
    @EnvironmentObject var model: AppModel
    var compact = false
    @State private var showAll = false
    static let shown = 3

    var body: some View {
        let all = model.agentSessions
        let list = showAll ? all : Array(all.prefix(Self.shown))
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("AGENTS").font(.caption.weight(.semibold)).foregroundStyle(Ink.tertiary)
                Spacer()
                if let w = waitingLine(all) {
                    Text(w).font(.caption.weight(.semibold)).foregroundStyle(Light.ember)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, compact ? 10 : 12)
            .padding(.bottom, 4)
            if all.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No agents running")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Ink.ink)
                    Text("Start Claude Code or Codex on your Mac and they show here, with an alert the moment one needs you. First, on your Mac: Macrophone › Agents › Connect.")
                        .font(.footnote)
                        .foregroundStyle(Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
            }
            ForEach(list) { s in
                AgentRow(session: s) { open(s) }
                if s.id != list.last?.id { PanelDivider() }
            }
            if all.count > Self.shown {
                PanelDivider()
                Button { withAnimation(.snappy) { showAll.toggle() } } label: {
                    Text(showAll ? "Show fewer" : "Show all \(all.count)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Light.cyan)
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 4)
        .controlPanel()
        .padding(.horizontal, 16)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agents")
    }

    private func waitingLine(_ all: [AgentSession]) -> String? {
        let n = all.filter { $0.state == .waiting }.count
        return n == 0 ? nil : n == 1 ? "1 waiting on you" : "\(n) waiting on you"
    }

    private func open(_ s: AgentSession) {
        guard let ref = s.ref else { return }
        Haptics.tick()
        model.openAttention(ref)
    }
}

private struct AgentRow: View {
    var session: AgentSession
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(color).frame(width: 8, height: 8)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(session.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Ink.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        Text(session.appName).font(.caption).foregroundStyle(Ink.tertiary)
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        Text(line(now: ctx.date))
                            .font(.footnote)
                            .foregroundStyle(session.state == .waiting ? Ink.secondary : Ink.tertiary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                if session.ref != nil {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Ink.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.ref == nil)
        .accessibilityElement(children: .combine)
        .accessibilityHint(session.ref == nil ? "" : "Shows its window.")
    }

    private var color: Color {
        switch session.state {
        case .waiting: return Light.ember
        case .yourTurn: return Light.mint
        case .working: return Light.violet
        }
    }

    private func line(now: Date) -> String {
        switch session.state {
        case .waiting:
            return session.detail ?? "Waiting on you"
        case .yourTurn:
            return session.detail.map { "Your turn · \($0)" } ?? "Your turn"
        case .working:
            let m = Int(now.timeIntervalSince(session.since) / 60)
            return m < 1 ? "Working" : "Working · \(m) min"
        }
    }
}
