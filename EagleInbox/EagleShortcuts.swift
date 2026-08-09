import AppIntents
import Foundation
import UniformTypeIdentifiers

struct SendFilesToEagleIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Files to Eagle"
    static let description = IntentDescription(
        "Sends photos, videos, audio, and PDFs to the selected Eagle connection."
    )
    static let openAppWhenRun = false

    @Parameter(
        title: "Files",
        description: "The photos, videos, audio, or PDFs to send.",
        supportedTypeIdentifiers: [
            "public.image",
            "public.movie",
            "public.audio",
            "com.adobe.pdf"
        ],
        requestValueDialog: "Which files do you want to send?",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var files: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$files) to Eagle")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard !files.isEmpty else {
            throw EagleShortcutError.noInput
        }
        guard files.count <= EagleShortcutUploader.maximumFileCount else {
            throw EagleShortcutError.tooManyFiles(
                maximum: EagleShortcutUploader.maximumFileCount
            )
        }

        let uploader = try await EagleShortcutUploader.verified()
        var batch = EagleShortcutBatchResult()

        for file in files {
            try Task.checkCancellation()
            let displayName = EagleShortcutFile.displayName(for: file)
            do {
                let materializedFile = try EagleShortcutFile(file)
                defer { materializedFile.removeTemporaryCopy() }
                try await uploader.upload(materializedFile.uploadItem)
                batch.recordSuccess()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                batch.recordFailure(
                    itemName: displayName,
                    error: error
                )
            }
        }

        try batch.throwIfNeeded()
        let itemLabel = batch.sent == 1 ? "item" : "items"
        return .result(
            dialog: IntentDialog(
                "Sent \(batch.sent) \(itemLabel) to \(uploader.destinationName)."
            )
        )
    }
}

struct SendURLsToEagleIntent: AppIntent {
    static let title: LocalizedStringResource = "Send URLs to Eagle"
    static let description = IntentDescription(
        "Saves web URLs as bookmarks in the selected Eagle connection."
    )
    static let openAppWhenRun = false

    @Parameter(
        title: "URLs",
        description: "The web URLs to save as Eagle bookmarks.",
        requestValueDialog: "Which URLs do you want to send?",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var urls: [URL]

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$urls) to Eagle")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard !urls.isEmpty else {
            throw EagleShortcutError.noValidWebURL
        }
        guard urls.count <= EagleShortcutUploader.maximumURLCount else {
            throw EagleShortcutError.tooManyURLs(
                maximum: EagleShortcutUploader.maximumURLCount
            )
        }

        var identities: Set<String> = []
        var validURLs: [URL] = []
        var batch = EagleShortcutBatchResult()
        for url in urls {
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host?.isEmpty == false else {
                batch.recordFailure(
                    itemName: url.absoluteString,
                    error: EagleClientError.invalidBookmarkURL
                )
                continue
            }
            let identity = MediaFileSupport.bookmarkIdentity(for: url)
            if identities.insert(identity).inserted {
                validURLs.append(url)
            }
        }
        guard !validURLs.isEmpty else {
            throw EagleShortcutError.noValidWebURL
        }

        let uploader = try await EagleShortcutUploader.verified()

        for url in validURLs {
            try Task.checkCancellation()
            let item = EagleShortcutUploadItem(
                name: MediaFileSupport.itemName(forBookmarkURL: url),
                source: .bookmark(url)
            )
            do {
                try await uploader.upload(item)
                batch.recordSuccess()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                batch.recordFailure(
                    itemName: url.absoluteString,
                    error: error
                )
            }
        }

        try batch.throwIfNeeded()
        let itemLabel = batch.sent == 1 ? "URL" : "URLs"
        return .result(
            dialog: IntentDialog(
                "Sent \(batch.sent) \(itemLabel) to \(uploader.destinationName)."
            )
        )
    }
}

struct EagleInboxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendFilesToEagleIntent(),
            phrases: [
                "Send files with \(.applicationName)",
                "Send media with \(.applicationName)"
            ],
            shortTitle: "Send Files",
            systemImageName: "square.and.arrow.up"
        )
        AppShortcut(
            intent: SendURLsToEagleIntent(),
            phrases: [
                "Send URLs with \(.applicationName)",
                "Save links with \(.applicationName)"
            ],
            shortTitle: "Send URLs",
            systemImageName: "link"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .blue
}

private struct EagleShortcutUploadItem {
    let name: String
    let source: EagleUploadSource
}

private struct EagleShortcutUploader {
    static let maximumFileCount = 50
    static let maximumURLCount = 20

    let client: EagleAPIClient
    let destinationName: String

    static func verified(
        settingsStore: SharedSettingsStore = SharedSettingsStore()
    ) async throws -> EagleShortcutUploader {
        let snapshot = settingsStore.load()
        let profile = snapshot.selectedProfileID.flatMap { selectedID in
            snapshot.profiles.first(where: { $0.id == selectedID })
        } ?? snapshot.profiles.first

        guard let profile else {
            throw EagleShortcutError.noConnection
        }
        guard profile.connection.isValid else {
            throw EagleClientError.invalidConnection
        }
        guard let expectedLibraryName = profile.expectedLibraryName,
              !expectedLibraryName.isEmpty else {
            throw EagleClientError.libraryNotPinned
        }

        let client = EagleAPIClient(connection: profile.connection)
        let status = try await client.testConnection()
        if let mismatch = status.libraryMismatch(
            expectedLibraryName: expectedLibraryName
        ) {
            throw EagleShortcutError.libraryMismatch(mismatch)
        }

        return EagleShortcutUploader(
            client: client,
            destinationName: status.libraryName
        )
    }

    func upload(_ item: EagleShortcutUploadItem) async throws {
        _ = try await client.upload(
            source: item.source,
            metadata: EagleUploadMetadata(
                name: item.name,
                website: nil,
                tags: [],
                folders: [],
                annotation: nil
            )
        )
    }
}

private final class EagleShortcutFile {
    let uploadItem: EagleShortcutUploadItem
    private let temporaryURL: URL

    init(_ file: IntentFile) throws {
        let resolvedFileName = Self.resolvedFileName(for: file)
        let copiedURL: URL

        if let sourceURL = file.fileURL {
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }
            copiedURL = try MediaFileSupport.temporaryCopy(
                of: sourceURL,
                suggestedName: resolvedFileName
            )
        } else {
            let sanitizedName = resolvedFileName.replacingOccurrences(
                of: "/",
                with: "-"
            )
            copiedURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "eagle-shortcut-\(UUID().uuidString)-\(sanitizedName)"
                )
            try file.data.write(to: copiedURL, options: .atomic)
        }

        do {
            let values = try copiedURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  MediaFileSupport.isSupportedFile(copiedURL) else {
                throw EagleShortcutError.unsupportedFile(resolvedFileName)
            }

            temporaryURL = copiedURL
            uploadItem = EagleShortcutUploadItem(
                name: MediaFileSupport.itemName(forFileName: resolvedFileName),
                source: .file(
                    url: copiedURL,
                    mimeType: file.type?.preferredMIMEType
                        ?? MediaFileSupport.mimeType(
                            for: copiedURL,
                            fallbackTypeIdentifier: file.type?.identifier
                        )
                )
            )
        } catch {
            try? FileManager.default.removeItem(at: copiedURL)
            throw error
        }
    }

    func removeTemporaryCopy() {
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    static func displayName(for file: IntentFile) -> String {
        let name = resolvedFileName(for: file)
        return name.isEmpty ? "Attachment" : name
    }

    private static func resolvedFileName(for file: IntentFile) -> String {
        MediaFileSupport.resolvedSharedFileName(
            suggestedName: file.filename,
            representationFileName: file.fileURL?.lastPathComponent ?? "",
            preferredFilenameExtension: file.type?.preferredFilenameExtension
        )
    }
}

private struct EagleShortcutBatchResult {
    private(set) var sent = 0
    private(set) var failed = 0
    private var firstFailure: String?

    mutating func recordSuccess() {
        sent += 1
    }

    mutating func recordFailure(itemName: String, error: Error) {
        failed += 1
        if firstFailure == nil {
            firstFailure = "\(itemName): \(error.localizedDescription)"
        }
    }

    func throwIfNeeded() throws {
        guard failed > 0 else { return }
        throw EagleShortcutError.batchFailed(
            sent: sent,
            failed: failed,
            firstFailure: firstFailure ?? "The item could not be sent."
        )
    }
}

private enum EagleShortcutError: LocalizedError {
    case noInput
    case noValidWebURL
    case noConnection
    case tooManyFiles(maximum: Int)
    case tooManyURLs(maximum: Int)
    case unsupportedFile(String)
    case libraryMismatch(EagleLibraryMismatch)
    case batchFailed(sent: Int, failed: Int, firstFailure: String)

    var errorDescription: String? {
        switch self {
        case .noInput:
            return "Choose at least one file to send."
        case .noValidWebURL:
            return "Provide at least one valid HTTP or HTTPS URL."
        case .noConnection:
            return "Open Eagle Inbox and add or select a connection first."
        case let .tooManyFiles(maximum):
            return "Choose no more than \(maximum) files at a time."
        case let .tooManyURLs(maximum):
            return "Choose no more than \(maximum) URLs at a time."
        case let .unsupportedFile(name):
            return "\(name) is not a supported photo, video, audio, or PDF."
        case let .libraryMismatch(mismatch):
            return "Open \(mismatch.expectedLibraryName) in Eagle and try again. "
                + "\(mismatch.actualLibraryName) is currently open."
        case let .batchFailed(sent, failed, firstFailure):
            let completed = sent + failed
            return "Sent \(sent) of \(completed) items. "
                + "\(failed) failed. \(firstFailure)"
        }
    }
}
