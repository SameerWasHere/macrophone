import AppKit
import Carbon.HIToolbox
import Foundation
import MacrophoneKit

/// An answer from a notification's button (Nov 9 2026, Core/AlertAnswer.swift): the phone isn't
/// watching the window, so this finds it, reads what it asks now, and only if that is still the
/// question the notification showed brings it forward and gives the answer — the same keys (or
/// the card's own controls) a tap in the window view gives. Anything else answers nothing and
/// says why: an answer must never land on a different question.
@MainActor
enum AlertAnswerer {
    static func answer(_ a: AlertAnswer, app: AppModel) async -> AlertAnswerResult {
        guard Paster.isTrusted else { return AlertAnswerResult(ok: false, detail: "Your Mac needs to allow Accessibility first") }
        guard !StayAwake.isLocked else { return AlertAnswerResult(ok: false, detail: "Your Mac is locked") }
        guard case let .app(bundleID, windowKey, name) = AppModel.named(a.ref),
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first, !running.isTerminated else {
            return AlertAnswerResult(ok: false, detail: "That app isn't open any more")
        }
        let pid = running.processIdentifier
        let wid = windowKey.flatMap { CGWindowID($0) } ?? WindowServer.appWindows().filter { $0.pid == pid }.min(by: { $0.z < $1.z })?.id
        guard let wid else { return AlertAnswerResult(ok: false, detail: "That window isn't open any more") }

        let (ax, prompt) = await read(pid: pid, windowID: wid)
        guard let prompt, prompt.id == a.promptID else {
            app.log.add("alert answer: skipped — the window moved on")
            return AlertAnswerResult(ok: false, detail: "\(name) isn't asking that any more — nothing was answered")
        }
        guard a.index >= 0, a.index < prompt.choices.count else { return AlertAnswerResult(ok: false, detail: "That answer isn't there any more") }
        let words = prompt.choices[a.index].label

        if prompt.style == .pressed, let ax {
            guard let pt = ax.point(for: a.index) else { return AlertAnswerResult(ok: false, detail: "The question's buttons are gone") }
            _ = try? await Paster.bringToFront(running, windowID: wid, required: false, name: name)
            await click(at: pt)
            try? await Task.sleep(nanoseconds: 150_000_000)
            _ = ax.pressSubmit()
        } else {
            guard let keys = prompt.keys(for: a.index) else { return AlertAnswerResult(ok: false, detail: "That answer can't be given from here") }
            do { _ = try await Paster.bringToFront(running, windowID: wid, required: true, name: name) }
            catch { return AlertAnswerResult(ok: false, detail: "Couldn't bring \(name) forward") }
            try? await Task.sleep(nanoseconds: 120_000_000)
            for k in keys {
                switch k {
                case .up: Keys.press(CGKeyCode(kVK_UpArrow), flags: [.maskNumericPad, .maskSecondaryFn])
                case .down: Keys.press(CGKeyCode(kVK_DownArrow), flags: [.maskNumericPad, .maskSecondaryFn])
                case .returnKey: Keys.press(CGKeyCode(kVK_Return), flags: [])
                case let .character(c):
                    let fallback = c == "y" ? kVK_ANSI_Y : c == "n" ? kVK_ANSI_N : nil
                    guard let code = Keys.code(for: c) ?? fallback.map({ CGKeyCode($0) }) else { continue }
                    Keys.press(code, flags: [])
                }
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
        }
        // Answered from the phone: a chat now, its reply worth telling.
        app.replies.engaged(windowID: wid, bundleID: bundleID)
        app.log.add("alert answer: answer \(a.index + 1) of \(prompt.choices.count) given")
        return AlertAnswerResult(ok: true, detail: "Answered \(name): \(words)")
    }

    /// What a window asks now: its controls first (exact), else the picture.
    static func read(pid: pid_t, windowID wid: CGWindowID) async -> (AXPrompt?, WatchPrompt?) {
        if let read = await Task.detached(priority: .userInitiated, operation: { AXPrompt.read(pid: pid, windowID: wid) }).value {
            return (read, read.prompt)
        }
        if CGPreflightScreenCaptureAccess(),
           let c = try? await SCShareableContentBox.current(),
           let scw = c.windows.first(where: { $0.windowID == wid }),
           let image = await AttentionWatcher.capture(scw) {
            return (nil, await PromptVision.read(image))
        }
        return (nil, nil)
    }

    private static func click(at pt: CGPoint) async {
        let src = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

import ScreenCaptureKit

/// The shareable content, asked once here.
enum SCShareableContentBox {
    static func current() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    }
}
