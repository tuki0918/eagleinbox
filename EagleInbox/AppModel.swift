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
    @Published private(set) var recentFolders: [EagleFolder] = []
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
    private let entitlementStore: ProEntitlementStore
    let allowsAutomaticConnectionRefresh: Bool
    private let uploadNotifier: any UploadNotifying
    private var folderLoadToken: UUID?
    private var loadedFolderProfile: EagleLibraryProfileFingerprint?
    private var connectionTestTokens: [UUID: UUID] = [:]
    private var activeConnectionTestToken: UUID?
    private var tagLoadToken: UUID?
    private var loadedTagProfile: EagleLibraryProfileFingerprint?
    private var loadedTagsAt: Date?
    private var sendConnectionFailure: (profileID: UUID, message: String)?
    init(
        settingsStore: SharedSettingsStore = SharedSettingsStore(),
        entitlementStore: ProEntitlementStore = ProEntitlementStore(),
        allowsAutomaticConnectionRefresh: Bool = true,
        uploadNotifier: any UploadNotifying = SystemUploadNotifier()
    ) {
        self.settingsStore = settingsStore
        self.entitlementStore = entitlementStore
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

    var hasProAccess: Bool {
        entitlementStore.hasProAccess
    }

    var canAddConnection: Bool {
        ProAccessPolicy.canAddConnection(
            profileCount: profiles.count,
            hasProAccess: hasProAccess
        )
    }

    func canSelectProfile(_ id: UUID) -> Bool {
        ProAccessPolicy.canSelectConnection(
            id,
            profiles: profiles,
            selectedProfileID: selectedProfileID,
            hasProAccess: hasProAccess
        )
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

#if DEBUG
    func seedPinnedUnverifiedConnectionForUITesting(
        expectedLibraryName: String
    ) {
        guard let profile = selectedProfile,
              let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            return
        }
        profiles[index].expectedLibraryName = expectedLibraryName
        profiles[index].libraryName = nil
        connectionTestStates[profile.id] = .unverified
    }

    func seedConnectionFailureForUITesting(_ message: String) {
        guard let profile = selectedProfile else { return }
        applySendConnectionFailure(message, profileID: profile.id)
    }

    func seedRecoveredSendConnectionForUITesting(
        _ message: String,
        expectedLibraryName: String
    ) {
        guard let profile = selectedProfile,
              let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            return
        }
        profiles[index].expectedLibraryName = expectedLibraryName
        profiles[index].libraryName = expectedLibraryName
        applySendConnectionFailure(message, profileID: profile.id)
        connectionTestStates[profile.id] = .succeeded
        connectionMessage = nil
        clearSendConnectionFailure(for: profile.id)
    }

    func seedLibraryMismatchForUITesting(
        expectedLibraryName: String,
        actualLibraryName: String
    ) {
        guard let profile = selectedProfile,
              let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            return
        }
        profiles[index].expectedLibraryName = expectedLibraryName
        profiles[index].libraryName = expectedLibraryName
        let mismatch = EagleLibraryMismatch(
            expectedLibraryName: expectedLibraryName,
            actualLibraryName: actualLibraryName
        )
        connectionTestStates[profile.id] = .warning(mismatch.warningMessage)
    }

    func seedUploadLibraryMismatchConfirmationForUITesting(
        expectedLibraryName: String,
        actualLibraryName: String
    ) {
        guard let profile = selectedProfile,
              let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            return
        }
        profiles[index].expectedLibraryName = expectedLibraryName
        profiles[index].libraryName = expectedLibraryName
        let mismatch = EagleLibraryMismatch(
            expectedLibraryName: expectedLibraryName,
            actualLibraryName: actualLibraryName
        )
        connectionTestStates[profile.id] = .warning(mismatch.warningMessage)
        pendingUploadLibraryMismatch = mismatch
    }
#endif

    func reloadProfiles() {
        applySettingsSnapshot(settingsStore.load())
    }

    private func applySettingsSnapshot(
        _ snapshot: ConnectionSettingsSnapshot
    ) {
        let previousProfile = selectedProfile
        let previousProfiles = Dictionary(
            uniqueKeysWithValues: profiles.map { ($0.id, $0) }
        )
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
            if let previousProfile {
                clearSendConnectionFailure(for: previousProfile.id)
            }
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
        guard canSelectProfile(id) else {
            connectionMessage = ProFeatureAccessError
                .additionalConnectionsRequirePro
                .localizedDescription
            return false
        }
        pendingUploadLibraryMismatch = nil
        do {
            let snapshot = try settingsStore.selectProfile(
                id,
                allowsChangingSelection: hasProAccess
            )
            applySettingsSnapshot(snapshot)
            connectionMessage = nil
            return true
        } catch {
            handleSettingsMutationFailure(error)
            return false
        }
    }

    @discardableResult
    func upsertProfile(
        _ profile: EagleConnectionProfile,
        verifiedConnection: EagleConnection? = nil,
        connectionWasVerified: Bool = false
    ) -> Bool {
        let baseline = profiles.first(where: { $0.id == profile.id })
        return persistProfile(
            profile,
            baseline: baseline,
            isNew: baseline == nil,
            verifiedConnection: verifiedConnection,
            connectionWasVerified: connectionWasVerified
        )
    }

    private func persistProfile(
        _ profile: EagleConnectionProfile,
        baseline: EagleConnectionProfile?,
        isNew: Bool,
        verifiedConnection: EagleConnection?,
        connectionWasVerified: Bool
    ) -> Bool {
        guard !isWorking else { return false }
        guard profile.connection.isValid else {
            connectionMessage = EagleClientError.invalidConnection.localizedDescription
            return false
        }
        pendingUploadLibraryMismatch = nil

        var normalized = profile
        normalized.name = profile.displayName
        normalized.connection = profile.connection.normalizedForStorage
        let normalizedVerifiedConnection = verifiedConnection?.normalizedForStorage
        var connectionChanged = false
        var expectedLibraryChanged = false
        if !isNew, let baseline {
            let canReplaceExpectedLibrary = normalizedVerifiedConnection == normalized.connection
                && normalized.expectedLibraryName != nil
                && normalized.expectedLibraryName == normalized.libraryName
            if let expectedLibraryName = baseline.expectedLibraryName,
               !canReplaceExpectedLibrary {
                normalized.expectedLibraryName = expectedLibraryName
            }
            expectedLibraryChanged = baseline.expectedLibraryName
                != normalized.expectedLibraryName
            connectionChanged = baseline.connection != normalized.connection
        }
        if normalizedVerifiedConnection != normalized.connection {
            normalized.libraryName = nil
        }

        let snapshot: ConnectionSettingsSnapshot
        do {
            if isNew {
                snapshot = try settingsStore.insertProfile(
                    normalized,
                    maximumProfileCount: hasProAccess
                        ? nil
                        : ProAccessPolicy.freeConnectionLimit
                )
            } else if let baseline {
                snapshot = try settingsStore.replaceProfile(
                    normalized,
                    baseline: baseline
                )
            } else {
                throw SharedSettingsMutationError.changedOrRemoved
            }
        } catch {
            handleSettingsMutationFailure(error)
            return false
        }

        applySettingsSnapshot(snapshot)
        let isSelected = selectedProfileID == normalized.id
        let shouldClearSendFailure = isSelected
            && (connectionChanged || expectedLibraryChanged)
        let shouldResetFolders = shouldClearSendFailure
        connectionMessage = nil
        if connectionWasVerified,
           normalizedVerifiedConnection == normalized.connection,
           normalized.libraryName != nil {
            connectionTestStates[normalized.id] = .succeeded
            clearSendConnectionFailure(for: normalized.id)
        } else if isNew || connectionChanged || expectedLibraryChanged {
            clearConnectionTest(for: normalized.id)
        }
        if shouldResetFolders {
            resetFolders()
        }
        if shouldClearSendFailure {
            clearSendConnectionFailure(for: normalized.id)
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
        persistProfile(
            profile,
            baseline: isNew ? nil : baseline,
            isNew: isNew,
            verifiedConnection: verifiedConnection,
            connectionWasVerified: connectionWasVerified
        )
    }

    func deleteProfile(_ id: UUID) {
        guard !isWorking else { return }
        pendingUploadLibraryMismatch = nil
        do {
            let snapshot = try settingsStore.deleteProfile(id)
            applySettingsSnapshot(snapshot)
        } catch {
            handleSettingsMutationFailure(error)
            return
        }
        clearConnectionTest(for: id)
        pendingUploadLibraryMismatch = nil
        clearSendConnectionFailure(for: id)
    }

    var hasLoadedFoldersForSelectedProfile: Bool {
        guard let profile = selectedProfile else { return false }
        return loadedFolderProfile == EagleLibraryProfileFingerprint(profile: profile)
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
            recentFolders = []
            folderMessage = String(
                localized: "Add and select a connection first."
            )
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
            let client = EagleAPIClient(connection: profile.connection)
            async let foldersTask = client.fetchFolders()
            async let recentFoldersTask = client.fetchRecentFolders()
            let folders = try await foldersTask
            let fetchedRecentFolders = (try? await recentFoldersTask) ?? []
            try Task.checkCancellation()
            guard folderLoadToken == loadToken,
                  selectedProfile.map({ EagleLibraryProfileFingerprint(profile: $0) })
                    == fingerprint else {
                return
            }
            availableFolders = folders
            recentFolders = EagleFolder.recent(
                from: fetchedRecentFolders,
                matching: folders
            )
            loadedFolderProfile = fingerprint
            folderLoadToken = nil
            folderMessage = folders.isEmpty
                ? String(localized: "The current Eagle library has no folders.")
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
            EagleFolder(
                id: "folder-inbox",
                name: "Inbox",
                path: "Inbox",
                depth: 0,
                imageCount: 42
            ),
            EagleFolder(
                id: "folder-reference",
                name: "Reference",
                path: "Reference",
                depth: 0,
                imageCount: 18
            ),
            EagleFolder(
                id: "folder-archive",
                name: "Archive",
                path: "Archive",
                depth: 0,
                imageCount: 7
            ),
        ]
        selectedFolderIDs = ["folder-inbox"]
        connectionTestStates[profile.id] = .succeeded
        recentFolders = [availableFolders[0], availableFolders[1]]
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
            connectionMessage = String(localized: "Add a connection first.")
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
                clearSendConnectionFailure(for: id)
                return
            }

            let previousLibraryName = profiles[index].libraryName
            let updatedSnapshot: ConnectionSettingsSnapshot
            do {
                updatedSnapshot = try settingsStore
                    .recordSuccessfulConnectionTest(
                        profileID: id,
                        testedConnection: testedConnection,
                        testedExpectedLibraryName: testedExpectedLibraryName,
                        detectedLibraryName: status.libraryName
                    )
            } catch {
                let message: String
                if error is SharedSettingsMutationError {
                    message = String(
                        localized: "This connection was changed elsewhere. Reopen it and test again."
                    )
                } else {
                    message = error.localizedDescription
                }
                applySettingsSnapshot(settingsStore.load())
                if profiles.contains(where: { $0.id == id }) {
                    connectionTestStates[id] = .failed(message)
                    connectionMessage = message
                    if sendConnectionFailure?.profileID == id {
                        applySendConnectionFailure(message, profileID: id)
                    }
                }
                return
            }
            applySettingsSnapshot(updatedSnapshot)
            if let previousLibraryName,
               previousLibraryName != status.libraryName,
               selectedProfile?.id == id {
                resetFolders()
            }
            connectionMessage = nil
            connectionTestStates[id] = .succeeded
            clearSendConnectionFailure(for: id)
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
            if sendConnectionFailure?.profileID == id {
                applySendConnectionFailure(message, profileID: id)
            }
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
            let message = String(
                localized: "This connection was changed elsewhere. Reopen it and test again."
            )
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
            operationMessage = String(
                localized: "This bookmark is already in the queue."
            )
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
        if let failure = sendConnectionFailure,
           failure.message == message {
            clearSendConnectionFailure(for: failure.profileID)
        } else {
            operationMessage = nil
        }
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
                    let localizedPhotoName = String(localized: "Photo")
                    originalName = "\(localizedPhotoName)-\(UUID().uuidString.prefix(8)).\(fileExtension)"
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
            operationMessage = String(
                localized: "Add and select a connection before uploading."
            )
            return
        }
        guard profile.connection.isValid else {
            didLastSendFail = true
            operationMessage = EagleClientError.invalidConnection.localizedDescription
            return
        }
        guard !isWorking else { return }
        guard connectionTestState(for: profile).allowsUpload,
              profile.hasPinnedLibrary,
              let expectedLibraryName = profile.expectedLibraryName else {
            return
        }

        let previousConnectionTestState = connectionTestState(for: profile)
        connectionTestStates[profile.id] = .testing
        isWorking = true
        isSending = true
        didLastSendFail = false
        operationMessage = nil
        sendConnectionFailure = nil
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
            let message = error.localizedDescription
            applySendConnectionFailure(message, profileID: profile.id)
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
            queue[index].uploadProgress = nil
            let item = queue[index]
            let metadata = EagleUploadMetadata(
                name: item.name,
                website: nil,
                tags: MediaFileSupport.list(from: tagsText),
                folders: selectedFolderIDs.sorted(),
                annotation: annotation.trimmingCharacters(in: .whitespacesAndNewlines)
            )

            do {
                _ = try await client.upload(
                    source: item.source,
                    metadata: metadata
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.updateUploadProgress(progress, for: item.id)
                    }
                }
                queue[index].state = .succeeded
                queue[index].uploadProgress = nil
                succeeded += 1
            } catch {
                queue[index].uploadProgress = nil
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

    private func applySendConnectionFailure(
        _ message: String,
        profileID: UUID
    ) {
        didLastSendFail = true
        sendConnectionFailure = (profileID, message)
        pendingUploadLibraryMismatch = nil
        connectionTestStates[profileID] = .failed(message)
        connectionMessage = message
        operationMessage = message
    }

    private func clearSendConnectionFailure(for profileID: UUID) {
        guard let failure = sendConnectionFailure,
              failure.profileID == profileID else {
            return
        }
        sendConnectionFailure = nil
        if operationMessage == failure.message {
            operationMessage = nil
        }
        if failedUploadCount == 0 {
            didLastSendFail = false
        }
    }

    private func updateUploadProgress(
        _ progress: UploadProgressSnapshot,
        for itemID: UUID
    ) {
        guard let index = queue.firstIndex(where: { $0.id == itemID }),
              queue[index].state == .uploading,
              progress.sentByteCount
                >= (queue[index].uploadProgress?.sentByteCount ?? 0) else {
            return
        }
        queue[index].uploadProgress = progress
    }

    private func handleSettingsMutationFailure(_ error: Error) {
        applySettingsSnapshot(settingsStore.load())
        switch error as? SharedSettingsMutationError {
        case .profileLimitReached, .selectionNotAllowed:
            connectionMessage = ProFeatureAccessError
                .additionalConnectionsRequirePro
                .localizedDescription
        case .alreadyExists, .changedOrRemoved:
            connectionMessage = String(
                localized: "This connection was changed elsewhere. Reopen it and try again."
            )
        case nil:
            connectionMessage = error.localizedDescription
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
        recentFolders = []
        selectedFolderIDs = []
        folderMessage = nil
        tagLoadToken = nil
        loadedTagProfile = nil
        loadedTagsAt = nil
        isLoadingTags = false
        availableTags = []
        recentTags = []
        availableTagGroups = []
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
