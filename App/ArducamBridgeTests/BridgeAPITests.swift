import XCTest
@testable import ArducamBridge

final class BridgeAPITests: XCTestCase {
    func testDerivedSnapshotURLReplacesStreamPath() {
        XCTAssertEqual(
            BridgeAPI.derivedSnapshotURL(from: "http://pi.local:7123/stream.mjpg"),
            "http://pi.local:7123/snapshot.jpg"
        )
    }

    func testDerivedSnapshotURLPreservesSubpathHost() {
        XCTAssertEqual(
            BridgeAPI.derivedSnapshotURL(from: "http://example.com/camera/stream.mjpg"),
            "http://example.com/camera/snapshot.jpg"
        )
    }

    func testEndpointURLUsesSiblingPath() throws {
        let endpoint = try BridgeAPI.endpointURL(
            from: "http://example.com/bridge/stream.mjpg?token=1",
            path: "healthz"
        )

        XCTAssertEqual(endpoint.absoluteString, "http://example.com/bridge/healthz")
    }
}
