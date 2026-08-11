import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private struct SharePhotoTransferFile: Transferable {
    let url: URL
    let originalFileName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .data) { value in
            SentTransferredFile(value.url)
        } importing: { received in
            let originalName = received.file.lastPathComponent
            return SharePhotoTransferFile(
                url: try MediaFileSupport.temporaryCopy(
                    of: received.file,
                    suggestedName: originalName
                ),
                originalFileName: originalName
            )
        }
    }
}

private final class ShareTemporaryFileOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var fileURLs: Set<URL> = []

    func track(_ items: [QueuedUpload]) {
        let urls = items.compactMap { item -> URL? in
            guard case let .file(url, _) = item.source else { return nil }
            return url
        }
        lock.lock()
        fileURLs.formUnion(urls)
        lock.unlock()
    }

    func track(_ url: URL) {
        lock.lock()
        fileURLs.insert(url)
        lock.unlock()
    }

    deinit {
        lock.lock()
        let urls = fileURLs
        fileURLs.removeAll()
        lock.unlock()
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

@MainActor
final class ShareUploadViewModel: ObservableObject {
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
    @Published var isLoading = true
    @Published var isUploading = false
    @Published private(set) var isAddingItems = false
    @Published private(set) var isTestingConnection = false
    @Published private(set) var didLastSendFail = false
    @Published private(set) var didCompleteUpload = false
    @Published var isLoadingFolders = false
    @Published var folderMessage: String?
    @Published var operationMessage: String?
    @Published var connectionMessage: String?
    @Published var pendingUploadLibraryMismatch: EagleLibraryMismatch?
    @Published private var connectionTestStates: [UUID: ConnectionTestState] = [:]

    private weak var extensionContext: NSExtensionContext?
    private let settingsStore = SharedSettingsStore()
    private let uploadNotifier: any UploadNotifying
    private let temporaryFileOwner = ShareTemporaryFileOwner()
    private var folderLoadToken: UUID?
    private var loadedFolderProfile: EagleLibraryProfileFingerprint?
    private var tagLoadToken: UUID?
    private var loadedTagProfile: EagleLibraryProfileFingerprint?
    private var loadedTagsAt: Date?
    private var isTerminated = false
    private var itemAdditionToken: UUID?
    private var fileImportTask: Task<Void, Never>?
    private var fileImportWorkerTask: Task<MediaFileImportResult, Never>?
    private var sendConnectionFailure: (profileID: UUID, message: String)?

    init(
        extensionContext: NSExtensionContext?,
        uploadNotifier: any UploadNotifying = SystemUploadNotifier()
    ) {
        self.extensionContext = extensionContext
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
        connectionTestStates[profile.id] ?? .unverified
    }

    func load() async {
        guard !isTerminated else { return }
        didCompleteUpload = false
        let loadedQueue = await ShareMediaLoader.load(from: extensionContext)
        guard !Task.isCancelled, !isTerminated else {
            Self.cleanupFiles(for: loadedQueue)
            return
        }
        queue = loadedQueue
        temporaryFileOwner.track(loadedQueue)
        isLoading = false

        if queue.isEmpty {
            operationMessage = String(
                localized: "No supported file or URL was shared."
            )
        } else if selectedProfile?.connection.isValid != true {
            operationMessage = String(
                localized: "Configure this share extension’s connection before uploading."
            )
        }
    }

    func reloadProfiles() {
        guard !isUploading, !isAddingItems, !isTestingConnection else { return }
        let previousProfile = selectedProfile
        let snapshot = settingsStore.load()
        profiles = snapshot.profiles
        selectedProfileID = snapshot.selectedProfileID
        pendingUploadLibraryMismatch = nil
        connectionTestStates = [:]

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
        guard !isUploading,
              !isAddingItems,
              !isTestingConnection,
              profiles.contains(where: { $0.id == id }) else {
            return false
        }
        pendingUploadLibraryMismatch = nil
        guard selectedProfileID != id else { return true }
        let previousSelectedProfileID = selectedProfileID
        selectedProfileID = id
        connectionMessage = nil
        if let persistenceError = persistProfiles() {
            connectionMessage = persistenceError.localizedDescription
            selectedProfileID = previousSelectedProfileID
            return false
        }
        if let previousSelectedProfileID {
            clearSendConnectionFailure(for: previousSelectedProfileID)
        }
        operationMessage = nil
        didLastSendFail = false
        resetFolders()
        return true
    }

    func dismissOperationMessage(ifMatching currentMessage: String) {
        guard operationMessage == currentMessage else { return }
        if let failure = sendConnectionFailure,
           failure.message == currentMessage {
            clearSendConnectionFailure(for: failure.profileID)
        } else {
            operationMessage = nil
        }
    }

    @discardableResult
    func upsertProfile(
        _ profile: EagleConnectionProfile,
        verifiedConnection: EagleConnection? = nil,
        connectionWasVerified: Bool = false
    ) -> Bool {
        guard profile.connection.isValid else {
            connectionMessage = EagleClientError.invalidConnection.localizedDescription
            return false
        }
        guard !isUploading, !isAddingItems, !isTestingConnection else {
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
        if let persistenceError = persistProfiles() {
            connectionMessage = persistenceError.localizedDescription
            profiles = previousProfiles
            return false
        }
        if connectionWasVerified,
           normalizedVerifiedConnection == normalized.connection,
           normalized.libraryName != nil {
            connectionTestStates[normalized.id] = .succeeded
            clearSendConnectionFailure(for: normalized.id)
        } else if isNewProfile || connectionChanged || expectedLibraryChanged {
            connectionTestStates.removeValue(forKey: normalized.id)
        }
        if shouldResetFolders {
            resetFolders()
        }
        if shouldClearSendFailure {
            clearSendConnectionFailure(for: normalized.id)
            didLastSendFail = false
        }
        connectionMessage = nil
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
            connectionMessage = String(
                localized: "This connection was changed elsewhere. Reopen it and try again."
            )
            return false
        }
        return upsertProfile(
            profile,
            verifiedConnection: verifiedConnection,
            connectionWasVerified: connectionWasVerified
        )
    }

    func deleteProfile(_ id: UUID) {
        guard !isUploading, !isAddingItems, !isTestingConnection else {
            return
        }
        pendingUploadLibraryMismatch = nil
        let previousProfiles = profiles
        let previousSelectedProfileID = selectedProfileID
        profiles.removeAll(where: { $0.id == id })
        let didDeleteSelectedProfile = selectedProfileID == id
        if selectedProfileID == id {
            selectedProfileID = profiles.first?.id
        }
        if let persistenceError = persistProfiles() {
            connectionMessage = persistenceError.localizedDescription
            profiles = previousProfiles
            selectedProfileID = previousSelectedProfileID
            return
        }
        connectionTestStates.removeValue(forKey: id)
        if didDeleteSelectedProfile {
            clearSendConnectionFailure(for: id)
            didLastSendFail = false
            resetFolders()
        }
    }

    var hasLoadedFoldersForSelectedProfile: Bool {
        guard let profile = selectedProfile else { return false }
        return loadedFolderProfile == EagleLibraryProfileFingerprint(profile: profile)
    }

    func loadFoldersIfNeeded() async {
        guard let profile = selectedProfile else {
            await loadFolders()
            return
        }
        let fingerprint = EagleLibraryProfileFingerprint(profile: profile)
        guard loadedFolderProfile != fingerprint else { return }
        await loadFolders()
    }

    func loadFolders() async {
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
                ? String(
                    localized: "The current Eagle library has no folders."
                )
                : nil
            isLoadingFolders = false
        } catch {
            guard folderLoadToken == loadToken else { return }
            folderLoadToken = nil
            isLoadingFolders = false
            if Task.isCancelled || error is CancellationError || isTerminated {
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

    func testDraftConnection(
        _ draft: EagleConnectionProfile
    ) async -> EagleDraftConnectionTestResult? {
        guard draft.connection.isValid else {
            connectionMessage = EagleClientError.invalidConnection.localizedDescription
            return nil
        }
        guard !isUploading, !isAddingItems, !isTestingConnection else {
            return nil
        }

        isTestingConnection = true
        connectionMessage = nil
        defer { isTestingConnection = false }

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
            return
        }
        guard !Task.isCancelled else { return }
        guard !isUploading, !isAddingItems, !isTestingConnection else {
            return
        }

        let testedConnection = profile.connection
        let testedExpectedLibraryName = profile.expectedLibraryName
        let previousTestState = connectionTestState(for: profile)
        isTestingConnection = true
        connectionTestStates[id] = .testing
        connectionMessage = nil
        defer { isTestingConnection = false }
        await Task.yield()
        do {
            let status = try await EagleAPIClient(
                connection: testedConnection
            ).testConnection()
            try Task.checkCancellation()

            guard let index = profiles.firstIndex(where: { $0.id == id }),
                  profiles[index].connection == testedConnection,
                  profiles[index].expectedLibraryName == testedExpectedLibraryName else {
                if profiles.contains(where: { $0.id == id }) {
                    connectionTestStates[id] = .unverified
                } else {
                    connectionTestStates.removeValue(forKey: id)
                }
                return
            }

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
            if let persistenceError = persistProfiles() {
                profiles[index] = previousProfile
                let message = persistenceError.localizedDescription
                connectionTestStates[id] = .failed(message)
                connectionMessage = message
                if sendConnectionFailure?.profileID == id {
                    applySendConnectionFailure(message, profileID: id)
                }
                return
            }
            connectionTestStates[id] = .succeeded
            connectionMessage = nil
            clearSendConnectionFailure(for: id)
            loadedTagsAt = nil
        } catch {
            if Task.isCancelled || error is CancellationError {
                if let profile = profiles.first(where: { $0.id == id }),
                   profile.connection == testedConnection,
                   profile.expectedLibraryName == testedExpectedLibraryName {
                    connectionTestStates[id] = previousTestState
                }
                return
            }

            guard let profile = profiles.first(where: { $0.id == id }),
                  profile.connection == testedConnection,
                  profile.expectedLibraryName == testedExpectedLibraryName else {
                return
            }

            let errorMessage = error.localizedDescription
            connectionTestStates[id] = .failed(errorMessage)
            connectionMessage = errorMessage
            if sendConnectionFailure?.profileID == id {
                applySendConnectionFailure(errorMessage, profileID: id)
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
            connectionMessage = String(
                localized: "This connection was changed elsewhere. Reopen it and test again."
            )
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

    func removeQueueItem(_ id: UUID) {
        guard !isUploading,
              !isAddingItems,
              !isTestingConnection,
              let index = queue.firstIndex(where: { $0.id == id }) else {
            return
        }
        if case let .file(url, _) = queue[index].source {
            try? FileManager.default.removeItem(at: url)
        }
        queue.remove(at: index)
        didLastSendFail = false
        didCompleteUpload = false
    }

    @discardableResult
    func addBookmark(_ value: String) -> Bool {
        guard !isLoading,
              !isUploading,
              !isAddingItems,
              !isTestingConnection else {
            return false
        }
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
        didCompleteUpload = false
        operationMessage = nil
        return true
    }

    func addFiles(_ urls: [URL]) {
        guard !isTerminated,
              !isLoading,
              !isUploading,
              !isAddingItems,
              !isTestingConnection,
              !urls.isEmpty else {
            return
        }
        didLastSendFail = false
        didCompleteUpload = false
        isAddingItems = true

        let additionToken = UUID()
        itemAdditionToken = additionToken
        let worker = Task.detached(priority: .userInitiated) {
            MediaFileSupport.importFiles(urls)
        }
        fileImportWorkerTask = worker
        fileImportTask = Task { @MainActor [weak self] in
            let result = await worker.value
            guard let self else {
                Self.cleanupFiles(for: result.uploads)
                return
            }
            guard !Task.isCancelled,
                  !self.isTerminated,
                  self.itemAdditionToken == additionToken else {
                Self.cleanupFiles(for: result.uploads)
                self.finishFileImport(ifMatching: additionToken)
                return
            }

            self.temporaryFileOwner.track(result.uploads)
            self.queue.append(contentsOf: result.uploads)
            if let latestErrorMessage = result.latestErrorMessage {
                self.operationMessage = latestErrorMessage
            } else if !result.uploads.isEmpty {
                self.operationMessage = nil
            }
            self.finishFileImport(ifMatching: additionToken)
        }
    }

    func addPhotos(_ selections: [PhotosPickerItem]) async {
        guard !isTerminated,
              !isLoading,
              !isUploading,
              !isAddingItems,
              !isTestingConnection else {
            return
        }
        didLastSendFail = false
        didCompleteUpload = false
        let additionToken = UUID()
        itemAdditionToken = additionToken
        isAddingItems = true
        defer {
            if itemAdditionToken == additionToken {
                itemAdditionToken = nil
                isAddingItems = false
            }
        }

        for selection in selections {
            guard !Task.isCancelled,
                  !isTerminated,
                  itemAdditionToken == additionToken else {
                return
            }
            do {
                let contentType = selection.supportedContentTypes.first ?? .data
                let destination: URL
                let originalName: String

                if let transferred = try await selection.loadTransferable(
                    type: SharePhotoTransferFile.self
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

                guard !Task.isCancelled,
                      !isTerminated,
                      itemAdditionToken == additionToken else {
                    try? FileManager.default.removeItem(at: destination)
                    return
                }
                temporaryFileOwner.track(destination)
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
                operationMessage = nil
            } catch {
                if Task.isCancelled || error is CancellationError || isTerminated {
                    return
                }
                operationMessage = error.localizedDescription
            }
        }
    }

    func upload(
        confirming confirmedMismatch: EagleLibraryMismatch? = nil
    ) async {
        guard !isTerminated else { return }
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
        guard !isAddingItems else { return }
        guard !isTestingConnection else { return }
        guard !isUploading else { return }
        guard connectionTestState(for: profile).allowsUpload,
              profile.hasPinnedLibrary,
              let expectedLibraryName = profile.expectedLibraryName else {
            return
        }

        let previousConnectionTestState = connectionTestState(for: profile)
        connectionTestStates[profile.id] = .testing
        isUploading = true
        didLastSendFail = false
        didCompleteUpload = false
        operationMessage = nil
        sendConnectionFailure = nil
        defer {
            isUploading = false
            if isTerminated {
                Self.cleanupFiles(for: queue)
                queue.removeAll()
            }
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
                guard confirmedMismatch == mismatch else {
                    pendingUploadLibraryMismatch = mismatch
                    return
                }
                pendingUploadLibraryMismatch = nil
            } else {
                pendingUploadLibraryMismatch = nil
                connectionTestStates[profile.id] = .succeeded
            }
        } catch {
            if Task.isCancelled {
                pendingUploadLibraryMismatch = nil
                connectionTestStates[profile.id] = previousConnectionTestState
                operationMessage = nil
                return
            }
            let errorMessage = error.localizedDescription
            applySendConnectionFailure(errorMessage, profileID: profile.id)
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
        let uploadWasCancelled = Task.isCancelled
        didLastSendFail = failed > 0
        let didComplete = !uploadWasCancelled
            && failed == 0
            && succeeded > 0
            && queue.isEmpty
        loadedTagsAt = nil
        operationMessage = nil
        guard !uploadWasCancelled else { return }
        if let result = UploadNotificationResult.completed(
            sent: succeeded,
            failed: failed
        ) {
            await uploadNotifier.post(result)
        }
        guard !Task.isCancelled, !isTerminated else { return }
        didCompleteUpload = didComplete
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
        let hasFailedUpload = queue.contains {
            if case .failed = $0.state { return true }
            return false
        }
        if !hasFailedUpload {
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

    func finish() {
        guard !isTerminated else { return }
        let context = extensionContext
        terminate()
        context?.completeRequest(returningItems: nil)
    }

    func cancel() {
        guard !isTerminated else { return }
        let context = extensionContext
        terminate()
        context?.cancelRequest(
            withError: NSError(
                domain: NSCocoaErrorDomain,
                code: NSUserCancelledError
            )
        )
    }

    private func persistProfiles() -> (any Error)? {
        do {
            try settingsStore.save(
                ConnectionSettingsSnapshot(
                    profiles: profiles,
                    selectedProfileID: selectedProfileID
                )
            )
            return nil
        } catch {
            return error
        }
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

    private func removeSucceededUploadsFromQueue() {
        let succeededItems = queue.filter { $0.state == .succeeded }
        for item in succeededItems {
            if case let .file(url, _) = item.source {
                try? FileManager.default.removeItem(at: url)
            }
        }
        queue.removeAll(where: { $0.state == .succeeded })
    }

    private func finishFileImport(ifMatching token: UUID) {
        guard itemAdditionToken == token else { return }
        itemAdditionToken = nil
        fileImportTask = nil
        fileImportWorkerTask = nil
        isAddingItems = false
    }

    private func terminate() {
        guard !isTerminated else { return }
        isTerminated = true
        itemAdditionToken = nil
        fileImportWorkerTask?.cancel()
        fileImportTask?.cancel()
        fileImportWorkerTask = nil
        fileImportTask = nil
        isAddingItems = false
        if !isUploading {
            Self.cleanupFiles(for: queue)
            queue.removeAll()
        }
        operationMessage = nil
        connectionMessage = nil
        folderMessage = nil
        pendingUploadLibraryMismatch = nil
    }

    nonisolated private static func cleanupFiles(for items: [QueuedUpload]) {
        for item in items {
            if case let .file(url, _) = item.source {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
