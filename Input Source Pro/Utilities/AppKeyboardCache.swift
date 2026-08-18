import AppKit
import Foundation
import os

@MainActor
class AppKeyboardCache {
    private static let storageKey = "ISPAppKeyboardCache.v1"

    private var cache: [String: String]
    private let defaults: UserDefaults

    let logger = ISPLogger(category: String(describing: AppKeyboardCache.self))

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.dictionary(forKey: Self.storageKey) as? [String: String] {
            cache = stored
        } else {
            cache = [:]
        }
        logger.debug { "Loaded \(self.cache.count) keyboard memory entries" }
    }

    var entryCount: Int { cache.count }

    func remove(_ kind: AppKind) {
        guard let id = kind.getId(), cache[id] != nil else { return }
        logger.debug { "Remove #\(id)" }
        cache.removeValue(forKey: id)
        persist()
    }

    func save(_ kind: AppKind, keyboard: InputSource?) {
        guard let id = kind.getId() else { return }

        if let keyboardId = keyboard?.persistentIdentifier {
            guard cache[id] != keyboardId else { return }
            logger.debug { "Save \(id)#\(keyboardId)" }
            cache[id] = keyboardId
            persist()
        } else if cache[id] != nil {
            cache.removeValue(forKey: id)
            persist()
        }
    }

    func retrieve(_ kind: AppKind) -> InputSource? {
        guard let id = kind.getId(),
              let keyboardId = cache[id]
        else { return nil }

        logger.debug { "Retrieve \(id)#\(keyboardId)" }

        return InputSource.resolvePersistedIdentifier(keyboardId)
    }

    func clear() {
        logger.debug { "Clear All" }
        cache.removeAll()
        persist()
    }

    func remove(byBundleId bundleId: String) {
        let prefix = "\(bundleId)_"
        let keys = cache.keys.filter { $0 == bundleId || $0.hasPrefix(prefix) }
        guard !keys.isEmpty else { return }

        for key in keys {
            logger.debug { "Remove \(bundleId)#\(key)" }
            cache.removeValue(forKey: key)
        }
        persist()
    }

    private func persist() {
        defaults.set(cache, forKey: Self.storageKey)
    }
}
