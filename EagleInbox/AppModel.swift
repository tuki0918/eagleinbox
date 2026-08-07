import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private struct PhotoTransferFile: Transferable {
    let url: URL
    let originalFileName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .data) { value in
            SentTransferredFile(value.url)
        } importing: { received in
            let originalName = received.file.lastPathComponent
            return PhotoTransferFile(
                url: try MediaFileSupport.temporaryCopy(
                    of: received.file,
                    suggestedName: originalName
                ),
                originalFileName: originalName
            )
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var profiles: [EagleConnectionProfile]
    @Published var selectedProfileID: UUID?
    @Published var queue: [QueuedUpload] = []
    @Published var tagsText = ""
    @Published private(set) var availableTags: [EagleTag] = []
    @Published private(set) var recentTags: [EagleTag] = []
    @Published private(set) var availableTagGroups: [EagleTagGroup] = []
    @Published private(set) var isLoadingTags = false
    @Published var availableFolders: [EagleFolder] = []
    @Published var selectedFolderIDs: Set<String> = []
    @Published var annotation = ""
    @Published var isWorking = false
    @Published private(set) var isSending = false
    @Published private(set) var didLastSendFail = false
    @Published private(set) var isImportingFiles = false
    @Published var isLoadingFolders = false
    @Published var connectionMessage: String?
    @Published var folderMessage: String?
    @Published var operationMessage: String?
    @Published var pendingUploadLibraryMismatch: EagleLibraryMismatch?
    @Published private var connectionTestStates: [UUID: ConnectionTestState] = [:]

    private let settingsStore: SharedSettingsStore
    let allowsAutomaticConnectionRefresh: Bool
    private let recentFolderStore = RecentFolderStore()
    private let uploadNotifier: any UploadNotifying
    private var folderLoadToken: UUID?
    private var loadedFolderProfile: EagleLibraryProfileFingerprint?
    private var connectionTestTokens: [UUID: UUID] = [:]
    private var activeConnectionTestToken: UUID?
    private var tagLoadToken: UUID?
    private var loadedTagProfile: EagleLibraryProfileFingerprint?
    private var loadedTagsAt: Date?
#if DEBUG
    private var seededRecentFolderIDsForUITesting: [String]?
#endif

    init(
        settingsStore: SharedSettingsStore = SharedSettingsStore(),
        allowsAutomaticConnectionRefresh: Bool = true,
        uploadNotifier: any UploadNotifying = SystemUploadNotifier()
    ) {
        self.settingsStore = settingsStore
        self.allowsAutomaticConnectionRefresh = allowsAutomaticConnectionRefresh
        self.uploadNotifier = uploadNotifier
        let snapshot = settingsStore.load()
        profiles = snapshot.profiles
        selectedProfileID = snapshot.selectedProfileID
    }

    var selectedProfile: EagleConnectionProfile? {
        guard let selectedProfileID else { return profiles.first }
        return profiles.first(where: { $0.id == selectedProfileID }) ?? profiles.first
    }

    func connectionTestState(for profile: EagleConnectionProfile) -> ConnectionTestState {
        connectionTestStates[profile.id]
            ?? (profile.libraryName == nil ? .unverified : .succeeded)
    }

    var pendingUploadCount: Int {
        queue.filter { $0.state != .succeeded }.count
    }

    var failedUploadCount: Int {
        queue.filter {
            if case .failed = $0.state { return true }
            return false
        }.count
    }

    func reloadProfiles() {
        let previousProfile = selectedProfile
        let previousProfiles = Dictionary(
            uniqueKeysWithValues: profiles.map { ($0.id, $0) }
        )
        let snapshot = settingsStore.load()
        profiles = snapshot.profiles
        selectedProfileID = snapshot.selectedProfileID
        connectionMessage = nil
        pendingUploadLibraryMismatch = nil
        let currentProfiles = Dictionary(
            uniqueKeysWithValues: profiles.map { ($0.id, $0) }
        )
        let validTestIDs = Set(connectionTestTokens.keys.filter { id in
            previousProfiles[id]?.connection == currentProfiles[id]?.connection
                && previousProfiles[id]?.expectedLibraryName
                    == currentProfiles[id]?.expectedLibraryName
        })
        let invalidatedTestIDs = connectionTestTokens.keys.filter {
            !validTestIDs.contains($0)
        }
        for id in invalidatedTestIDs {
            clearConnectionTest(for: id)
        }
        connectionTestStates = connectionTestStates.filter { id, _ in
            validTestIDs.contains(id)
        }
        if previousProfile?.id != selectedProfile?.id
            || previousProfile?.connection != selectedProfile?.connection
            || previousProfile?.expectedLibraryName
                != selectedProfile?.expectedLibraryName {
            didLastSendFail = false
            resetFolders()
        }
    }

    @discardableResult
    func selectProfile(_ id: UUID) -> Bool {
        guard !isWorking,
              profiles.contains(where: { $0.id == id }) else {
            return false
        }
        pendingUploadLibraryMismatch = nil
        guard selectedProfileID != id else { return true }
        let previousSelectedProfileID = selectedProfileID
        selectedProfileID = id
        connectionMessage = nil
        guard persistProfiles() else {
            selectedProfileID = previousSelectedProfileID
            return false
        }
        didLastSendFail = false
        resetFolders()
        return true
    }

    @discardableResult
    func upsertProfile(
        _ profile: EagleConnectionProfile,
        verifiedConnection: EagleConnection? = nil,
        connectionWasVerified: Bool = false
    ) -> Bool {
        guard !isWorking else { return false }
        guard profile.connection.isValid else {
            connectionMessage = EagleClientError.invalidConnection.localizedDescription
            return false
        }
        pendingUploadLibraryMismatch = nil

        let previousProfiles = profiles
        var normalized = profile
        normalized.name = profile.displayName
        normalized.connection = profile.connection.normalizedForStorage
        let normalizedVerifiedConnection = verifiedConnection?.normalizedForStorage
        let isNewProfile = !profiles.contains(where: { $0.id == profile.id })
        var connectionChanged = false
        var expectedLibraryChanged = false
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            let existingProfile = profiles[index]
            let canReplaceExpectedLibrary = normalizedVerifiedConnection == normalized.connection
                && normalized.expectedLibraryName != nil
                && normalized.expectedLibraryName == normalized.libraryName
            if let expectedLibraryName = existingProfile.expectedLibraryName,
               !canReplaceExpectedLibrary {
                normalized.expectedLibraryName = expectedLibraryName
            }
            expectedLibraryChanged = existingProfile.expectedLibraryName
                != normalized.expectedLibraryName
            if existingProfile.connection != normalized.connection {
                connectionChanged = true
            }
        }
        if normalizedVerifiedConnection != normalized.connection {
            normalized.libraryName = nil
        }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = normalized
        } else {
            profiles.append(normalized)
        }
        let isSelected = selectedProfileID == normalized.id
        let shouldClearSendFailure = isSelected
            && (connectionChanged || expectedLibraryChanged)
        let shouldResetFolders = isSelected
            && (connectionChanged || expectedLibraryChanged)
        guard persistProfiles() else {
            profiles = previousProfiles
            return false
        }
        connectionMessage = nil
        if connectionWasVerified,
           normalizedVerifiedConnection == normalized.connection,
           normalized.libraryName != nil {
            connectionTestStates[normalized.id] = .succeeded
        } else if isNewProfile || connectionChanged || expectedLibraryChanged {
            clearConnectionTest(for: normalized.id)
        }
        if shouldResetFolders {
            resetFolders()
        }
        if shouldClearSendFailure {
            didLastSendFail = false
        }
        return true
    }

    @discardableResult
    func saveEditedProfile(
        _ profile: EagleConnectionProfile,
        baseline: EagleConnectionProfile,
        isNew: Bool,
        verifiedConnection: EagleConnection?,
        connectionWasVerified: Bool
    ) -> Bool {
        let storedProfile = settingsStore.load().profiles.first(where: {
            $0.id == baseline.id
        })
        guard isNew ? storedProfile == nil : storedProfile == baseline else {
            connectionMessage = "This connection was changed elsewhere. Reopen it and try again."
            return false
        }
        return upsertProfile(
            profile,
            verifiedConnection: verifiedConnection,
            connectionWasVerified: connectionWasVerified
        )
    }

    func deleteProfile(_ id: UUID) {
        guard !isWorking else { return }
        pendingUploadLibraryMismatch = nil
        let previousProfiles = profiles
        let previousSelectedProfileID = selectedProfileID
        profiles.removeAll(where: { $0.id == id })
        let didDeleteSelectedProfile = selectedProfileID == id
        if selectedProfileID == id {
            selectedProfileID = profiles.first?.id
        }
        guard persistProfiles() else {
            profiles = previousProfiles
            selectedProfileID = previousSelectedProfileID
            return
        }
        clearConnectionTest(for: id)
        pendingUploadLibraryMismatch = nil
        if didDeleteSelectedProfile {
            didLastSendFail = false
            resetFolders()
        }
    }

    var hasLoadedFoldersForSelectedProfile: Bool {
        guard let profile = selectedProfile else { return false }
        return loadedFolderProfile == EagleLibraryProfileFingerprint(profile: profile)
    }

    var recentFolders: [EagleFolder] {
#if DEBUG
        if let seededRecentFolderIDsForUITesting {
            let foldersByID = Dictionary(
                uniqueKeysWithValues: availableFolders.map { ($0.id, $0) }
            )
            return seededRecentFolderIDsForUITesting
                .prefix(RecentFolderHistory.limit)
                .compactMap { foldersByID[$0] }
        }
#endif
        guard let profile = selectedProfile,
              canUseRecentFolderHistory(for: profile) else {
            return []
        }
        let foldersByID = Dictionary(
            uniqueKeysWithValues: availableFolders.map { ($0.id, $0) }
        )
        return recentFolderStore.folderIDs(for: profile).compactMap {
            foldersByID[$0]
        }
    }

    func rememberRecentFolders(_ folderIDs: [String]) {
        guard let profile = selectedProfile,
              canUseRecentFolderHistory(for: profile) else {
            return
        }
        recentFolderStore.record(folderIDs, for: profile)
    }

    func loadFoldersIfNeeded() async {
#if DEBUG
        if seedFoldersForUITestingIfRequested() {
            return
        }
#endif
        guard let profile = selectedProfile else {
            await loadFolders()
            return
        }
        let fingerprint = EagleLibraryProfileFingerprint(profile: profile)
        guard loadedFolderProfile != fingerprint else { return }
        await loadFolders()
    }

    func loadFolders() async {
#if DEBUG
        if seedFoldersForUITestingIfRequested() {
            return
        }
#endif
        guard let profile = selectedProfile else {
            availableFolders = []
            folderMessage = "Add and select a connection first."
            folderLoadToken = nil
            loadedFolderProfile = nil
            isLoadingFolders = false
            return
        }
        guard !isLoadingFolders else { return }

        let fingerprint = EagleLibraryProfileFingerprint(profile: profile)
        let loadToken = UUID()
        folderLoadToken = loadToken
        isLoadingFolders = true
        folderMessage = nil

        do {
            let folders = try await EagleAPIClient(
                connection: profile.connection
            ).fetchFolders()
            guard folderLoadToken == loadToken,
                  selectedProfile.map({ EagleLibraryProfileFingerprint(profile: $0) })
                    == fingerprint else {
                return
            }
            availableFolders = folders
            if canUseRecentFolderHistory(for: profile) {
                recentFolderStore.retainAvailableFolderIDs(
                    Set(folders.map(\.id)),
                    for: profile
                )
            }
            loadedFolderProfile = fingerprint
            folderLoadToken = nil
            folderMessage = folders.isEmpty
                ? "The current Eagle library has no folders."
                : nil
            isLoadingFolders = false
        } catch {
            guard folderLoadToken == loadToken else { return }
            folderLoadToken = nil
            isLoadingFolders = false
            if Task.isCancelled || error is CancellationError {
                return
            }
            folderMessage = error.localizedDescription
        }
    }

    func loadTagsIfNeeded() async {
        await loadTags(forceRefresh: false)
    }

    func reloadTags() async {
        await loadTags(forceRefresh: true)
    }

    private func loadTags(forceRefresh: Bool) async {
#if DEBUG
        if seedTagsForUITestingIfRequested() {
            return
        }
#endif
        guard let profile = selectedProfile,
              profile.expectedLibraryName != nil else {
            availableTags = []
            recentTags = []
            availableTagGroups = []
            return
        }

        let fingerprint = EagleLibraryProfileFingerprint(profile: profile)
        if !forceRefresh,
           loadedTagProfile == fingerprint,
           let loadedTagsAt,
           Date().timeIntervalSince(loadedTagsAt) < 300 {
            return
        }
        guard !isLoadingTags else { return }

        let token = UUID()
        tagLoadToken = token
        isLoadingTags = true
        defer {
            if tagLoadToken == token {
                isLoadingTags = false
            }
        }

        do {
            let client = EagleAPIClient(connection: profile.connection)
            async let tagsTask = client.fetchTags()
            async let recentTagsTask = client.fetchRecentTags()
            async let groupsTask = client.fetchTagGroups()
            let tags = try await tagsTask
            let recentTags = (try? await recentTagsTask) ?? []
            let tagGroups = (try? await groupsTask) ?? []
            try Task.checkCancellation()
            guard tagLoadToken == token,
                  selectedProfile.map({ EagleLibraryProfileFingerprint(profile: $0) })
                    == fingerprint else {
                return
            }
            availableTags = tags
            self.recentTags = EagleTag.recent(from: recentTags)
            availableTagGroups = tagGroups
            loadedTagProfile = fingerprint
            loadedTagsAt = Date()
        } catch {
            guard tagLoadToken == token else { return }
            if Task.isCancelled || error is CancellationError {
                return
            }
            // Tag suggestions are optional. Manual tag entry remains available.
        }
    }

#if DEBUG
    @discardableResult
    private func seedFoldersForUITestingIfRequested() -> Bool {
        guard ProcessInfo.processInfo.arguments.contains(
            "--ui-testing-seeded-folders"
        ), let profile = selectedProfile else {
            return false
        }
        availableFolders = [
            EagleFolder(id: "folder-inbox", name: "Inbox", path: "Inbox", depth: 0),
            EagleFolder(
                id: "folder-reference",
                name: "Reference",
                path: "Reference",
                depth: 0
            ),
            EagleFolder(id: "folder-archive", name: "Archive", path: "Archive", depth: 0),
        ]
        selectedFolderIDs = ["folder-inbox"]
        connectionTestStates[profile.id] = .succeeded
        seededRecentFolderIDsForUITesting = [
            "folder-inbox",
            "folder-reference",
        ]
        loadedFolderProfile = EagleLibraryProfileFingerprint(profile: profile)
        folderLoadToken = nil
        isLoadingFolders = false
        folderMessage = nil
        return true
    }

    @discardableResult
    private func seedTagsForUITestingIfRequested() -> Bool {
        guard ProcessInfo.processInfo.arguments.contains(
            "--ui-testing-seeded-tags"
        ) else {
            return false
        }
        availableTags = [
            EagleTag(name: "Inbox", count: 42, groupIDs: ["work"]),
            EagleTag(name: "Reference", count: 18, groupIDs: ["work"]),
            EagleTag(name: "Design", count: 12, groupIDs: ["ideas"]),
            EagleTag(name: "Inspiration", count: 7, groupIDs: ["ideas"]),
            EagleTag(name: "Loose", count: 2),
        ]
        recentTags = [availableTags[0], availableTags[3]]
        availableTagGroups = [
            EagleTagGroup(
                id: "work",
                name: "Work",
                color: "blue",
                tags: ["Inbox", "Reference"],
                description: ""
            ),
            EagleTagGroup(
                id: "ideas",
                name: "Ideas",
                color: "purple",
                tags: ["Design", "Inspiration"],
                description: ""
            ),
        ]
        loadedTagProfile = selectedProfile.map(
            EagleLibraryProfileFingerprint.init(profile:)
        )
        loadedTagsAt = Date()
        return true
    }
#endif

    func testDraftConnection(
        _ draft: EagleConnectionProfile
    ) async -> EagleDraftConnectionTestResult? {
        guard !Task.isCancelled else { return nil }
        guard draft.connection.isValid else {
            connectionMessage = EagleClientError.invalidConnection.localizedDescription
            return nil
        }
        guard !isWorking else { return nil }

        isWorking = true
        connectionMessage = nil
        defer { isWorking = false }

        guard await ConnectionEditorTestTiming.waitBeforeStarting() else {
            return nil
        }

        do {
            let status = try await EagleAPIClient(
                connection: draft.connection
            ).testConnection()

            guard !Task.isCancelled else {
                connectionMessage = nil
                return nil
            }

            if let mismatch = status.libraryMismatch(
                expectedLibraryName: draft.expectedLibraryName
            ) {
                var proposedDraft = draft
                proposedDraft.expectedLibraryName = status.libraryName
                proposedDraft.libraryName = status.libraryName
                return .libraryUpdateProposal(
                    profile: proposedDraft,
                    mismatch: mismatch
                )
            }

            var testedDraft = draft
            if testedDraft.expectedLibraryName == nil {
                testedDraft.expectedLibraryName = status.libraryName
            }
            testedDraft.libraryName = status.libraryName
            connectionMessage = nil
            return .verified(testedDraft)
        } catch {
            if Task.isCancelled {
                connectionMessage = nil
                return nil
            }
            connectionMessage = error.localizedDescription
            return nil
        }
    }

    func testConnection(profileID: UUID? = nil) async {
        pendingUploadLibraryMismatch = nil
        let id = profileID ?? selectedProfileID ?? profiles.first?.id
        guard let id,
              let profile = profiles.first(where: { $0.id == id }) else {
            connectionMessage = "Add a connection first."
            return
        }
        guard !Task.isCancelled else { return }
        guard !isWorking else { return }

        let testedConnection = profile.connection
        let testedExpectedLibraryName = profile.expectedLibraryName
        let previousTestState = connectionTestState(for: profile)
        let testToken = UUID()
        connectionTestTokens[id] = testToken
        connectionTestStates[id] = .testing
        activeConnectionTestToken = testToken
        isWorking = true
        connectionMessage = nil
        defer {
            if activeConnectionTestToken == testToken {
                activeConnectionTestToken = nil
                isWorking = false
            }
        }
        await Task.yield()
        do {
            let status = try await EagleAPIClient(
                connection: testedConnection
            ).testConnection()
            try Task.checkCancellation()

            guard connectionTestTokens[id] == testToken,
                  let index = profiles.firstIndex(where: { $0.id == id }),
                  profiles[index].connection == testedConnection,
                  profiles[index].expectedLibraryName == testedExpectedLibraryName else {
                return
            }

            connectionTestTokens.removeValue(forKey: id)
            if let mismatch = status.libraryMismatch(
                expectedLibraryName: testedExpectedLibraryName
            ) {
                if selectedProfile?.id == id {
                    resetFolders()
                }
                connectionTestStates[id] = .warning(mismatch.warningMessage)
                connectionMessage = nil
                return
            }

            let previousProfile = profiles[index]
            let previousLibraryName = profiles[index].libraryName
            if profiles[index].expectedLibraryName == nil {
                profiles[index].expectedLibraryName = status.libraryName
            }
            profiles[index].libraryName = status.libraryName
            if let previousLibraryName,
               previousLibraryName != status.libraryName,
               selectedProfile?.id == id {
                resetFolders()
            }
            connectionMessage = nil
            guard persistProfiles() else {
                profiles[index] = previousProfile
                connectionTestStates[id] = .failed(
                    connectionMessage ?? "The connection result could not be saved."
                )
                return
            }
            connectionTestStates[id] = .succeeded
            loadedTagsAt = nil
        } catch {
            if Task.isCancelled || error is CancellationError {
                if connectionTestTokens[id] == testToken {
                    connectionTestTokens.removeValue(forKey: id)
                    connectionTestStates[id] = previousTestState
                }
                connectionMessage = nil
                return
            }

            guard connectionTestTokens[id] == testToken,
                  let profile = profiles.first(where: { $0.id == id }),
                  profile.connection == testedConnection,
                  profile.expectedLibraryName == testedExpectedLibraryName else {
                return
            }

            connectionTestTokens.removeValue(forKey: id)
            let message = error.localizedDescription
            connectionTestStates[id] = .failed(message)
            connectionMessage = message
        }
    }

    @discardableResult
    func acceptEditedConnectionLibraryUpdate(
        _ proposal: EagleConnectionLibraryUpdateProposal,
        baseline: EagleConnectionProfile
    ) -> Bool {
        reloadProfiles()
        guard proposal.profile.id == baseline.id,
              let storedProfile = profiles.first(where: { $0.id == baseline.id }),
              storedProfile == baseline,
              proposal.profile.expectedLibraryName
                == proposal.mismatch.actualLibraryName,
              proposal.profile.libraryName == proposal.mismatch.actualLibraryName else {
            let message = "This connection was changed elsewhere. Reopen it and test again."
            connectionMessage = message
            return false
        }

        let didSave = upsertProfile(
            proposal.profile,
            verifiedConnection: proposal.profile.connection,
            connectionWasVerified: true
        )
        if didSave {
            reloadProfiles()
            connectionMessage = nil
        }
        return didSave
    }

    @discardableResult
    func addBookmark(_ value: String) -> Bool {
        guard !isWorking else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            operationMessage = EagleClientError.invalidBookmarkURL.localizedDescription
            return false
        }
        let identity = MediaFileSupport.bookmarkIdentity(for: url)
        guard !queue.contains(where: {
            guard case let .bookmark(queuedURL) = $0.source else { return false }
            return MediaFileSupport.bookmarkIdentity(for: queuedURL) == identity
        }) else {
            operationMessage = "This bookmark is already in the queue."
            return false
        }
        queue.append(
            QueuedUpload(
                name: MediaFileSupport.itemName(forBookmarkURL: url),
                source: .bookmark(url)
            )
        )
        didLastSendFail = false
        operationMessage = nil
        return true
    }

    func addFiles(_ urls: [URL]) {
        guard !isWorking, !urls.isEmpty else { return }
        didLastSendFail = false
        isWorking = true
        isImportingFiles = true

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                MediaFileSupport.importFiles(urls)
            }.value

            queue.append(contentsOf: result.uploads)
            if let latestErrorMessage = result.latestErrorMessage {
                operationMessage = latestErrorMessage
            } else if !result.uploads.isEmpty {
                operationMessage = nil
            }
            isImportingFiles = false
            isWorking = false
        }
    }

    func dismissOperationMessage(ifMatching message: String) {
        guard operationMessage == message else { return }
        operationMessage = nil
    }

    func addPhotos(_ selections: [PhotosPickerItem]) async {
        guard !isWorking else { return }
        didLastSendFail = false
        isWorking = true
        isImportingFiles = true
        defer {
            isImportingFiles = false
            isWorking = false
        }

        for selection in selections {
            do {
                let contentType = selection.supportedContentTypes.first ?? .data
                let destination: URL
                let originalName: String

                if let transferred = try await selection.loadTransferable(
                    type: PhotoTransferFile.self
                ) {
                    destination = transferred.url
                    originalName = transferred.originalFileName
                } else if let data = try await selection.loadTransferable(type: Data.self) {
                    let fileExtension = contentType.preferredFilenameExtension ?? "bin"
                    originalName = "Photo-\(UUID().uuidString.prefix(8)).\(fileExtension)"
                    destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent(originalName)
                    try data.write(to: destination, options: .atomic)
                } else {
                    continue
                }

                queue.append(
                    QueuedUpload(
                        name: MediaFileSupport.itemName(forFileName: originalName),
                        source: .file(
                            url: destination,
                            mimeType: contentType.preferredMIMEType
                                ?? MediaFileSupport.mimeType(for: destination)
                        )
                    )
                )
            } catch {
                operationMessage = error.localizedDescription
            }
        }
    }

    func remove(_ id: UUID) {
        guard !isWorking,
              let index = queue.firstIndex(where: { $0.id == id }) else {
            return
        }
        cleanupFiles(for: [queue[index]])
        queue.remove(at: index)
        didLastSendFail = false
    }

    func uploadAll(
        confirming confirmedMismatch: EagleLibraryMismatch? = nil
    ) async {
        pendingUploadLibraryMismatch = nil
        guard let profile = selectedProfile else {
            didLastSendFail = true
            operationMessage = "Add and select a connection before uploading."
            return
        }
        guard profile.connection.isValid else {
            didLastSendFail = true
            operationMessage = EagleClientError.invalidConnection.localizedDescription
            return
        }
        guard !isWorking else { return }
        guard let expectedLibraryName = profile.expectedLibraryName else {
            didLastSendFail = true
            let message = EagleClientError.libraryNotPinned.localizedDescription
            connectionTestStates[profile.id] = .unverified
            connectionMessage = message
            operationMessage = message
            pendingUploadLibraryMismatch = nil
            return
        }

        let previousConnectionTestState = connectionTestState(for: profile)
        connectionTestStates[profile.id] = .testing
        isWorking = true
        isSending = true
        didLastSendFail = false
        operationMessage = nil
        defer {
            isSending = false
            isWorking = false
        }
        guard !Task.isCancelled else {
            connectionTestStates[profile.id] = previousConnectionTestState
            return
        }

        let testedConnection = profile.connection
        let client = EagleAPIClient(connection: testedConnection)
        do {
            let status = try await client.testConnection()
            guard selectedProfile?.id == profile.id,
                  let currentProfile = profiles.first(where: { $0.id == profile.id }),
                  currentProfile.connection == testedConnection,
                  currentProfile.expectedLibraryName == expectedLibraryName else {
                throw EagleClientError.connectionChangedDuringVerification
            }

            if let mismatch = status.libraryMismatch(
                expectedLibraryName: expectedLibraryName
            ) {
                resetFolders()
                connectionTestStates[profile.id] = .warning(mismatch.warningMessage)
                connectionMessage = nil
                guard confirmedMismatch == mismatch else {
                    pendingUploadLibraryMismatch = mismatch
                    return
                }
                pendingUploadLibraryMismatch = nil
            } else {
                pendingUploadLibraryMismatch = nil
                connectionTestStates[profile.id] = .succeeded
                connectionMessage = nil
            }
        } catch {
            if Task.isCancelled {
                pendingUploadLibraryMismatch = nil
                connectionTestStates[profile.id] = previousConnectionTestState
                operationMessage = nil
                return
            }
            didLastSendFail = true
            let message = error.localizedDescription
            pendingUploadLibraryMismatch = nil
            connectionTestStates[profile.id] = .failed(message)
            connectionMessage = message
            operationMessage = message
            return
        }

        await uploadNotifier.prepareAuthorization()
        guard !Task.isCancelled else { return }

        var succeeded = 0
        var failed = 0

        for index in queue.indices where queue[index].state != .succeeded {
            guard !Task.isCancelled else {
                break
            }
            queue[index].state = .uploading
            let item = queue[index]
            let metadata = EagleUploadMetadata(
                name: item.name,
                website: nil,
                tags: MediaFileSupport.list(from: tagsText),
                folders: selectedFolderIDs.sorted(),
                annotation: annotation.trimmingCharacters(in: .whitespacesAndNewlines)
            )

            do {
                _ = try await client.upload(source: item.source, metadata: metadata)
                queue[index].state = .succeeded
                succeeded += 1
            } catch {
                if Task.isCancelled {
                    queue[index].state = .canceled(
                        UploadCancellation.uncertainDeliveryMessage
                    )
                    break
                }
                queue[index].state = .failed(error.localizedDescription)
                failed += 1
            }
        }

        removeSucceededUploadsFromQueue()
        didLastSendFail = failed > 0
        loadedTagsAt = nil
        operationMessage = nil
        guard !Task.isCancelled else { return }
        isSending = false
        if let result = UploadNotificationResult.completed(
            sent: succeeded,
            failed: failed
        ) {
            await uploadNotifier.post(result)
        }
    }

    @discardableResult
    private func persistProfiles() -> Bool {
        do {
            try settingsStore.save(
                ConnectionSettingsSnapshot(
                    profiles: profiles,
                    selectedProfileID: selectedProfileID
                )
            )
            return true
        } catch {
            connectionMessage = error.localizedDescription
            return false
        }
    }

    private func cleanupFiles(for items: [QueuedUpload]) {
        for item in items {
            if case let .file(url, _) = item.source {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func removeSucceededUploadsFromQueue() {
        let succeededItems = queue.filter { $0.state == .succeeded }
        cleanupFiles(for: succeededItems)
        queue.removeAll(where: { $0.state == .succeeded })
    }

    private func resetFolders() {
        folderLoadToken = nil
        loadedFolderProfile = nil
        isLoadingFolders = false
        availableFolders = []
        selectedFolderIDs = []
        folderMessage = nil
#if DEBUG
        seededRecentFolderIDsForUITesting = nil
#endif
        tagLoadToken = nil
        loadedTagProfile = nil
        loadedTagsAt = nil
        isLoadingTags = false
        availableTags = []
        recentTags = []
        availableTagGroups = []
    }

    private func canUseRecentFolderHistory(
        for profile: EagleConnectionProfile
    ) -> Bool {
        guard let expectedLibraryName = profile.expectedLibraryName,
              !expectedLibraryName.isEmpty,
              profile.libraryName == expectedLibraryName,
              connectionTestStates[profile.id] == .succeeded else {
            return false
        }
        return true
    }

    private func clearConnectionTest(for id: UUID) {
        connectionTestStates.removeValue(forKey: id)
        guard let token = connectionTestTokens.removeValue(forKey: id),
              activeConnectionTestToken == token else {
            return
        }
        activeConnectionTestToken = nil
        isWorking = false
    }
}
