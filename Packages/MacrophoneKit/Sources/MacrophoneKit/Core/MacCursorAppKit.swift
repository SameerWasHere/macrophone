#if os(macOS)
import AppKit
import CryptoKit

// Making a `MacCursor` from the Mac's pointer — shared by the Mac app's watch and `mpctl serve`.

/// Reads the Mac's pointer and says when its shape changed. Each read draws the cursor into a
/// small bitmap (a few thousand pixels) and compares it with the last; the PNG is made only when
/// it differs, so reading it fifteen times a second costs next to nothing.
@MainActor
public final class MacCursorReader {
    private var lastKey: Data?

    public init() {}

    /// Forget the last shape: the next read sends whatever shows (the phone's pointer just showed).
    public func reset() { lastKey = nil }

    /// The pointer the Mac shows right now, whatever app set it — nil when it's the same shape as
    /// the last read, or can't be read.
    public func changed() -> MacCursor? {
        guard let cursor = NSCursor.currentSystem else { return nil }
        return changed(cursor)
    }

    /// The same, for a cursor in hand (`mpctl serve` picks one for the spot under its pointer).
    public func changed(_ cursor: NSCursor) -> MacCursor? {
        guard let (rep, key) = MacCursor.raster(cursor), key != lastKey else { return nil }
        guard let c = MacCursor.make(rep, key: key, hotSpot: cursor.hotSpot) else { return nil }
        lastKey = key
        return c
    }
}

extension MacCursor {
    /// The cursor drawn afresh at twice its size in points, and what tells this shape from
    /// another (its pixels and its hot spot).
    @MainActor static func raster(_ cursor: NSCursor) -> (NSBitmapImageRep, Data)? {
        let image = cursor.image
        let size = image.size
        guard size.width > 0, size.height > 0, size.width <= maxSide, size.height <= maxSide else { return nil }
        let w = Int((size.width * 2).rounded(.up)), h = Int((size.height * 2).rounded(.up))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let bytes = rep.bitmapData else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        var key = Data(bytes: bytes, count: rep.bytesPerRow * rep.pixelsHigh)
        key.append(Data("\(cursor.hotSpot.x),\(cursor.hotSpot.y),\(size.width),\(size.height)".utf8))
        return (rep, key)
    }

    static func make(_ rep: NSBitmapImageRep, key: Data, hotSpot hot: NSPoint) -> MacCursor? {
        guard let png = rep.representation(using: .png, properties: [:]), png.count <= maxBytes else { return nil }
        let size = rep.size
        let id = SHA256.hash(data: key).prefix(8).map { String(format: "%02x", $0) }.joined()
        let c = MacCursor(id: id, png: png, width: size.width, height: size.height,
                          hotX: min(max(0, hot.x), size.width), hotY: min(max(0, hot.y), size.height))
        return c.isValid ? c : nil
    }
}
#endif
