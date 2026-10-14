import MacrophoneKit
import SwiftUI

/// The Custom cleanup level's instructions, in full and editable. Prefilled with the default —
/// exactly Medium's — saved as he types and applied to the next dictation at once. Emptied, Custom
/// goes back to the default. Reached from Settings › Cleanup, and from the Custom step by the mic
/// (tap it again once it's picked, or long-press it).
struct CustomCleanupView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: Settings
    @State private var text = ""
    @State private var confirmReset = false
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDefault: Bool { trimmed.isEmpty || trimmed == CleanupPrompts.defaultCustomInstructions }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("These are the instructions Apple's on-device model follows to clean up your words. It always keeps your words as text — it never answers them.")
                .font(.footnote)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if settings.cleanupLevel != .custom { useCustom }
            editor
            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Ink.ground.ignoresSafeArea())
        .navigationTitle("Custom Cleanup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = false }.fontWeight(.semibold)
            }
        }
        .onAppear {
            text = settings.customInstructions.isEmpty ? CleanupPrompts.defaultCustomInstructions : settings.customInstructions
        }
        // Saved as he types; the next dictation at Custom follows it.
        .onChange(of: text) { _, t in model.setCustomInstructions(t) }
        .confirmationDialog("Reset to the default instructions?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset to Default", role: .destructive) { text = CleanupPrompts.defaultCustomInstructions }
        } message: {
            Text("Your edits are replaced with the default, the same as Medium.")
        }
    }

    /// Cleanup is on another level: the instructions only apply at Custom.
    private var useCustom: some View {
        HStack(spacing: 10) {
            Text("Cleanup is set to \(settings.cleanupLevel.title). These apply when it's set to Custom.")
                .font(.footnote)
                .foregroundStyle(Light.ochre)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Use Custom") {
                Haptics.tick()
                model.setCleanupLevel(.custom)
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.bordered)
            .tint(Light.cyan)
            .accessibilityIdentifier("use-custom")
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.callout)
                .foregroundStyle(Ink.ink)
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .autocorrectionDisabled()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .accessibilityLabel("Custom cleanup instructions")
                .accessibilityIdentifier("custom-instructions")
            if trimmed.isEmpty {
                Text("Empty — Custom follows the default instructions, the same as Medium.")
                    .font(.callout)
                    .foregroundStyle(Ink.tertiary)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Ink.sunk))
        .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
            .strokeBorder(focused ? Light.cyan.opacity(0.5) : Ink.line, lineWidth: 1))
        .animation(.easeInOut(duration: 0.2), value: focused)
    }

    private var status: some View {
        Text(isDefault ? "Default · same as Medium" : "Your own · saved as you type")
            .font(.footnote.weight(.medium))
            .foregroundStyle(isDefault ? Ink.tertiary : Light.mint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var count: some View {
        Text("\(text.count.formatted()) characters")
            .font(.mono(.caption, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Ink.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("custom-count")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Side by side while they fit; stacked at large text sizes, never clipped.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) { status; Spacer(minLength: 8); count }
                VStack(alignment: .leading, spacing: 4) { status; count }
            }
            Text("Your dictionary words are added automatically.")
                .font(.footnote)
                .foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Reset to Default") { confirmReset = true }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isDefault ? Ink.tertiary : Light.cyan)
                .disabled(isDefault)
                .frame(minHeight: 44)
                .accessibilityIdentifier("custom-reset")
        }
    }
}

/// The editor as a sheet from the Custom step by the mic.
struct CustomCleanupSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CustomCleanupView(settings: model.settings)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.fontWeight(.semibold) }
                }
        }
        .tint(Light.cyan)
    }
}
