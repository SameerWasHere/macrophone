import Foundation
import MacrophoneKit

/// Runs the messy-dictation test set through the real on-device model and checks each
/// output against the sample's expectations. Exit code 0 = every check passed.
struct CleanupSample: Codable {
    var id: String
    var input: String
    /// Levels to run; default all three.
    var levels: [CleanupLevel]?
    var dictionary: [String]?
    /// Substrings (case-insensitive) that must appear in the output at every level run.
    var mustContain: [String]?
    /// Substrings (case-insensitive) that must NOT appear.
    var mustNotContain: [String]?
    var note: String?

    enum CodingKeys: String, CodingKey {
        case id, input, levels, dictionary, note
        case mustContain = "must_contain"
        case mustNotContain = "must_not_contain"
    }
}

enum CleanupEval {
    static func run(file: String?, level: String?, only: String?) async -> Int32 {
        let path = file ?? "Tests/MacrophoneKitTests/CleanupSamples.json"
        guard let data = FileManager.default.contents(atPath: path),
              let samples = try? JSONDecoder().decode([CleanupSample].self, from: data) else {
            print("Couldn't read samples at \(path)")
            return 2
        }
        let availability = Cleaner.availability(language: "en-US")
        guard availability.isAvailable else { print("Model unavailable: \(availability.explanation)"); return 2 }
        var failures = 0, checks = 0
        let started = Date()
        for s in samples where only == nil || s.id == only {
            let levels = level.flatMap(CleanupLevel.init(rawValue:)).map { [$0] } ?? s.levels ?? [.light, .medium, .heavy]
            for l in levels {
                let t0 = Date()
                let r = await Cleaner.clean(s.input, level: l, dictionary: s.dictionary ?? [], language: "en-US")
                let out = r.cleaned ?? s.input
                var problems: [String] = []
                for m in s.mustContain ?? [] where out.range(of: m, options: .caseInsensitive) == nil { problems.append("missing “\(m)”") }
                for m in s.mustNotContain ?? [] where out.range(of: m, options: .caseInsensitive) != nil { problems.append("contains “\(m)”") }
                checks += 1
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                let mark = problems.isEmpty ? "PASS" : "FAIL"
                if !problems.isEmpty { failures += 1 }
                print("\(mark) [\(s.id) · \(l.rawValue) · \(ms)ms]\(r.cleaned == nil ? " (raw kept)" : "")")
                print("   in:  \(s.input)")
                print("   out: \(out.replacingOccurrences(of: "\n", with: "⏎ "))")
                if !problems.isEmpty { print("   why: \(problems.joined(separator: "; "))") }
            }
        }
        print("\n\(checks - failures)/\(checks) passed in \(Int(Date().timeIntervalSince(started)))s")
        return failures == 0 ? 0 : 1
    }
}
