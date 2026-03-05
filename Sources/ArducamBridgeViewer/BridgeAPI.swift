import Foundation

enum FocusMode: String, CaseIterable, Identifiable {
    case auto
    case continuous
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:
            return "Auto"
        case .continuous:
            return "Continuous"
        case .manual:
            return "Manual"
        }
    }
}

enum StreamPreset: String, CaseIterable, Identifiable {
    case lowLatency
    case balanced
    case detail

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lowLatency:
            return "Low Latency"
        case .balanced:
            return "Balanced"
        case .detail:
            return "Detail"
        }
    }

    var summary: String {
        switch self {
        case .lowLatency:
            return "640x480 · 12 fps · q55"
        case .balanced:
            return "1280x720 · 6 fps · q65"
        case .detail:
            return "1920x1080 · 4 fps · q75"
        }
    }

    var payload: [String: Any] {
        switch self {
        case .lowLatency:
            return [
                "width": 640,
                "height": 480,
                "framerate": 12,
                "quality": 55,
            ]
        case .balanced:
            return [
                "width": 1280,
                "height": 720,
                "framerate": 6,
                "quality": 65,
            ]
        case .detail:
            return [
                "width": 1920,
                "height": 1080,
                "framerate": 4,
                "quality": 75,
            ]
        }
    }

    static func matching(settings: BridgeSettings) -> StreamPreset {
        switch (settings.width, settings.height, Int(settings.framerate.rounded()), settings.quality) {
        case (640, 480, 12, 55):
            return .lowLatency
        case (1280, 720, 6, 65):
            return .balanced
        case (1920, 1080, 4, 75):
            return .detail
        default:
            return .balanced
        }
    }
}

struct BridgeSettings: Codable, Equatable {
    var width: Int
    var height: Int
    var framerate: Double
    var quality: Int
    var rotation: Int
    var camera: Int
    var autofocusMode: String
    var autofocusRange: String
    var autofocusSpeed: String
    var lensPosition: Double?

    enum CodingKeys: String, CodingKey {
        case width
        case height
        case framerate
        case quality
        case rotation
        case camera
        case autofocusMode = "autofocus_mode"
        case autofocusRange = "autofocus_range"
        case autofocusSpeed = "autofocus_speed"
        case lensPosition = "lens_position"
    }

    static let placeholder = BridgeSettings(
        width: 1280,
        height: 720,
        framerate: 6,
        quality: 65,
        rotation: 0,
        camera: 0,
        autofocusMode: FocusMode.auto.rawValue,
        autofocusRange: "normal",
        autofocusSpeed: "normal",
        lensPosition: nil
    )

    var focusMode: FocusMode {
        get { FocusMode(rawValue: autofocusMode) ?? .auto }
        set { autofocusMode = newValue.rawValue }
    }

    var resolutionLabel: String {
        "\(width)x\(height)"
    }
}

struct BridgeHealthResponse: Codable {
    var running: Bool
    var frameCounter: Int
    var lastFrameAgeSeconds: Double?
    var error: String?
    var streamURL: String
    var snapshotURL: String
    var settingsURL: String
    var settings: BridgeSettings

    enum CodingKeys: String, CodingKey {
        case running
        case frameCounter = "frame_counter"
        case lastFrameAgeSeconds = "last_frame_age_s"
        case error
        case streamURL = "stream_url"
        case snapshotURL = "snapshot_url"
        case settingsURL = "settings_url"
        case settings
    }
}

private struct BridgeSettingsEnvelope: Codable {
    var settings: BridgeSettings
}

private struct BridgeErrorEnvelope: Codable {
    var error: String
}

enum BridgeAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The Pi URL is invalid."
        case .invalidResponse:
            return "The Pi returned an unexpected response."
        case .httpError(let message):
            return message
        }
    }
}

enum BridgeAPI {
    static func derivedSnapshotURL(from streamURL: String) -> String {
        guard var components = URLComponents(string: streamURL) else {
            return "http://pi-zero-1.local:7123/snapshot.jpg"
        }

        if components.path.hasSuffix("/stream.mjpg") {
            components.path = components.path.replacingOccurrences(of: "/stream.mjpg", with: "/snapshot.jpg")
            components.query = nil
            return components.string ?? "http://pi-zero-1.local:7123/snapshot.jpg"
        }

        if components.path.hasSuffix("/") {
            components.path += "snapshot.jpg"
        } else if components.path.isEmpty {
            components.path = "/snapshot.jpg"
        } else {
            components.path += "/snapshot.jpg"
        }

        components.query = nil
        return components.string ?? "http://pi-zero-1.local:7123/snapshot.jpg"
    }

    static func fetchHealth(from streamURL: String) async throws -> BridgeHealthResponse {
        let url = try endpointURL(from: streamURL, path: "healthz")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try decoder.decode(BridgeHealthResponse.self, from: data)
    }

    static func updateSettings(from streamURL: String, payload: [String: Any]) async throws -> BridgeSettings {
        let url = try endpointURL(from: streamURL, path: "settings")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(BridgeSettingsEnvelope.self, from: data).settings
    }

    static func downloadSnapshot(from snapshotURL: String) async throws -> Data {
        guard let url = URL(string: snapshotURL) else {
            throw BridgeAPIError.invalidURL
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return data
    }

    private static func endpointURL(from streamURL: String, path: String) throws -> URL {
        guard let sourceURL = URL(string: streamURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw BridgeAPIError.invalidURL
        }
        guard var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false) else {
            throw BridgeAPIError.invalidURL
        }
        components.path = "/\(path)"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw BridgeAPIError.invalidURL
        }
        return url
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BridgeAPIError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            if let error = try? decoder.decode(BridgeErrorEnvelope.self, from: data) {
                throw BridgeAPIError.httpError(error.error)
            }
            throw BridgeAPIError.httpError("Pi request failed with status \(httpResponse.statusCode).")
        }
    }

    private static let decoder: JSONDecoder = {
        JSONDecoder()
    }()
}
