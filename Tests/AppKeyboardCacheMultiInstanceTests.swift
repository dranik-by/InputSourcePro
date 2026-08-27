import AppKit
import XCTest
@testable import Input_Source_Pro

@MainActor
final class AppKeyboardCacheMultiInstanceTests: XCTestCase {
    func testRemoveByBundleIdClearsPerProcessKeys() {
        let suiteName = "isp.cache.test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        defaults.set(
            [
                "com.jetbrains.clion#1001": "layout.ru",
                "com.jetbrains.clion#1002": "layout.en",
                "com.jetbrains.clion": "layout.legacy",
                "com.jetbrains.clion_example.com": "layout.site",
                "com.other.app#9": "layout.keep",
            ] as [String: String],
            forKey: "ISPAppKeyboardCache.v1"
        )

        let cache = AppKeyboardCache(defaults: defaults)
        XCTAssertEqual(cache.entryCount, 5)

        cache.remove(byBundleId: "com.jetbrains.clion")
        XCTAssertEqual(cache.entryCount, 1)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testWindowKeyDoesNotFallBackWhenExactMissingIfUsingExactAPI() {
        let suiteName = "isp.cache.test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let cache = AppKeyboardCache(defaults: defaults)
        let app = NSRunningApplication.current
        let processKind = AppKind.normal(
            app: app,
            info: (focusedElement: nil, isFocusOnInputContainer: false, windowId: nil)
        )
        let windowKind = AppKind.normal(
            app: app,
            info: (focusedElement: nil, isFocusOnInputContainer: false, windowId: "w9")
        )
        let source = InputSource.getCurrentInputSource()

        cache.save(processKind, keyboard: source)
        XCTAssertNil(cache.retrieveExact(windowKind))
        XCTAssertEqual(cache.retrieve(windowKind)?.persistentIdentifier, source.persistentIdentifier)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testSaveWindowDoesNotMirrorProcessKey() {
        let suiteName = "isp.cache.test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let cache = AppKeyboardCache(defaults: defaults)
        let app = NSRunningApplication.current
        let windowKind = AppKind.normal(
            app: app,
            info: (focusedElement: nil, isFocusOnInputContainer: false, windowId: "w3")
        )
        let processKind = AppKind.normal(
            app: app,
            info: (focusedElement: nil, isFocusOnInputContainer: false, windowId: nil)
        )
        let source = InputSource.getCurrentInputSource()

        cache.save(windowKind, keyboard: source)
        XCTAssertEqual(cache.retrieveExact(windowKind)?.persistentIdentifier, source.persistentIdentifier)
        XCTAssertNil(cache.retrieveExact(processKind))

        defaults.removePersistentDomain(forName: suiteName)
    }
}
