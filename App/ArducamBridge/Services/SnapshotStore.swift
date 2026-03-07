import Foundation

final class SnapshotStore {
    private let fileManager: FileManager
    private let metadataURL: URL
    private let snapshotDirectoryURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let rootURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.snapshotDirectoryURL = rootURL.appendingPathComponent("ArducamBridge/Snapshots", isDirectory: true)
        self.metadataURL = rootURL.appendingPathComponent("ArducamBridge/snapshots.json", isDirectory: false)

        try? fileManager.createDirectory(
            at: snapshotDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    func loadRecords() -> [SnapshotRecord] {
        guard let data = try? Data(contentsOf: metadataURL) else {
            return []
        }

        do {
            return try JSONDecoder().decode([SnapshotRecord].self, from: data)
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            return []
        }
    }

    func saveSnapshot(data: Data, profile: BridgeProfile) throws -> SnapshotRecord {
        let fileName = snapshotFileName(for: profile)
        let destinationURL = snapshotDirectoryURL.appendingPathComponent(fileName)
        try data.write(to: destinationURL, options: .atomic)

        let record = SnapshotRecord(
            profileID: profile.id,
            profileName: profile.trimmedName,
            fileName: fileName,
            sizeBytes: data.count
        )
        return record
    }

    func saveRecords(_ records: [SnapshotRecord]) {
        guard let data = try? JSONEncoder().encode(records) else {
            return
        }
        try? fileManager.createDirectory(
            at: metadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try? data.write(to: metadataURL, options: .atomic)
    }

    func deleteSnapshot(for record: SnapshotRecord) {
        let url = fileURL(for: record)
        try? fileManager.removeItem(at: url)
    }

    func fileURL(for record: SnapshotRecord) -> URL {
        snapshotDirectoryURL.appendingPathComponent(record.fileName)
    }

    private func snapshotFileName(for profile: BridgeProfile) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: .now)
        let sanitizedName = profile.trimmedName
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let baseName = sanitizedName.isEmpty ? "bridge" : sanitizedName
        return "\(baseName)-\(timestamp).jpg"
    }
}
