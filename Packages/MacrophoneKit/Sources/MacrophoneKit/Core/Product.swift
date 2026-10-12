import Foundation

/// Every user-facing name and address in one place, so a rename is one edit.
public enum Product {
    public static let name = "Macrophone"
    /// Bonjour service type the Mac advertises and the phone browses for.
    public static let serviceType = "_macrophone._tcp"
    /// QR / deep-link scheme.
    public static let urlScheme = "macrophone"
    public static let website = URL(string: "https://sameer.us/macrophone")!
    public static let macDownload = URL(string: "https://sameer.us/macrophone/download")!
    public static let docs = URL(string: "https://sameer.us/macrophone/docs")!
    /// Short form shown large on the phone during setup.
    public static let macDownloadDisplay = "sameer.us/macrophone"
    public static let protocolVersion = 1
    /// Local pull API on the Mac (127.0.0.1 only).
    public static let apiPort: UInt16 = 47_820
}

extension NSLock {
    /// Scoped locking that's safe to call from async code (never held across an await).
    @inline(__always)
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
