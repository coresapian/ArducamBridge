import Foundation

enum FocusMode: String, CaseIterable, Identifiable, Codable {
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

    static func matching(settings: BridgeSettings) -> StreamPreset? {
        switch (settings.width, settings.height, Int(settings.framerate.rounded()), settings.quality) {
        case (640, 480, 12, 55):
            return .lowLatency
        case (1280, 720, 6, 65):
            return .balanced
        case (1920, 1080, 4, 75):
            return .detail
        default:
            return nil
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

struct BridgeHealthResponse: Codable, Equatable {
    var running: Bool
    var cameraRunning: Bool?
    var frameCounter: Int
    var lastFrameAgeSeconds: Double?
    var error: String?
    var streamURL: String
    var snapshotURL: String
    var settingsURL: String
    var settings: BridgeSettings
    var stderrTail: [String]?

    enum CodingKeys: String, CodingKey {
        case running
        case cameraRunning = "camera_running"
        case frameCounter = "frame_counter"
        case lastFrameAgeSeconds = "last_frame_age_s"
        case error
        case streamURL = "stream_url"
        case snapshotURL = "snapshot_url"
        case settingsURL = "settings_url"
        case settings
        case stderrTail = "stderr_tail"
    }
}

struct BridgeProfile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var streamURL: String
    var snapshotURL: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        streamURL: String,
        snapshotURL: String = "",
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.streamURL = streamURL
        self.snapshotURL = snapshotURL
        self.createdAt = createdAt
    }

    var trimmedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Pi Camera" : trimmed
    }

    var trimmedStreamURL: String {
        streamURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var resolvedSnapshotURL: String {
        let trimmed = snapshotURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return BridgeAPI.derivedSnapshotURL(from: trimmedStreamURL)
        }
        return trimmed
    }
}

struct SnapshotRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var profileID: UUID
    var profileName: String
    var fileName: String
    var createdAt: Date
    var sizeBytes: Int

    init(
        id: UUID = UUID(),
        profileID: UUID,
        profileName: String,
        fileName: String,
        createdAt: Date = .now,
        sizeBytes: Int
    ) {
        self.id = id
        self.profileID = profileID
        self.profileName = profileName
        self.fileName = fileName
        self.createdAt = createdAt
        self.sizeBytes = sizeBytes
    }
}

enum StatusTone {
    case idle
    case live
    case fallback
    case error
    case success
}
