import AVFoundation
import MacrophoneKit
import SwiftUI

/// Dictation at the desk (Nov 7 2026): the switch, the key, this Mac's cleanup level, what macOS
/// needs, and a box to try it in.
struct DictationPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings
    @ObservedObject var desk: DeskDictation
    @ObservedObject var permissions: PermissionsMonitor
    @FocusState private var tryFocused: Bool

    private var key: DeskKey { settings.deskKey }
    private var keyName: String { key == .off ? "the key" : key.short }
    private var cleanupLevels: [CleanupLevel] { [.off, .light, .medium, .heavy] }

    var body: some View {
        PanePage {
            PaneHeader(title: "Dictation",
                       subtitle: "Hold \(key == .off ? "a key" : key.short) on this Mac, talk, and let go — the words are cleaned up and pasted wherever you're typing. No iPhone needed.")

            if !DeskDictation.engineAvailable {
                PlateNote("Dictation on this Mac needs macOS 26 or later.", color: Light.ochre)
            }

            PaneSection(nil, note: howItWorks) {
                Plate {
                    PlateRow(title: "Dictate on this Mac",
                             subtitle: settings.deskDictation ? hintLine : "Off — only your iPhone dictates.",
                             icon: "mic", iconColor: settings.deskDictation ? Light.teal : Ink.tertiary) {
                        Toggle("", isOn: $settings.deskDictation).toggleStyle(.switch).labelsHidden()
                            .accessibilityLabel("Dictate on this Mac")
                    }
                    PlateDivider()
                    PlateRow(title: "Hold to talk", subtitle: "Two quick taps keep it listening until you tap again.", icon: "keyboard") {
                        Picker("", selection: $settings.deskKey) {
                            ForEach(DeskKey.allCases) { k in Text(k.title).tag(k) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        .accessibilityLabel("Key to hold")
                    }
                    PlateDivider()
                    PlateRow(title: "Cleanup", subtitle: cleanupLine, subtitleColor: cleanupAvailable ? Ink.tertiary : Light.ochre,
                             icon: "wand.and.stars") {
                        Picker("", selection: $settings.deskCleanup) {
                            ForEach(cleanupLevels) { l in Text(l.title).tag(l) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .accessibilityLabel("Cleanup level")
                    }
                }
                .disabled(!DeskDictation.engineAvailable)
            }

            if key == .fn, settings.deskDictation, let conflict = desk.fnUsage.conflict {
                HStack(alignment: .center, spacing: Space.gap) {
                    Image(systemName: "globe").foregroundStyle(Light.ochre).accessibilityHidden(true)
                    Text(conflict).font(.system(size: 12)).foregroundStyle(Light.ochre)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Space.gap)
                    Button("Open Keyboard Settings") { NSWorkspace.shared.open(DeskDictation.keyboardSettingsURL) }
                        .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                }
                .padding(.horizontal, 4)
            }

            if settings.deskDictation, key != .off {
                PaneSection("What macOS needs") {
                    PermissionRows(monitor: permissions, desk: true, needsInputMonitoring: desk.tapRefused && permissions.accessibility)
                }
            }

            PaneSection("Try it", note: "Your Mac's language: \(languageName). What you say stays on this Mac.") {
                Plate {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $desk.tryText)
                            .font(.system(size: 13.5))
                            .scrollContentBackground(.hidden)
                            .focused($tryFocused)
                            .frame(minHeight: 96, maxHeight: 180)
                            .accessibilityLabel("Try dictation here")
                        if desk.tryText.isEmpty {
                            Text(settings.deskDictation && key != .off
                                 ? "Click here, then hold \(keyName) and say something."
                                 : "Turn on Dictate on this Mac to try it here.")
                                .font(.system(size: 13.5)).foregroundStyle(Ink.tertiary)
                                .padding(.leading, 5).padding(.top, 1)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(12)
                    .fieldFocusRing(tryFocused, radius: Radius.plate)
                }
                if !desk.tryText.isEmpty {
                    Button("Clear") { desk.tryText = "" }
                        .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                }
            }
        }
        .onChange(of: tryFocused) { _, f in desk.tryBoxFocused = f }
        .onAppear { desk.readFnUsage(); permissions.refresh() }
        .onDisappear { desk.tryBoxFocused = false }
    }

    private var hintLine: String {
        guard key != .off else { return "Pick a key to hold." }
        if permissions.microphone == .denied || permissions.microphone == .restricted {
            return "The microphone is off for Macrophone — allow it below."
        }
        if desk.tapRefused {
            return permissions.accessibility
                ? "macOS needs Input Monitoring before \(keyName) can be heard — below."
                : "Turn on Accessibility below so \(keyName) can be heard."
        }
        return "Hold \(keyName) anywhere to dictate."
    }

    private var howItWorks: String {
        "Hold the key and talk; let go and the words land where your cursor is — never sent. Esc cancels. Speech and cleanup run on this Mac, and every dictation is in History."
    }

    private var cleanupAvailable: Bool { Cleaner.availability(language: DeskDictation.language).isAvailable }

    private var cleanupLine: String {
        switch Cleaner.availability(language: DeskDictation.language) {
        case .available: return settings.deskCleanup.summary
        case .languageNotSupported: return "Cleanup works in English only for now — your words go as heard."
        case .appleIntelligenceOff: return "Turn on Apple Intelligence in System Settings to clean up — your words go as heard until then."
        case .modelDownloading: return "Apple Intelligence is still downloading — your words go as heard until it's ready."
        default: return "Cleanup needs Apple Intelligence on this Mac — your words go as heard."
        }
    }

    private var languageName: String {
        Locale.current.localizedString(forIdentifier: DeskDictation.language) ?? DeskDictation.language
    }
}
