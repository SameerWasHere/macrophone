import MacrophoneKit
import SwiftUI

// The desktop's widget (Nov 1 2026): the room between the menu bar and the Dock holds a widget,
// as a Mac's desktop holds them since Sonoma — the last dictation: where it went, when, its first
// lines, Copy and Resend. Before the first one it says what the mic does. It never takes a
// touch the mic or the Dock wants; it's glass over the wallpaper, like its Mac cousins.

struct LastDictationWidget: View {
    @EnvironmentObject var model: AppModel
    /// How many lines of the words fit in the room it's given.
    var lines = 4
    /// A body line's height, at the reader's text size.
    @ScaledMetric(relativeTo: .body) private var lineHeight: CGFloat = 22

    var body: some View {
        Group {
            if let item = model.latest {
                filled(item)
            } else {
                empty
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(WidgetGlass())
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private func filled(_ item: HistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let t = item.dictation.target {
                    DockTile(target: t, icon: model.liveTarget(for: t)?.icon, size: 20)
                } else {
                    Image(systemName: "iphone").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.secondary)
                }
                Text(item.targetName ?? "This iPhone")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Ink.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                status(item)
                Text(item.dictation.createdAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
            // The words whole, shown to the widget's lines and fading out under them (as a widget's
            // long text does) — never cut with "…"; VoiceOver hears all of it with the widget.
            Text(item.text(cleaned: true))
                .font(.body)
                .foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, maxHeight: lineHeight * CGFloat(lines), alignment: .topLeading)
                .clipped()
                .edgeFade(bottom: 14)
                .accessibilityHidden(true)
            HStack(spacing: 8) {
                Button { model.copy(item, cleaned: true); Haptics.tick() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .accessibilityIdentifier("widget-copy")
                if item.delivery != .copiedOnPhone {
                    Button { model.resend(item) } label: { Label("Send Again", systemImage: "arrow.uturn.right") }
                        .accessibilityIdentifier("widget-resend")
                }
                Spacer(minLength: 0)
                Button { model.sheet = .history } label: { Text("History") }
                    .accessibilityIdentifier("widget-history")
            }
            .font(.footnote.weight(.semibold))
            .controlSize(.small)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(Ink.ink)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Last dictation, to \(item.targetName ?? "this iPhone"): \(item.text(cleaned: true))")
        .accessibilityIdentifier("last-dictation-widget")
    }

    private func status(_ item: HistoryItem) -> some View {
        let (symbol, color): (String, Color) = {
            switch item.delivery {
            case .delivered, .duplicate: return ("checkmark.circle.fill", Light.mint)
            case .queued: return ("clock.fill", Light.ochre)
            case .failed: return ("exclamationmark.circle.fill", Light.rose)
            case .cleaning, .sending: return ("arrow.up.circle.fill", Light.cyan)
            case .copiedOnPhone: return ("doc.on.clipboard.fill", Ink.secondary)
            }
        }()
        return Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .accessibilityLabel(item.labels.first ?? "")
    }

    private var empty: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "mic.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(AppIconShape().fill(Light.cyan.gradient))
            VStack(alignment: .leading, spacing: 4) {
                Text("Talk to your Mac").font(.headline).foregroundStyle(Ink.ink)
                Text("Tap the mic and speak. Your words go to \(Places.appName(model.selection.target, in: model)) on \(model.isPaired ? model.macName : "your Mac").")
                    .font(.subheadline)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A desktop widget's plate: Liquid Glass at a widget's corner (material below iOS 26).
struct WidgetGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: MacOSLook.widget, style: .continuous)
        if #available(iOS 26.0, *), !reduceTransparency {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(shape.fill(reduceTransparency ? AnyShapeStyle(Ink.raised) : AnyShapeStyle(.regularMaterial)))
                .overlay(shape.strokeBorder(Ink.line, lineWidth: 0.5))
        }
    }
}
