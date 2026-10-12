import EventKit
import Foundation
import MacrophoneKit

/// Obsidian, Apple Notes and Reminders: where a profile can also save what you said.
enum NoteActions {
    struct Failure: Error { var message: String; var opensSettings: URL? = nil }

    // MARK: Obsidian

    /// Appends a timestamped bullet to a note in the vault (a plain file write — Obsidian
    /// doesn't need to be running). No note path = today's daily note.
    /// Returns the note's path inside the vault, for the popup ("Daily/2026-10-12.md").
    static func appendToObsidian(_ text: String, vaultPath: String, notePath: String?, dailyFolder: String?,
                                 heading: String?, now: Date = Date()) throws -> String {
        let fm = FileManager.default
        let vault = URL(fileURLWithPath: (vaultPath as NSString).expandingTildeInPath, isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: vault.path, isDirectory: &isDir), isDir.boolValue else {
            throw Failure(message: "The Obsidian vault folder isn't there anymore")
        }
        let relative = noteRelativePath(vault: vault, notePath: notePath, dailyFolder: dailyFolder, now: now)
        let file = vault.appendingPathComponent(relative)
        // Never write outside the vault (a note path like "../x").
        guard file.standardizedFileURL.path.hasPrefix(vault.standardizedFileURL.path) else {
            throw Failure(message: "That note path points outside the vault")
        }
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let entry = bullet(text, now: now)
        let updated = insert(entry, into: existing, under: heading)
        do { try updated.write(to: file, atomically: true, encoding: .utf8) } catch {
            throw Failure(message: "Couldn't write to \(relative)")
        }
        return relative
    }

    /// "- 14:05 Buy milk" (continuation lines indented under the bullet).
    static func bullet(_ text: String, now: Date) -> String {
        let time = TemplateRenderer.clockContext(now)["time"] ?? ""
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        var out = "- \(time) \(lines.first ?? "")"
        for l in lines.dropFirst() { out += "\n  " + l }
        return out
    }

    static func noteRelativePath(vault: URL, notePath: String?, dailyFolder: String?, now: Date) -> String {
        if var p = notePath?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            while p.hasPrefix("/") { p.removeFirst() }
            return p.lowercased().hasSuffix(".md") ? p : p + ".md"
        }
        // Today's daily note, in the folder given, else the one Obsidian's Daily notes plugin uses.
        var folder = dailyFolder?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var format = "YYYY-MM-DD"
        let cfg = vault.appendingPathComponent(".obsidian/daily-notes.json")
        if let d = try? Data(contentsOf: cfg), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if folder.isEmpty, let f = obj["folder"] as? String { folder = f }
            if let f = obj["format"] as? String, !f.isEmpty { format = f }
        }
        let name = momentFormat(format, now)
        let clean = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return clean.isEmpty ? "\(name).md" : "\(clean)/\(name).md"
    }

    /// Obsidian's daily-note names use moment.js tokens; the common ones are enough.
    static func momentFormat(_ format: String, _ date: Date) -> String {
        let map: [(String, String)] = [("YYYY", "yyyy"), ("YY", "yy"), ("MMMM", "MMMM"), ("MMM", "MMM"), ("MM", "MM"),
                                       ("DD", "dd"), ("Do", "d"), ("D", "d"), ("dddd", "EEEE"), ("ddd", "EEE")]
        var out = ""
        var i = format.startIndex
        while i < format.endIndex {
            if format[i] == "[", let close = format[i...].firstIndex(of: "]") {
                out += "'" + format[format.index(after: i)..<close] + "'"
                i = format.index(after: close)
                continue
            }
            if let (m, f) = map.first(where: { format[i...].hasPrefix($0.0) }) {
                out += f
                i = format.index(i, offsetBy: m.count)
            } else {
                let c = format[i]
                out += c.isLetter ? "'\(c)'" : String(c)
                i = format.index(after: i)
            }
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = out
        return df.string(from: date)
    }

    /// Adds `entry` at the end of the section under `heading` (any level, created at the end
    /// of the note when missing), or at the end of the note.
    static func insert(_ entry: String, into note: String, under heading: String?) -> String {
        var lines = note.isEmpty ? [] : note.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard let h = heading?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty else {
            return (lines + [entry]).joined(separator: "\n") + "\n"
        }
        let wanted = h.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
        func level(_ line: String) -> Int? {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("#") else { return nil }
            let n = t.prefix { $0 == "#" }.count
            return n <= 6 && t.dropFirst(n).hasPrefix(" ") ? n : nil
        }
        if let start = lines.firstIndex(where: { level($0) != nil && $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased() == wanted }) {
            let lv = level(lines[start])!
            var end = lines.count
            for j in (start + 1)..<lines.count where (level(lines[j]).map { $0 <= lv } ?? false) { end = j; break }
            var insertAt = end
            while insertAt > start + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
            lines.insert(entry, at: insertAt)
            return lines.joined(separator: "\n") + "\n"
        }
        let headingLine = h.hasPrefix("#") ? h : "## \(h)"
        if !lines.isEmpty { lines.append("") }
        lines.append(headingLine)
        lines.append(entry)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Apple Notes

    static let notesBundleID = "com.apple.Notes"

    /// A new note in `folder` (default folder when nil), or appended to the note titled
    /// `appendTo` (created if there's none). Returns where it went, for the popup.
    static func saveToNotes(_ text: String, folder: String?, appendTo: String?) async throws -> String {
        switch await Scripting.permissionAsync(notesBundleID, ask: true) {
        case .denied:
            throw Failure(message: "Macrophone isn't allowed to use Notes", opensSettings: Scripting.automationSettingsURL)
        default: break
        }
        let html = htmlBody(text)
        let folderClause: String
        if let f = folder?.trimmingCharacters(in: .whitespaces), !f.isEmpty {
            folderClause = """
            set targetFolder to missing value
            repeat with fo in folders
                if name of fo is \(Scripting.quote(f)) then set targetFolder to fo
            end repeat
            if targetFolder is missing value then set targetFolder to make new folder with properties {name:\(Scripting.quote(f))}
            """
        } else {
            folderClause = "set targetFolder to default folder of default account"
        }
        let script: String
        if let title = appendTo?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            script = """
            tell application id "com.apple.Notes"
                set hits to (notes whose name is \(Scripting.quote(title)))
                if (count of hits) > 0 then
                    set n to item 1 of hits
                    set body of n to (body of n) & \(Scripting.quote(html))
                    return "appended"
                end if
                \(folderClause)
                make new note at targetFolder with properties {body:\(Scripting.quote("<div><h1>" + escape(title) + "</h1></div>" + html))}
                return "created"
            end tell
            """
        } else {
            script = """
            tell application id "com.apple.Notes"
                \(folderClause)
                make new note at targetFolder with properties {body:\(Scripting.quote(html))}
                return "created"
            end tell
            """
        }
        do {
            let r = try await Scripting.run(script, timeout: 10)
            if let title = appendTo, !title.isEmpty { return r == "appended" ? "Added to “\(title)”" : "New note “\(title)”" }
            return folder.map { $0.isEmpty ? "New note" : "New note in \($0)" } ?? "New note"
        } catch let f as Scripting.Failure {
            if f.number == -1743 { throw Failure(message: "Macrophone isn't allowed to use Notes", opensSettings: Scripting.automationSettingsURL) }
            throw Failure(message: "Notes didn't take it: \(f.message)")
        }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Notes bodies are HTML; one <div> per line keeps line breaks.
    static func htmlBody(_ text: String) -> String {
        text.components(separatedBy: "\n").map { $0.isEmpty ? "<div><br></div>" : "<div>\(escape($0))</div>" }.joined()
    }

    // MARK: Reminders

    static let store = EKEventStore()

    static var remindersStatus: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .reminder) }

    static var remindersAllowed: Bool {
        if #available(macOS 14.0, *) { return remindersStatus == .fullAccess }
        return remindersStatus == .authorized
    }

    /// Asks for Reminders the first time (macOS 14: full access — Macrophone reads your lists
    /// to offer them and adds to the one you pick).
    static func requestReminders() async -> Bool {
        if remindersAllowed { return true }
        if #available(macOS 14.0, *) {
            return (try? await store.requestFullAccessToReminders()) ?? false
        }
        return await withCheckedContinuation { c in store.requestAccess(to: .reminder) { ok, _ in c.resume(returning: ok) } }
    }

    static func reminderLists() -> [String] {
        guard remindersAllowed else { return [] }
        return store.calendars(for: .reminder).map(\.title).sorted()
    }

    static let remindersSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!

    /// Adds a reminder; with `detectDates`, "call the dentist tomorrow at 5pm" becomes
    /// "Call the dentist", due tomorrow 5 PM. Returns the line for the popup.
    static func addReminder(_ text: String, list: String?, detectDates: Bool, now: Date = Date()) async throws -> String {
        guard await requestReminders() else {
            throw Failure(message: "Macrophone isn't allowed to use Reminders", opensSettings: remindersSettingsURL)
        }
        let parsed = detectDates ? ReminderParsing.parse(text, now: now) : (title: text, due: nil)
        let r = EKReminder(eventStore: store)
        r.title = parsed.title
        let calendars = store.calendars(for: .reminder)
        if let list, let cal = calendars.first(where: { $0.title == list }) {
            r.calendar = cal
        } else if let def = store.defaultCalendarForNewReminders() {
            r.calendar = def
        } else {
            throw Failure(message: "There's no Reminders list to add to")
        }
        if let due = parsed.due {
            var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            comps.timeZone = .current
            r.dueDateComponents = comps
            r.addAlarm(EKAlarm(absoluteDate: due))
        }
        do { try store.save(r, commit: true) } catch {
            throw Failure(message: "Reminders didn't save it")
        }
        var line = "In \(r.calendar.title)"
        if let due = parsed.due {
            let f = DateFormatter()
            f.doesRelativeDateFormatting = true
            f.dateStyle = .medium
            f.timeStyle = .short
            line += " · due \(f.string(from: due))"
        }
        return line
    }
}
