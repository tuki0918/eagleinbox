import Foundation

struct EagleAPIClient: Sendable {
    static let connectionTestTimeout: TimeInterval = 5

    let connection: EagleConnection
    private let session: URLSession

    init(connection: EagleConnection) {
        self.connection = connection
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 900
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func testConnection() async throws -> EagleConnectionStatus {
        try await withThrowingTaskGroup(
            of: EagleConnectionStatus.self,
            returning: EagleConnectionStatus.self
        ) { group in
            group.addTask {
                try await connectionStatus()
            }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: UInt64(
                        Self.connectionTestTimeout * 1_000_000_000
                    )
                )
                try Task.checkCancellation()
                throw EagleClientError.connectionTestTimedOut
            }
            defer { group.cancelAll() }

            guard let result = try await group.next() else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            return result
        }
    }

    private func connectionStatus() async throws -> EagleConnectionStatus {
        async let appPayload = get(path: "/api/v2/app/info")
        async let libraryPayload = get(path: "/api/v2/library/info")
        let (_, libraryValue) = try await (appPayload, libraryPayload)

        guard let library = libraryValue as? [String: Any],
              let libraryName = library["name"] as? String,
              !libraryName.isEmpty else {
            throw EagleClientError.invalidResponse
        }
        return EagleConnectionStatus(libraryName: libraryName)
    }

    func fetchFolders() async throws -> [EagleFolder] {
        try await fetchFolderList()
    }

    func fetchRecentFolders() async throws -> [EagleFolder] {
        try await fetchFolderList(
            isRecent: true,
            pageLimit: EagleFolder.recentLimit,
            maximumCount: EagleFolder.recentLimit
        )
    }

    private func fetchFolderList(
        isRecent: Bool = false,
        pageLimit: Int = 1_000,
        maximumCount: Int? = nil
    ) async throws -> [EagleFolder] {
        var offset = 0
        var allObjects: [[String: Any]] = []
        var pageFingerprints: Set<String> = []

        while true {
            var queryItems = [
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "limit", value: String(pageLimit))
            ]
            if isRecent {
                queryItems.insert(
                    URLQueryItem(name: "isRecent", value: "true"),
                    at: 0
                )
            }
            let payload = try await get(
                path: "/api/v2/folder/get",
                queryItems: queryItems
            )
            let page = try folderPage(from: payload)
            let fingerprint = page.objects.compactMap { $0["id"] as? String }
                .joined(separator: "\u{0}")
            guard pageFingerprints.insert(fingerprint).inserted else { break }

            allObjects.append(contentsOf: page.objects)
            if let maximumCount, allObjects.count >= maximumCount {
                break
            }

            let loadedCount = page.objects.count
            let hasMore = if let total = page.total {
                offset + loadedCount < total
            } else {
                loadedCount == pageLimit
            }
            guard hasMore, loadedCount > 0 else { break }
            offset += loadedCount
        }

        let folders = EagleFolder.flattened(from: allObjects)
        if let maximumCount {
            return Array(folders.prefix(maximumCount))
        }
        return folders
    }

    func fetchTags() async throws -> [EagleTag] {
        try await fetchTagList(
            path: "/api/v2/tag/get",
            preservingOrder: false
        )
    }

    func fetchRecentTags() async throws -> [EagleTag] {
        let tags = try await fetchTagList(
            path: "/api/v2/tag/getRecentTags",
            preservingOrder: true,
            pageLimit: EagleTag.recentLimit,
            maximumCount: EagleTag.recentLimit
        )
        return EagleTag.recent(from: tags)
    }

    private func fetchTagList(
        path: String,
        preservingOrder: Bool,
        pageLimit: Int = 1_000,
        maximumCount: Int? = nil
    ) async throws -> [EagleTag] {
        var offset = 0
        var allObjects: [[String: Any]] = []
        var pageFingerprints: Set<String> = []

        while true {
            let payload = try await get(
                path: path,
                queryItems: [
                    URLQueryItem(name: "offset", value: String(offset)),
                    URLQueryItem(name: "limit", value: String(pageLimit))
                ]
            )
            let page = try tagPage(from: payload)
            let fingerprint = page.objects.compactMap { $0["name"] as? String }
                .joined(separator: "\u{0}")
            guard pageFingerprints.insert(fingerprint).inserted else { break }

            allObjects.append(contentsOf: page.objects)
            if let maximumCount, allObjects.count >= maximumCount {
                break
            }
            let loadedCount = page.objects.count
            let hasMore = if let total = page.total {
                offset + loadedCount < total
            } else {
                loadedCount == pageLimit
            }
            guard hasMore, loadedCount > 0 else { break }
            offset += loadedCount
        }

        return EagleTag.parsed(
            from: allObjects,
            preservingOrder: preservingOrder
        )
    }

    func fetchTagGroups() async throws -> [EagleTagGroup] {
        let pageLimit = 1_000
        var offset = 0
        var allObjects: [[String: Any]] = []
        var pageFingerprints: Set<String> = []

        while true {
            let payload = try await get(
                path: "/api/v2/tagGroup/get",
                queryItems: [
                    URLQueryItem(name: "offset", value: String(offset)),
                    URLQueryItem(name: "limit", value: String(pageLimit))
                ]
            )
            let page = try tagGroupPage(from: payload)
            let fingerprint = page.objects.compactMap { $0["id"] as? String }
                .joined(separator: "\u{0}")
            guard pageFingerprints.insert(fingerprint).inserted else { break }

            allObjects.append(contentsOf: page.objects)
            let loadedCount = page.objects.count
            let hasMore = if let total = page.total {
                offset + loadedCount < total
            } else {
                loadedCount == pageLimit
            }
            guard hasMore, loadedCount > 0 else { break }
            offset += loadedCount
        }

        return EagleTagGroup.parsed(from: allObjects)
    }

    func upload(
        source: EagleUploadSource,
        metadata: EagleUploadMetadata,
        progress: (@Sendable (UploadProgressSnapshot) -> Void)? = nil
    ) async throws -> EagleUploadResult {
        switch source {
        case let .bookmark(url):
            return try await uploadBookmark(url, metadata: metadata)
        case let .file(url, mimeType):
            return try await uploadFile(
                url,
                mimeType: mimeType,
                metadata: metadata,
                progress: progress
            )
        }
    }

    private func uploadBookmark(
        _ bookmarkURL: URL,
        metadata: EagleUploadMetadata
    ) async throws -> EagleUploadResult {
        guard let scheme = bookmarkURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              bookmarkURL.host?.isEmpty == false else {
            throw EagleClientError.invalidBookmarkURL
        }

        var request = try uploadRequest()
        request.httpBody = try JSONSerialization.data(
            withJSONObject: metadata.bookmarkJSONObject(url: bookmarkURL)
        )
        let (data, response) = try await session.data(for: request)
        return try parseUploadResult(data: data, response: response)
    }

    private func uploadFile(
        _ fileURL: URL,
        mimeType: String,
        metadata: EagleUploadMetadata,
        progress: (@Sendable (UploadProgressSnapshot) -> Void)?
    ) async throws -> EagleUploadResult {
        let bodyURL = try Base64JSONBodyWriter.write(
            fileURL: fileURL,
            mimeType: mimeType,
            metadata: metadata
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let request = try uploadRequest()
        let delegate = progress.map(UploadProgressTaskDelegate.init)
        let (data, response) = try await session.upload(
            for: request,
            fromFile: bodyURL,
            delegate: delegate
        )
        return try parseUploadResult(data: data, response: response)
    }

    private func uploadRequest() throws -> URLRequest {
        var request = URLRequest(url: try connection.endpoint("/api/v2/item/add"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func get(
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> Any {
        var request = URLRequest(
            url: try connection.endpoint(path, queryItems: queryItems)
        )
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        return try parse(data: data, response: response)
    }

    private func folderPage(from payload: Any) throws -> FolderPage {
        if let objects = payload as? [[String: Any]] {
            return FolderPage(objects: objects, total: nil)
        }
        guard let dictionary = payload as? [String: Any] else {
            throw EagleClientError.invalidResponse
        }
        if let objects = dictionary["data"] as? [[String: Any]] {
            return FolderPage(
                objects: objects,
                total: dictionary["total"] as? Int
            )
        }
        if let objects = dictionary["folders"] as? [[String: Any]] {
            return FolderPage(objects: objects, total: nil)
        }
        throw EagleClientError.invalidResponse
    }

    private func tagPage(from payload: Any) throws -> TagPage {
        if let objects = tagObjects(from: payload) {
            return TagPage(objects: objects, total: nil)
        }
        guard let dictionary = payload as? [String: Any] else {
            throw EagleClientError.invalidResponse
        }
        if let objects = tagObjects(from: dictionary["data"]) {
            return TagPage(
                objects: objects,
                total: (dictionary["total"] as? NSNumber)?.intValue
                    ?? dictionary["total"] as? Int
            )
        }
        if let objects = tagObjects(from: dictionary["tags"]) {
            return TagPage(objects: objects, total: nil)
        }
        throw EagleClientError.invalidResponse
    }

    private func tagGroupPage(from payload: Any) throws -> TagGroupPage {
        if let objects = tagGroupObjects(from: payload) {
            return TagGroupPage(objects: objects, total: nil)
        }
        guard let dictionary = payload as? [String: Any] else {
            throw EagleClientError.invalidResponse
        }
        if let objects = tagGroupObjects(from: dictionary["data"]) {
            return TagGroupPage(
                objects: objects,
                total: (dictionary["total"] as? NSNumber)?.intValue
                    ?? dictionary["total"] as? Int
            )
        }
        if let objects = tagGroupObjects(from: dictionary["tagGroups"]) {
            return TagGroupPage(objects: objects, total: nil)
        }
        throw EagleClientError.invalidResponse
    }

    private func tagObjects(from value: Any?) -> [[String: Any]]? {
        guard let values = value as? [Any] else { return nil }
        return values.compactMap { value in
            if let object = value as? [String: Any] {
                return object
            }
            if let name = value as? String {
                return ["name": name]
            }
            return nil
        }
    }

    private func tagGroupObjects(from value: Any?) -> [[String: Any]]? {
        value as? [[String: Any]]
    }

    private func parseUploadResult(data: Data, response: URLResponse) throws -> EagleUploadResult {
        let payload = try parse(data: data, response: response)
        if let id = payload as? String, !id.isEmpty {
            return EagleUploadResult(ids: [id])
        }
        guard let dictionary = payload as? [String: Any] else {
            throw EagleClientError.invalidResponse
        }

        if let id = dictionary["id"] as? String {
            return EagleUploadResult(ids: [id])
        }
        if let ids = dictionary["ids"] as? [String] {
            return EagleUploadResult(ids: ids)
        }
        throw EagleClientError.invalidResponse
    }

    private func parse(data: Data, response: URLResponse) throws -> Any {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EagleClientError.invalidResponse
        }

        let object = try? JSONSerialization.jsonObject(with: data)
        let envelope = object as? [String: Any]
        let message = envelope?["message"] as? String
            ?? String(data: data, encoding: .utf8)
            ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw EagleClientError.server(
                statusCode: httpResponse.statusCode,
                message: message
            )
        }
        guard let envelope,
              let status = envelope["status"] as? String else {
            throw EagleClientError.invalidResponse
        }
        guard status.lowercased() == "success" else {
            throw EagleClientError.api(message: message)
        }
        guard let payload = envelope["data"] else {
            throw EagleClientError.invalidResponse
        }
        return payload
    }
}

private final class UploadProgressTaskDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable {
    private let handler: @Sendable (UploadProgressSnapshot) -> Void
    private let lock = NSLock()
    private var lastReportedAt: TimeInterval = 0

    init(handler: @escaping @Sendable (UploadProgressSnapshot) -> Void) {
        self.handler = handler
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let expectedByteCount = totalBytesExpectedToSend > 0
            ? totalBytesExpectedToSend
            : task.countOfBytesExpectedToSend
        guard expectedByteCount > 0 else { return }

        let snapshot = UploadProgressSnapshot(
            sentByteCount: totalBytesSent,
            totalByteCount: expectedByteCount
        )
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        let shouldReport = lastReportedAt == 0
            || snapshot.isComplete
            || now - lastReportedAt >= 0.1
        if shouldReport {
            lastReportedAt = now
        }
        lock.unlock()

        if shouldReport {
            handler(snapshot)
        }
    }
}

private struct FolderPage {
    let objects: [[String: Any]]
    let total: Int?
}

private struct TagPage {
    let objects: [[String: Any]]
    let total: Int?
}

private struct TagGroupPage {
    let objects: [[String: Any]]
    let total: Int?
}
