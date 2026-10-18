import AppKit
import ApplicationServices
import Foundation
import MacrophoneKit
import ScreenCaptureKit
import Vision

/// Reader's words (Oct 18 2026): a terminal's own text through Accessibility (exact, its last
/// stretch), else text recognition over a full-resolution picture of the window, kept to the
/// column you type in so a sidebar's list stays out. Nothing read here is kept or logged.
enum WindowReader {
    private static let queue = DispatchQueue(label: "macrophone.reader", qos: .userInitiated)

    /// A terminal window's text: its text area's last `ReaderPage.maxCharacters`, as lines, the
    /// blank ones at its end dropped. Nil when it can't be read.
    static func terminalLines(pid: pid_t, windowID: CGWindowID) -> [String]? {
        guard let win = AX.window(in: AX.app(pid), id: windowID), let area = textArea(in: win, depth: 0) else { return nil }
        guard let text = tail(of: area, characters: ReaderPage.maxCharacters) else { return nil }
        var lines = text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\r", with: "") }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        // A cut at the start of the stretch leaves half a line.
        if text.count >= ReaderPage.maxCharacters, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    private static func textArea(in e: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 12 else { return nil }
        if AX.role(e) == kAXTextAreaRole { return e }
        for k in AX.elements(e, kAXChildrenAttribute) { if let t = textArea(in: k, depth: depth + 1) { return t } }
        return nil
    }

    private static func tail(of e: AXUIElement, characters n: Int) -> String? {
        var count: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
              let total = count as? Int, total > 0 else { return AX.value(e) }
        var range = CFRange(location: max(0, total - n), length: min(n, total))
        guard let r = AXValueCreate(.cfRange, &range) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(e, kAXStringForRangeParameterizedAttribute as CFString, r, &out) == .success
        else { return nil }
        return out as? String
    }

    /// The window at full resolution (up to 2600 pixels across), for reading.
    static func capture(_ w: SCWindow) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let cfg = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let pxW = max(1, w.frame.width * scale), pxH = max(1, w.frame.height * scale)
        let k = min(1, 2600 / pxW)
        cfg.width = Int(pxW * k)
        cfg.height = Int(pxH * k)
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    /// The words on the picture, top to bottom, inside `column` (fractions of its width).
    static func pictureLines(_ image: CGImage, column: ClosedRange<Double>?) async -> [String] {
        await withCheckedContinuation { c in queue.async { c.resume(returning: readNow(image, column: column)) } }
    }

    private static func readNow(_ image: CGImage, column: ClosedRange<Double>?) -> [String] {
        let request = VNRecognizeTextRequest()
        // Fast, as the prompt reader: on some Macs the accurate model never answers. Corrections
        // on: here the words matter more than the symbols.
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = true
        // The whole window is read and a line kept when its middle sits in the column: cropping the
        // picture instead slices the first letter off lines that start at the column's edge.
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { return [] }
        struct Piece { var text: String; var x: Double; var y: Double; var h: Double }
        let pieces: [Piece] = (request.results ?? []).compactMap { o in
            guard let t = o.topCandidates(1).first?.string else { return nil }
            let b = o.boundingBox
            if let column, !column.contains(Double(b.midX)) { return nil }
            return Piece(text: t, x: Double(b.minX), y: Double(1 - b.midY), h: Double(b.height))
        }.sorted { $0.y < $1.y }
        // Pieces on one row (their middles closer than half a line) read left to right as one line.
        var rows: [[Piece]] = []
        for p in pieces {
            if let last = rows.last?.last, abs(last.y - p.y) < max(0.004, min(last.h, p.h) * 0.5) {
                rows[rows.count - 1].append(p)
            } else {
                rows.append([p])
            }
        }
        return rows.map { $0.sorted { $0.x < $1.x }.map(\.text).joined(separator: "  ") }
    }
}
