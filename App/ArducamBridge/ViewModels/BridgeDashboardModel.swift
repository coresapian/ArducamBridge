import Foundation

@MainActor
final class BridgeDashboardModel: ObservableObject {
    @Published private(set) var profiles: [BridgeProfile]
    @Published var selectedProfileID: UUID?
    @Published private(set) var snapshots: [SnapshotRecord]
    @Published private(set) var health: BridgeHealthResponse?
    @Published private(set) var currentSettings = BridgeSettings.placeholder
    @Published private(set) var selectedPreset: StreamPreset? = .balanced
    @Published var focusMode: FocusMode = .auto
    @Published var manualLensPosition = 0.0
    @Published private(set) var activityMessage: String
    @Published private(set) var activityTone: StatusTone
    @Published private(set) var isSyncing = false
    @Published private(set) var isApplyingPreset = false
    @Published private(set) var isApplyingFocus = false
    @Published private(set) var isSavingSnapshot = false

    let preview = MJPEGStreamClient()

    private let profileStore: ProfileStore
    private let snapshotStore: SnapshotStore

    init(
        profileStore: ProfileStore = ProfileStore(),
        snapshotStore: SnapshotStore = SnapshotStore()
    ) {
        self.profileStore = profileStore
        self.snapshotStore = snapshotStore

        let loadedProfiles = profileStore.loadProfiles().sorted { $0.createdAt < $1.createdAt }
        let loadedSnapshots = snapshotStore.loadRecords()
        let loadedSelection = profileStore.loadSelectedProfileID()
        let resolvedSelection = loadedProfiles.contains(where: { $0.id == loadedSelection })
            ? loadedSelection
            : loadedProfiles.first?.id

        self.profiles = loadedProfiles
        self.snapshots = loadedSnapshots
        self.selectedProfileID = resolvedSelection

        if let profile = loadedProfiles.first(where: { $0.id == resolvedSelection }) {
            self.activityMessage = "Ready to connect to \(profile.trimmedName)."
            self.activityTone = .idle
        } else {
            self.activityMessage = "Create your first bridge profile to begin."
            self.activityTone = .idle
        }
    }

    var selectedProfile: BridgeProfile? {
        profiles.first(where: { $0.id == selectedProfileID })
    }

    var hasProfiles: Bool {
        !profiles.isEmpty
    }

    var canConnect: Bool {
        selectedProfile != nil
    }

    func selectProfile(_ profile: BridgeProfile) {
        selectedProfileID = profile.id
        profileStore.saveSelectedProfileID(profile.id)
        setActivity("Active bridge set to \(profile.trimmedName).", tone: .idle)
    }

    func upsertProfile(_ profile: BridgeProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
            setActivity("Updated \(profile.trimmedName).", tone: .success)
        } else {
            profiles.append(profile)
            profiles.sort { $0.createdAt < $1.createdAt }
            setActivity("Added \(profile.trimmedName).", tone: .success)
        }

        if selectedProfileID == nil || selectedProfileID == profile.id {
            selectedProfileID = profile.id
        }

        persistProfiles()
    }

    func deleteProfile(_ profile: BridgeProfile) {
        profiles.removeAll { $0.id == profile.id }
        if selectedProfileID == profile.id {
            selectedProfileID = profiles.first?.id
            preview.disconnect()
        }
        persistProfiles()

        if let nextProfile = selectedProfile {
            setActivity("Removed \(profile.trimmedName). Active bridge is now \(nextProfile.trimmedName).", tone: .idle)
        } else {
            setActivity("Removed \(profile.trimmedName). Create another bridge to continue.", tone: .idle)
        }
    }

    func connectPreview() {
        guard let profile = selectedProfile else {
            setActivity("Create or select a bridge profile first.", tone: .error)
            return
        }
        guard let streamURL = URL(string: profile.trimmedStreamURL) else {
            setActivity("The stream URL for \(profile.trimmedName) is invalid.", tone: .error)
            return
        }

        let snapshotURL = URL(string: profile.resolvedSnapshotURL)
        preview.connect(streamURL: streamURL, snapshotURL: snapshotURL)
        setActivity("Connecting to \(profile.trimmedName).", tone: .idle)

        Task {
            await syncPiState(showSuccessMessage: false)
        }
    }

    func disconnectPreview() {
        preview.disconnect()
        setActivity("Preview disconnected.", tone: .idle)
    }

    func syncPiState(showSuccessMessage: Bool = true) async {
        guard let profile = selectedProfile else {
            setActivity("Select a bridge before syncing.", tone: .error)
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        do {
            let health = try await BridgeAPI.fetchHealth(from: profile.trimmedStreamURL)
            self.health = health
            adopt(settings: health.settings)

            if let error = health.error, !error.isEmpty {
                setActivity(error, tone: .error)
            } else if showSuccessMessage {
                setActivity(
                    "Synced \(health.settings.resolutionLabel) at \(formattedFramerate(health.settings.framerate)) fps.",
                    tone: .success
                )
            }
        } catch {
            setActivity(error.localizedDescription, tone: .error)
        }
    }

    func applyPreset(_ preset: StreamPreset) {
        guard let profile = selectedProfile else {
            setActivity("Select a bridge before applying a preset.", tone: .error)
            return
        }

        Task {
            isApplyingPreset = true
            setActivity("Applying \(preset.title) profile.", tone: .idle)
            defer { isApplyingPreset = false }

            do {
                let settings = try await BridgeAPI.updateSettings(from: profile.trimmedStreamURL, payload: preset.payload)
                adopt(settings: settings)
                connectPreview()
                setActivity("Applied \(preset.title) profile.", tone: .success)
            } catch {
                setActivity(error.localizedDescription, tone: .error)
            }
        }
    }

    func applyFocus() {
        guard let profile = selectedProfile else {
            setActivity("Select a bridge before changing focus.", tone: .error)
            return
        }

        Task {
            isApplyingFocus = true
            setActivity("Applying focus changes.", tone: .idle)
            defer { isApplyingFocus = false }

            var payload: [String: Any] = [
                "autofocus_mode": focusMode.rawValue,
            ]
            if focusMode == .manual {
                payload["lens_position"] = manualLensPosition
            }

            do {
                let settings = try await BridgeAPI.updateSettings(from: profile.trimmedStreamURL, payload: payload)
                adopt(settings: settings)
                connectPreview()
                let summary = focusMode == .manual
                    ? "Manual focus applied."
                    : "\(focusMode.title) focus applied."
                setActivity(summary, tone: .success)
            } catch {
                setActivity(error.localizedDescription, tone: .error)
            }
        }
    }

    func captureSnapshot() {
        guard let profile = selectedProfile else {
            setActivity("Select a bridge before capturing a snapshot.", tone: .error)
            return
        }

        Task {
            isSavingSnapshot = true
            setActivity("Capturing snapshot from \(profile.trimmedName).", tone: .idle)
            defer { isSavingSnapshot = false }

            do {
                let data = try await BridgeAPI.downloadSnapshot(from: profile.resolvedSnapshotURL)
                let record = try snapshotStore.saveSnapshot(data: data, profile: profile)
                snapshots.insert(record, at: 0)
                snapshotStore.saveRecords(snapshots)
                setActivity("Saved snapshot for \(profile.trimmedName).", tone: .success)
            } catch {
                setActivity(error.localizedDescription, tone: .error)
            }
        }
    }

    func deleteSnapshot(_ record: SnapshotRecord) {
        snapshots.removeAll { $0.id == record.id }
        snapshotStore.deleteSnapshot(for: record)
        snapshotStore.saveRecords(snapshots)
        setActivity("Deleted snapshot from \(record.profileName).", tone: .idle)
    }

    func snapshotURL(for record: SnapshotRecord) -> URL {
        snapshotStore.fileURL(for: record)
    }

    func imageExists(for record: SnapshotRecord) -> Bool {
        FileManager.default.fileExists(atPath: snapshotURL(for: record).path)
    }

    func formattedFramerate(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }

    func formattedLastFrameAge() -> String {
        guard let age = health?.lastFrameAgeSeconds else {
            return "Waiting"
        }
        if age < 1 {
            return "\(Int(age * 1000)) ms"
        }
        return String(format: "%.1f s", age)
    }

    func formattedBytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    private func persistProfiles() {
        profileStore.saveProfiles(profiles)
        profileStore.saveSelectedProfileID(selectedProfileID)
    }

    private func adopt(settings: BridgeSettings) {
        currentSettings = settings
        selectedPreset = StreamPreset.matching(settings: settings)
        focusMode = settings.focusMode
        manualLensPosition = settings.lensPosition ?? 0.0
    }

    private func setActivity(_ message: String, tone: StatusTone) {
        activityMessage = message
        activityTone = tone
    }
}
