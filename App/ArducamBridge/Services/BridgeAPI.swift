import Foundation

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
            return "The bridge URL is invalid."
        case .invalidResponse:
            return "The bridge returned an unexpected response."
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

        components.path = siblingEndpointPath(from: components.path, endpoint: "snapshot.jpg")
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
        guard let url = URL(string: snapshotURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw BridgeAPIError.invalidURL
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return data
    }

    static func endpointURL(from streamURL: String, path: String) throws -> URL {
        guard let sourceURL = URL(string: streamURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw BridgeAPIError.invalidURL
        }
        guard var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false) else {
            throw BridgeAPIError.invalidURL
        }
        components.path = siblingEndpointPath(from: components.path, endpoint: path)
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw BridgeAPIError.invalidURL
        }
        return url
    }

    private static func siblingEndpointPath(from originalPath: String, endpoint: String) -> String {
        let cleanEndpoint = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanEndpoint.isEmpty else {
            return originalPath.isEmpty ? "/" : originalPath
        }

        if originalPath.hasSuffix("/stream.mjpg") {
            return originalPath.replacingOccurrences(of: "/stream.mjpg", with: "/\(cleanEndpoint)")
        }

        if originalPath.isEmpty || originalPath == "/" {
            return "/\(cleanEndpoint)"
        }

        if originalPath.hasSuffix("/") {
            return originalPath + cleanEndpoint
        }

        let lastComponent = originalPath.split(separator: "/").last.map(String.init) ?? ""
        if lastComponent.contains(".") {
            let basePath = originalPath
                .split(separator: "/")
                .dropLast()
                .map(String.init)
                .joined(separator: "/")
            if basePath.isEmpty {
                return "/\(cleanEndpoint)"
            }
            return "/\(basePath)/\(cleanEndpoint)"
        }

        return "\(originalPath)/\(cleanEndpoint)"
    }

    static func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BridgeAPIError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            if let error = try? decoder.decode(BridgeErrorEnvelope.self, from: data) {
                throw BridgeAPIError.httpError(error.error)
            }
            throw BridgeAPIError.httpError("Bridge request failed with status \(httpResponse.statusCode).")
        }
    }

    private static let decoder: JSONDecoder = {
        JSONDecoder()
    }()
}
