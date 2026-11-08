import XCTest
@testable import MacrophoneKit

final class DictionaryImportTests: XCTestCase {
    func testSameerOSVocabularyFile() {
        let file = """
        # Hey Claude — names spelled your way
        SameerOS
        Vercel
        # Sounds-like (said fast)
        SameerOS: summer or less, some or less
        iPhone Duo   # the foldable
        vercel
        """
        XCTAssertEqual(DictionaryImport.parse(file), ["SameerOS", "Vercel", "iPhone Duo"])
        XCTAssertEqual(DictionaryImport.merge(["Xcode"], ["xcode", "TestFlight"]), ["Xcode", "TestFlight"])
    }
}
