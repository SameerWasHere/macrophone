import Foundation
import Speech

/// The recognizer languages this iPhone can run fully on-device. Anything that would need
/// Apple's servers is hidden — the privacy promise depends on it.
enum Languages {
    struct Option: Identifiable, Hashable {
        var id: String
        var name: String
    }

    /// Computed once per launch: building a recognizer per locale is cheap but not free.
    static let onDevice: [Option] = {
        var seen = Set<String>()
        var out: [Option] = []
        for locale in SFSpeechRecognizer.supportedLocales() {
            let id = locale.identifier.replacingOccurrences(of: "_", with: "-")
            guard seen.insert(id).inserted,
                  let r = SFSpeechRecognizer(locale: locale), r.supportsOnDeviceRecognition else { continue }
            out.append(Option(id: id, name: displayName(id)))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    static func displayName(_ id: String) -> String {
        Locale(identifier: "en-US").localizedString(forIdentifier: id) ?? id
    }

    static func isOnDevice(_ id: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: id))?.supportsOnDeviceRecognition == true
    }

    /// The phone's own language when it runs on-device, else US English.
    static var defaultIdentifier: String {
        let current = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        if let lang = Locale.current.language.languageCode?.identifier,
           let region = Locale.current.region?.identifier {
            let id = "\(lang)-\(region)"
            if isOnDevice(id) { return id }
        }
        if isOnDevice(current) { return current }
        return "en-US"
    }
}
