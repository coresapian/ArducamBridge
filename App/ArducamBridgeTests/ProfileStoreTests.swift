import XCTest
@testable import ArducamBridge

final class ProfileStoreTests: XCTestCase {
    func testSaveAndLoadProfiles() {
        let suiteName = "ProfileStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = ProfileStore(defaults: defaults)

        let profile = BridgeProfile(
            name: "Warehouse Cam",
            streamURL: "http://pi.local:7123/stream.mjpg"
        )

        store.saveProfiles([profile])
        store.saveSelectedProfileID(profile.id)

        XCTAssertEqual(store.loadProfiles(), [profile])
        XCTAssertEqual(store.loadSelectedProfileID(), profile.id)

        defaults.removePersistentDomain(forName: suiteName)
    }
}
