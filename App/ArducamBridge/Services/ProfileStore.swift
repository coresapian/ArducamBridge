import Foundation

final class ProfileStore {
    private let defaults: UserDefaults
    private let profilesKey = "ios.bridge.profiles"
    private let selectionKey = "ios.bridge.selectedProfileID"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadProfiles() -> [BridgeProfile] {
        guard let data = defaults.data(forKey: profilesKey) else {
            return []
        }

        do {
            return try JSONDecoder().decode([BridgeProfile].self, from: data)
        } catch {
            return []
        }
    }

    func saveProfiles(_ profiles: [BridgeProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else {
            return
        }
        defaults.set(data, forKey: profilesKey)
    }

    func loadSelectedProfileID() -> UUID? {
        guard let rawValue = defaults.string(forKey: selectionKey) else {
            return nil
        }
        return UUID(uuidString: rawValue)
    }

    func saveSelectedProfileID(_ id: UUID?) {
        defaults.set(id?.uuidString, forKey: selectionKey)
    }
}
