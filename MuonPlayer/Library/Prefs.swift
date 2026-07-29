import Foundation

/// The handful of small settings the core persists: playback mode, output volume,
/// the gapless fix mode, the Last.fm session.
///
/// On Apple this is `UserDefaults`. On Android it is not: corelibs Foundation's
/// own `UserDefaults` does not survive a relaunch there — verified on device, and
/// `synchronize()` makes no difference — so anything written through it is lost
/// without an error. Since that silently un-persists a user's login, the same keys
/// go to a JSON file in Application Support instead.
enum Prefs {
    static func string(forKey key: String) -> String? {
        #if os(Android)
        store.value(key)
        #else
        UserDefaults.standard.string(forKey: key)
        #endif
    }

    static func float(forKey key: String) -> Float? {
        #if os(Android)
        store.value(key).flatMap(Float.init)
        #else
        UserDefaults.standard.object(forKey: key) as? Float
        #endif
    }

    static func set(_ value: String, forKey key: String) {
        #if os(Android)
        store.set(value, key)
        #else
        UserDefaults.standard.set(value, forKey: key)
        #endif
    }

    static func set(_ value: Float, forKey key: String) {
        #if os(Android)
        store.set(String(value), key)
        #else
        UserDefaults.standard.set(value, forKey: key)
        #endif
    }

    static func removeObject(forKey key: String) {
        #if os(Android)
        store.set(nil, key)
        #else
        UserDefaults.standard.removeObject(forKey: key)
        #endif
    }

    #if os(Android)
    private static let store = FileStore()

    /// Rewrites the whole file on every set. There are a handful of keys and they
    /// change on user actions, so the simplicity is worth more than the writes.
    private final class FileStore: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String]

        private static var url: URL {
            let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first!
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            return support.appendingPathComponent("prefs.json")
        }

        init() {
            let data = (try? Data(contentsOf: Self.url)) ?? Data()
            values = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }

        func value(_ key: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return values[key]
        }

        func set(_ value: String?, _ key: String) {
            lock.lock()
            values[key] = value
            let snapshot = values
            lock.unlock()
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.url, options: .atomic)
        }
    }
    #endif
}
