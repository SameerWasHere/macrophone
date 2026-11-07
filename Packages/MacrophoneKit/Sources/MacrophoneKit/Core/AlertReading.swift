#if canImport(Vision)
import CoreGraphics
import Dispatch
import Foundation
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What a window on watch says (Nov 6 2026): its lines, read with Apple's on-device text
/// recognition, so an alert can say "Build failed: 3 errors" instead of "Terminal changed". The
/// lines are read on the Mac; only the alert's headline and one line go to the phone.
public enum AlertReading {
    private static let queue = DispatchQueue(label: "macrophone.alert-reader", qos: .utility)

    /// The window's lines, top to bottom (fast recognition: a few hundredths of a second).
    public static func lines(_ image: CGImage) async -> [String] {
        await withCheckedContinuation { c in queue.async { c.resume(returning: linesNow(image)) } }
    }

    /// Accurate recognition (it reads "1 error", where fast reads "l error"), given four seconds on
    /// a thread of its own — on some Macs its model never answers — else fast.
    static func linesNow(_ image: CGImage) -> [String] {
        let done = DispatchSemaphore(value: 0)
        let box = LinesBox()
        DispatchQueue.global(qos: .utility).async {
            box.set(read(image, level: .accurate))
            done.signal()
        }
        if done.wait(timeout: .now() + 4) == .success, let lines = box.get() { return lines }
        return read(image, level: .fast)
    }

    private final class LinesBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String]?
        func set(_ l: [String]) { lock.lock(); lines = l; lock.unlock() }
        func get() -> [String]? { lock.lock(); defer { lock.unlock() }; return lines }
    }

    static func read(_ image: CGImage, level: VNRequestTextRecognitionLevel) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = false
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { return [] }
        // Recognition hands back pieces; the pieces on one row are one line, left to right.
        let pieces = (request.results ?? []).compactMap { o -> (String, CGRect)? in
            guard let t = o.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
            return (t, o.boundingBox)
        }.sorted { $0.1.midY > $1.1.midY }
        var rows: [[(String, CGRect)]] = []
        for p in pieces {
            if let last = rows.last?.first, abs(last.1.midY - p.1.midY) < min(last.1.height, p.1.height) * 0.5 {
                rows[rows.count - 1].append(p)
            } else {
                rows.append([p])
            }
        }
        return rows.map { $0.sorted { $0.1.minX < $1.1.minX }.map(\.0).joined(separator: " ") }
    }

    /// The headline and the line under it, written by the on-device model from what's new in the
    /// window — nil when there's no model (the caller falls back to `AlertWords`).
    public static func words(app: String, title: String, kind: MacAlert.Kind, newLines: [String]) async -> (headline: String, detail: String?)? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), case .available = SystemLanguageModel.default.availability, !newLines.isEmpty {
            return await Writer.write(app: app, title: title, kind: kind, newLines: newLines)
        }
        #endif
        return nil
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    enum Writer {
        static let instructions = """
        You write the text of a phone notification about a window on the user's Mac that changed. \
        You get the app's name, the window's title, what happened, and the lines of text at the end of \
        the window. Reply with exactly two lines. Line 1: a headline of 2 to 6 words saying what \
        happened, such as "Build failed", "Export finished", "Tests passed", "Download complete", \
        "New reply from Alex". Line 2: one short sentence with the most useful detail, copied or \
        shortened from the text, or "-" if there is none. Use only facts that are in the text; never \
        make up a number, a name or a result. No quotes, no emoji, no markdown, no full stop.

        """

        static func write(app: String, title: String, kind: MacAlert.Kind, newLines: [String]) async -> (headline: String, detail: String?)? {
            let happened: String
            switch kind {
            case .finished: happened = "a long task in it just ended (it may have succeeded or failed: read the text)"
            case .updated: happened = "something new just appeared in it"
            case .dialog: happened = "a dialog just opened over it"
            case .asking: happened = "it is asking the user a question"
            case .closed, .calmed: return nil
            }
            let text = newLines.suffix(30).joined(separator: "\n")
            let prompt = "App: \(app)\nWindow: \(title)\nWhat happened: \(happened)\nNew text:\n\(String(text.prefix(1800)))"
            let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
            let session = LanguageModelSession(model: model, instructions: instructions)
            let options = GenerationOptions(samplingMode: .greedy, temperature: nil, maximumResponseTokens: 80)
            guard let reply = try? await session.respond(to: prompt, options: options).content else { return nil }
            let parts = reply.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"*"))) }
            guard let first = parts.first, !first.isEmpty, first.count <= 60,
                  !["→", "->", "stopped changing", "busy", "window updated"].contains(where: { first.lowercased().contains($0) }) else { return nil }
            let head = first.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let detail = parts.dropFirst().first.flatMap { $0 == "-" || $0.isEmpty ? nil : String($0.prefix(160)) }
            // A number the window never showed is made up: plain words instead.
            guard grounded(head, in: text + " " + app + " " + title), detail.map({ grounded($0, in: text) }) ?? true else { return nil }
            return (head, detail)
        }

        /// Every number in `line` appears in `text`, and every longer word is the text's or a plain
        /// word for how things went ("finished", "failed", "reply") — so the model can't make up a
        /// "Build" for an upload.
        static func grounded(_ line: String, in text: String) -> Bool {
            let numbers = line.split(whereSeparator: { !$0.isNumber && $0 != "." }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.filter { !$0.isEmpty }
            guard numbers.allSatisfy({ text.contains($0) }) else { return false }
            let known = text.lowercased()
            let words = line.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 4 }
            return words.allSatisfy { w in known.contains(w) || AlertWords.statusWords.contains(w) || AlertWords.statusWords.contains(where: { w.hasPrefix($0) }) }
        }
    }
    #endif
}
#endif
