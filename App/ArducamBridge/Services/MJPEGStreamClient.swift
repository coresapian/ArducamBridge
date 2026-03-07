import Foundation
import UIKit

enum PreviewMode {
    case idle
    case connecting
    case live
    case fallback
    case error
}

@MainActor
final class MJPEGStreamClient: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var mode: PreviewMode = .idle
    @Published private(set) var statusMessage = "Select a bridge and connect."

    private var liveTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var connectionID = UUID()

    func connect(streamURL: URL, snapshotURL: URL?) {
        disconnect(clearImage: false)
        connectionID = UUID()
        mode = .connecting
        statusMessage = "Opening \(streamURL.absoluteString)"

        let currentID = connectionID
        liveTask = Task { [weak self] in
            await self?.runLiveAttempt(connectionID: currentID, streamURL: streamURL, snapshotURL: snapshotURL, isRetry: false)
        }
    }

    func disconnect(clearImage: Bool = true) {
        liveTask?.cancel()
        fallbackTask?.cancel()
        retryTask?.cancel()
        liveTask = nil
        fallbackTask = nil
        retryTask = nil
        connectionID = UUID()
        mode = .idle
        statusMessage = "Preview idle."
        if clearImage {
            image = nil
        }
    }

    private func runLiveAttempt(
        connectionID: UUID,
        streamURL: URL,
        snapshotURL: URL?,
        isRetry: Bool
    ) async {
        guard self.connectionID == connectionID else { return }

        mode = .connecting
        statusMessage = isRetry
            ? "Retrying live MJPEG at \(streamURL.absoluteString)"
            : "Opening \(streamURL.absoluteString)"

        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self else { return }
            guard !Task.isCancelled, self.connectionID == connectionID, self.mode != .live else { return }
            self.liveTask?.cancel()
            await self.beginFallback(
                connectionID: connectionID,
                streamURL: streamURL,
                snapshotURL: snapshotURL,
                reason: "MJPEG stream timed out. Falling back to still snapshots."
            )
        }

        do {
            var request = URLRequest(url: streamURL)
            request.timeoutInterval = 30
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            try BridgeAPI.validate(response: response, data: Data())

            var buffer = Data()

            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte)

                while let frameData = nextFrame(in: &buffer) {
                    guard let frameImage = UIImage(data: frameData) else {
                        continue
                    }

                    if mode != .live {
                        mode = .live
                        statusMessage = "Live MJPEG stream connected."
                    }
                    image = frameImage
                    watchdog.cancel()
                }
            }

            if Task.isCancelled {
                watchdog.cancel()
                return
            }

            throw BridgeAPIError.httpError("The live MJPEG stream ended unexpectedly.")
        } catch {
            watchdog.cancel()
            guard !Task.isCancelled, self.connectionID == connectionID else { return }
            await beginFallback(
                connectionID: connectionID,
                streamURL: streamURL,
                snapshotURL: snapshotURL,
                reason: "MJPEG stream unavailable. Falling back to still snapshots."
            )
        }
    }

    private func beginFallback(
        connectionID: UUID,
        streamURL: URL,
        snapshotURL: URL?,
        reason: String
    ) async {
        guard self.connectionID == connectionID else { return }

        guard let snapshotURL else {
            mode = .error
            statusMessage = "\(reason) No snapshot URL is configured."
            return
        }

        liveTask?.cancel()
        mode = .fallback
        statusMessage = reason

        fallbackTask?.cancel()
        fallbackTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                do {
                    let (data, response) = try await URLSession.shared.data(from: snapshotURL.cacheBusted())
                    try BridgeAPI.validate(response: response, data: data)
                    if let snapshotImage = UIImage(data: data) {
                        await MainActor.run {
                            guard self.connectionID == connectionID else { return }
                            self.image = snapshotImage
                            self.mode = .fallback
                            self.statusMessage = "Snapshot fallback is active."
                        }
                    }
                } catch {
                    await MainActor.run {
                        guard self.connectionID == connectionID else { return }
                        self.mode = .error
                        self.statusMessage = "Snapshot refresh failed. Check the bridge server."
                    }
                }

                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }

        retryTask?.cancel()
        retryTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                guard self.connectionID == connectionID else { return }
                guard self.mode == .fallback else { continue }

                self.liveTask?.cancel()
                self.liveTask = Task { [weak self] in
                    await self?.runLiveAttempt(
                        connectionID: connectionID,
                        streamURL: streamURL,
                        snapshotURL: snapshotURL,
                        isRetry: true
                    )
                }
            }
        }
    }

    private func nextFrame(in buffer: inout Data) -> Data? {
        let startMarker = Data([0xFF, 0xD8])
        let endMarker = Data([0xFF, 0xD9])

        guard let start = buffer.range(of: startMarker)?.lowerBound else {
            if buffer.count > 2 * 1024 * 1024 {
                buffer.removeAll(keepingCapacity: false)
            }
            return nil
        }

        if start > 0 {
            buffer.removeSubrange(0 ..< start)
        }

        guard let end = buffer.range(of: endMarker, options: [], in: 2 ..< buffer.count)?.upperBound else {
            if buffer.count > 8 * 1024 * 1024 {
                buffer = Data(buffer.suffix(2))
            }
            return nil
        }

        let frame = buffer.prefix(end)
        buffer.removeSubrange(0 ..< end)
        return Data(frame)
    }
}
private extension URL {
    func cacheBusted() -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }

        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "ts" }
        queryItems.append(URLQueryItem(name: "ts", value: "\(Int(Date().timeIntervalSince1970 * 1000))"))
        components.queryItems = queryItems
        return components.url ?? self
    }
}
