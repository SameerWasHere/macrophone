import Foundation

/// Which device this is (Nov 18 2026: the iPad version). Read from the hardware's model, not
/// UIKit, so anything can ask — a static, a model off the main actor, a string being built.
enum Device {
    static let isPad: Bool = {
        var s = utsname()
        uname(&s)
        let machine = withUnsafeBytes(of: &s.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        // (On a simulator the machine is the Mac's; the simulated model is in the environment.)
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine
        return model.hasPrefix("iPad")
    }()
    /// "iPhone" or "iPad", for every sentence that names this device.
    static let name = isPad ? "iPad" : "iPhone"
    /// Its SF Symbol.
    static let symbol = isPad ? "ipad" : "iphone.gen3"
    static let plainSymbol = isPad ? "ipad" : "iphone"
}
