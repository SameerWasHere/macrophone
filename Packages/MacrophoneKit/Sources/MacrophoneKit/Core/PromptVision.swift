#if canImport(Vision)
import CoreGraphics
import Dispatch
import Vision

/// Reads the question a window is asking off its picture (Oct 16 2026), with Apple's on-device
/// text recognition — only the bottom half, where a prompt sits, and nothing leaves the Mac but the
/// question and its answers, to the phone that's watching.
public enum PromptVision {
    /// The share of the window, from the bottom, that's read.
    public static let band: CGFloat = 0.5

    private static let queue = DispatchQueue(label: "macrophone.prompt-reader", qos: .utility)

    /// Reads on its own queue: text recognition blocks its thread while it waits on work of its
    /// own, and on a Swift concurrency thread that wait never ends.
    public static func read(_ image: CGImage) async -> WatchPrompt? {
        await withCheckedContinuation { c in queue.async { c.resume(returning: readNow(image)) } }
    }

    public static func readNow(_ image: CGImage) -> WatchPrompt? {
        let request = VNRecognizeTextRequest()
        // Fast: a few hundredths of a second for the band, and the reader forgives its usual
        // slips ("1" read as "l", "?" as "7"). Accurate is ten times the work, and on some Macs
        // its model never answers.
        request.recognitionLevel = .fast
        // Corrections turn "❯" and "(y/N)" into words; the reader wants what's there.
        request.usesLanguageCorrection = false
        // Vision's origin is the bottom-left corner.
        request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: band)
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { return nil }
        let lines: [ReadLine] = (request.results ?? []).compactMap { o in
            guard let text = o.topCandidates(1).first?.string else { return nil }
            // Boxes are relative to the region read: back to the whole window, top-left origin.
            let b = o.boundingBox
            return ReadLine(text: text, minX: Double(b.minX), midY: Double(1 - b.midY * band))
        }
        return PromptReader.read(lines)
    }
}
#endif
