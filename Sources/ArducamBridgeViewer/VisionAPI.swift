import Foundation

struct VisionEvent: Codable, Identifiable {
    var timestamp: String
    var frameIndex: Int
    var eventType: String
    var zone: String
    var trackID: Int
    var classID: Int
    var className: String
    var confidence: Double
    var center: [Double]
    var inventoryDelta: Int

    enum CodingKeys: String, CodingKey {
        case timestamp
        case frameIndex = "frame_index"
        case eventType = "event_type"
        case zone
        case trackID = "track_id"
        case classID = "class_id"
        case className = "class_name"
        case confidence
        case center
        case inventoryDelta = "inventory_delta"
    }

    var id: String {
        "\(timestamp)-\(frameIndex)-\(trackID)-\(eventType)"
    }
}

struct VisionTrackZoneState: Codable {
    var stable: String?
    var pending: String?
}

struct VisionTrack: Codable, Identifiable {
    var trackID: Int
    var classID: Int
    var className: String
    var lastSeenFrame: Int
    var confidence: Double
    var center: [Double]
    var zones: [String: VisionTrackZoneState]

    enum CodingKeys: String, CodingKey {
        case trackID = "track_id"
        case classID = "class_id"
        case className = "class_name"
        case lastSeenFrame = "last_seen_frame"
        case confidence
        case center
        case zones
    }

    var id: Int { trackID }
}

struct VisionModelSummary: Codable {
    var backend: String
    var weights: String
    var imgsz: Int
    var confidence: Double
}

struct VisionLatestSummary: Codable {
    var status: String?
    var message: String?
    var zoneCount: Int?
    var frameRate: Double?

    enum CodingKeys: String, CodingKey {
        case status
        case message
        case zoneCount = "zone_count"
        case frameRate = "frame_rate"
    }
}

struct VisionHealthResponse: Codable {
    var running: Bool
    var sourceStreamURL: String
    var annotatedStreamURL: String
    var snapshotURL: String
    var eventsURL: String
    var processedFrames: Int
    var currentFrameIndex: Int
    var processingFPS: Double
    var inventoryDelta: [String: Int]
    var tracks: [VisionTrack]
    var recentEvents: [VisionEvent]
    var model: VisionModelSummary
    var latest: VisionLatestSummary

    enum CodingKeys: String, CodingKey {
        case running
        case sourceStreamURL = "source_stream_url"
        case annotatedStreamURL = "annotated_stream_url"
        case snapshotURL = "snapshot_url"
        case eventsURL = "events_url"
        case processedFrames = "processed_frames"
        case currentFrameIndex = "current_frame_index"
        case processingFPS = "processing_fps"
        case inventoryDelta = "inventory_delta"
        case tracks
        case recentEvents = "recent_events"
        case model
        case latest
    }
}

struct VisionEventsResponse: Codable {
    var inventoryDelta: [String: Int]
    var recentEvents: [VisionEvent]

    enum CodingKeys: String, CodingKey {
        case inventoryDelta = "inventory_delta"
        case recentEvents = "recent_events"
    }
}

enum VisionAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The detector URL is invalid."
        case .invalidResponse:
            return "The detector returned an unexpected response."
        case .httpError(let message):
            return message
        }
    }
}

enum VisionAPI {
    static func fetchHealth(from baseURL: String) async throws -> VisionHealthResponse {
        let url = try endpointURL(from: baseURL, path: "healthz")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try decoder.decode(VisionHealthResponse.self, from: data)
    }

    static func fetchEvents(from baseURL: String) async throws -> VisionEventsResponse {
        let url = try endpointURL(from: baseURL, path: "events")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try decoder.decode(VisionEventsResponse.self, from: data)
    }

    static func annotatedStreamURL(from baseURL: String) -> String {
        derivedEndpoint(from: baseURL, path: "annotated.mjpg")
    }

    static func snapshotURL(from baseURL: String) -> String {
        derivedEndpoint(from: baseURL, path: "snapshot.jpg")
    }

    private static func derivedEndpoint(from baseURL: String, path: String) -> String {
        guard let sourceURL = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
        else {
            return "http://127.0.0.1:9134/\(path)"
        }
        components.path = "/\(path)"
        components.query = nil
        components.fragment = nil
        return components.string ?? "http://127.0.0.1:9134/\(path)"
    }

    private static func endpointURL(from baseURL: String, path: String) throws -> URL {
        guard let sourceURL = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
        else {
            throw VisionAPIError.invalidURL
        }
        components.path = "/\(path)"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw VisionAPIError.invalidURL
        }
        return url
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VisionAPIError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            if let envelope = try? decoder.decode(VisionErrorEnvelope.self, from: data) {
                throw VisionAPIError.httpError(envelope.error)
            }
            throw VisionAPIError.httpError("Detector request failed with status \(httpResponse.statusCode).")
        }
    }

    private static let decoder = JSONDecoder()
}

private struct VisionErrorEnvelope: Codable {
    var error: String
}
