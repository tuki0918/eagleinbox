import Foundation
import UniformTypeIdentifiers

private final class ShareProviderLoadRequest<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var progress: Progress?
    private var cancellationRequested = false
    private var isCompleted = false

    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if cancellationRequested || isCompleted {
            isCompleted = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setProgress(_ progress: Progress) {
        lock.lock()
        let shouldCancel = cancellationRequested || isCompleted
        if !shouldCancel {
            self.progress = progress
        }
        lock.unlock()
        if shouldCancel {
            progress.cancel()
        }
    }

    @discardableResult
    func complete(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return false
        }
        isCompleted = true
        let continuation = continuation
        self.continuation = nil
        progress = nil
        lock.unlock()
        continuation?.resume(with: result)
        return continuation != nil
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let progress = progress
        let continuation = continuation
        if continuation != nil, !isCompleted {
            isCompleted = true
            self.continuation = nil
            self.progress = nil
        }
        lock.unlock()
        progress?.cancel()
        continuation?.resume(throwing: CancellationError())
    }
}

enum ShareMediaLoader {
    private struct LoadedFile {
        let url: URL
        let originalFileName: String
    }

    static func load(from context: NSExtensionContext?) async -> [QueuedUpload] {
        guard let inputItems = context?.inputItems as? [NSExtensionItem] else {
            return []
        }

        var uploads: [QueuedUpload] = []
        var seenBookmarkIdentities: Set<String> = []
        for inputItem in inputItems {
            for provider in inputItem.attachments ?? [] {
                do {
                    try Task.checkCancellation()
                    if let fileTypeIdentifier = bestFileTypeIdentifier(for: provider) {
                        let loadedFile = try await loadFile(
                            from: provider,
                            typeIdentifier: fileTypeIdentifier
                        )
                        guard !Task.isCancelled else {
                            try? FileManager.default.removeItem(at: loadedFile.url)
                            throw CancellationError()
                        }
                        uploads.append(
                            QueuedUpload(
                                name: MediaFileSupport.itemName(
                                    forFileName: loadedFile.originalFileName
                                ),
                                source: .file(
                                    url: loadedFile.url,
                                    mimeType: MediaFileSupport.mimeType(
                                        for: loadedFile.url,
                                        fallbackTypeIdentifier: fileTypeIdentifier
                                    )
                                )
                            )
                        )
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                              let url = try await loadURL(from: provider) {
                        let identity = MediaFileSupport.bookmarkIdentity(for: url)
                        guard seenBookmarkIdentities.insert(identity).inserted else {
                            continue
                        }
                        uploads.append(
                            QueuedUpload(
                                name: MediaFileSupport.itemName(forBookmarkURL: url),
                                source: .bookmark(url)
                            )
                        )
                    }
                } catch is CancellationError {
                    cleanupFiles(for: uploads)
                    return []
                } catch {
                    uploads.append(
                        QueuedUpload(
                            name: provider.suggestedName
                                ?? String(localized: "Could Not Load Attachment"),
                            source: .bookmark(URL(string: "invalid://attachment")!)
                        )
                    )
                    uploads[uploads.count - 1].state = .failed(error.localizedDescription)
                }
            }
        }
        guard !Task.isCancelled else {
            cleanupFiles(for: uploads)
            return []
        }
        return uploads
    }

    private static func bestFileTypeIdentifier(for provider: NSItemProvider) -> String? {
        let acceptedTypes: [UTType] = [.image, .movie, .audio, .pdf]
        for acceptedType in acceptedTypes {
            if let identifier = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: acceptedType) == true
            }) {
                return identifier
            }
        }
        return nil
    }

    private static func loadFile(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> LoadedFile {
        let providerSuggestedName = provider.suggestedName
        let request = ShareProviderLoadRequest<LoadedFile>()
        let loadedFile = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<LoadedFile, Error>) in
                guard request.install(continuation) else { return }
                let progress = provider.loadFileRepresentation(
                    forTypeIdentifier: typeIdentifier
                ) { url, error in
                    if let error {
                        request.complete(.failure(error))
                        return
                    }
                    guard let url else {
                        request.complete(.failure(EagleClientError.invalidResponse))
                        return
                    }

                    do {
                        let suggestedName = MediaFileSupport.resolvedSharedFileName(
                            suggestedName: providerSuggestedName,
                            representationFileName: url.lastPathComponent,
                            preferredFilenameExtension: UTType(typeIdentifier)?
                                .preferredFilenameExtension
                        )
                        let copied = try MediaFileSupport.temporaryCopy(
                            of: url,
                            suggestedName: suggestedName
                        )
                        let delivered = request.complete(
                            .success(
                                LoadedFile(
                                    url: copied,
                                    originalFileName: suggestedName
                                )
                            )
                        )
                        if !delivered {
                            try? FileManager.default.removeItem(at: copied)
                        }
                    } catch {
                        request.complete(.failure(error))
                    }
                }
                request.setProgress(progress)
            }
        } onCancel: {
            request.cancel()
        }
        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: loadedFile.url)
            throw CancellationError()
        }
        return loadedFile
    }

    private static func loadURL(from provider: NSItemProvider) async throws -> URL? {
        let request = ShareProviderLoadRequest<URL?>()
        let url = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<URL?, Error>) in
                guard request.install(continuation) else { return }
                provider.loadItem(
                    forTypeIdentifier: UTType.url.identifier,
                    options: nil
                ) { item, error in
                    if let error {
                        request.complete(.failure(error))
                        return
                    }
                    if let url = item as? URL {
                        request.complete(.success(url))
                    } else if let url = item as? NSURL {
                        request.complete(.success(url as URL))
                    } else if let value = item as? String {
                        request.complete(.success(URL(string: value)))
                    } else {
                        request.complete(.success(nil))
                    }
                }
            }
        } onCancel: {
            request.cancel()
        }
        try Task.checkCancellation()
        return url
    }

    private static func cleanupFiles(for uploads: [QueuedUpload]) {
        for upload in uploads {
            if case let .file(url, _) = upload.source {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
