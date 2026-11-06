import MacrophoneKit
import SwiftUI

/// The Custom cleanup level's instructions, in full and editable. Prefilled with the default —
/// exactly Medium's — saved as he types and applied to the next dictation at once. Emptied, Custom
/// goes back to the default. Reached from Settings › Cleanup, and from the Custom step by the mic
/// (tap it again once it's picked, or long-press it). A native grouped page since Nov 1 2026, the
/// editor a cell as Mail's signature is.
struct CustomCleanupView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: Settings
    @State private var text = ""
    @State private var confirmReset = false
    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDefault: Bool { trimmed.isEmpty || trimmed == CleanupPrompts.defaultCustomInstructions }

    var body: some View {
        Form {
            if settings.cleanupLevel != .custom { useCustom }
            Section {
                editor
            } header: {
                Text("Instructions")
            } footer: {
                footer
            }
            Section {
                Button("Reset to Default", role: .destructive) { confirmReset = true }
                    .disabled(isDefault)
                    .accessibilityIdentifier("custom-reset")
            }
        }
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
        Section {
            let words = Text("Cleanup is set to \(settings.cleanupLevel.title). These apply when it's set to Custom.")
                .font(.subheadline)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Stacked at the accessibility sizes: side by side the button broke "Cus-tom" in two.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) { words; useCustomButton }
                    .padding(.vertical, 4)
            } else {
                HStack(spacing: 12) { words; Spacer(minLength: 4); useCustomButton }
            }
        }
    }

    private var useCustomButton: some View {
        Button("Use Custom") {
            Haptics.pick()
            model.setCleanupLevel(.custom)
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(Light.cyan)
        .fixedSize()
        .accessibilityIdentifier("use-custom")
    }

    /// As tall as the words (Nov 4 2026): a fixed-height editor inside the scrolling page was a
    /// scroll inside a scroll, its last line cut mid-word at the cell's foot. Now the page scrolls
    /// and the cell grows, as a note does; Return starts a new line.
    private var editor: some View {
        TextField("Empty — Custom follows the default instructions, the same as Medium.", text: $text, axis: .vertical)
            .font(.callout)
            .foregroundStyle(Ink.ink)
            .lineSpacing(2)
            .lineLimit(8...)
            .focused($focused)
            .autocorrectionDisabled()
            .accessibilityLabel("Custom cleanup instructions")
            .accessibilityIdentifier("custom-instructions")
            .padding(.vertical, 6)
    }

    /// Whose instructions these are, beside the count; then what the model does with them.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Side by side while they fit; stacked at large text sizes, never clipped.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) { status; Spacer(minLength: 8); count }
                VStack(alignment: .leading, spacing: 4) { status; count }
            }
            Text("These are the instructions Apple's on-device model follows to clean up your words. It always keeps your words as text — it never answers them. Your dictionary words are added automatically.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var status: some View {
        Label(isDefault ? "Default · same as Medium" : "Your own · saved as you type",
              systemImage: isDefault ? "doc.text" : "checkmark.circle.fill")
            .foregroundStyle(isDefault ? Ink.secondary : Light.mint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var count: some View {
        Text("\(text.count.formatted()) characters")
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("custom-count")
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
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.doneButtonStyle() }
                }
        }
        .tint(Light.cyan)
    }
}
