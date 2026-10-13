import AppKit
import Foundation
import MacrophoneKit

/// Fills template variables ({{clipboard}}, {{selection}}, {{url}}…). Only the variables a
/// automation's template or snippets actually use are gathered: reading the selection needs
/// Accessibility, the browser address needs Automation.
@MainActor
enum ContextGatherer {
    /// What was true when the dictation arrived — taken at once, before anything is pasted or
    /// any app is brought forward.
    struct Arrival {
        var frontBundleID: String?
        var frontName: String?
        var frontPID: pid_t?
        var clipboard: String?
        var selection: String?
        var window: String?
    }

    /// Variables used by the template and by the expansions of snippets that appear in the text.
    static func needed(template: String?, snippets: [Snippet], text: String) -> Set<String> {
        var names = TemplateRenderer.variables(in: template ?? "")
        for s in snippets where SnippetExpander.expand(text, snippets: [s]) != text {
            names.formUnion(TemplateRenderer.variables(in: s.expansion))
        }
        return names
    }

    static func arrival(needed: Set<String>) -> Arrival {
        let front = NSWorkspace.shared.frontmostApplication
        var a = Arrival(frontBundleID: front?.bundleIdentifier, frontName: front?.localizedName, frontPID: front?.processIdentifier)
        if needed.contains("clipboard") { a.clipboard = NSPasteboard.general.string(forType: .string) }
        if let pid = front?.processIdentifier, Paster.isTrusted {
            if needed.contains("selection") { a.selection = AX.selectedText(pid: pid) }
            if needed.contains("window") { a.window = AX.frontWindowTitle(pid: pid) }
        }
        return a
    }

    /// The context for one dictation. `notes` explains any variable that came back empty for a
    /// reason the person can fix.
    static func context(needed: Set<String>, arrival: Arrival, dictation d: Dictation, name: String, tmuxTarget: String?) async -> (values: [String: String], notes: [String]) {
        var c = TemplateRenderer.clockContext()
        var notes: [String] = []
        c["raw"] = d.raw
        c["profile"] = name
        c["device"] = d.sourceDevice
        c["app"] = arrival.frontName ?? ""
        if needed.contains("clipboard") { c["clipboard"] = arrival.clipboard ?? "" }
        if needed.contains("selection") || needed.contains("window") {
            if !Paster.isTrusted { notes.append("{{selection}} and {{window}} need Accessibility (Delivery › Permissions).") }
            c["selection"] = arrival.selection ?? ""
            c["window"] = arrival.window ?? ""
        }
        if needed.contains("url") {
            let r = await Scripting.browserURL(frontmost: arrival.frontBundleID)
            c["url"] = r.url ?? ""
            if let n = r.note { notes.append(n) }
        }
        if needed.contains("tmux_cwd") {
            if let target = tmuxTarget {
                c["tmux_cwd"] = await Task.detached { Tmux.currentPath(target) }.value ?? ""
            } else {
                c["tmux_cwd"] = ""
            }
        }
        return (c, notes)
    }

    /// Sample values for the editors' live previews.
    static let samples: [String: String] = [
        "text": "Refactor the history store so it trims to fifty items",
        "raw": "um refactor the the history store so it trims to fifty items",
        "clipboard": "func trim(_ items: [Item]) -> [Item]",
        "selection": "let capacity = 50",
        "app": "Xcode",
        "window": "HistoryStore.swift — Macrophone",
        "url": "https://github.com/sameer/macrophone/pull/42",
        "tmux_cwd": "~/code/macrophone",
        "profile": "Claude",
        "device": "Sameer's iPhone",
    ].merging(TemplateRenderer.clockContext()) { a, _ in a }
}
