import Foundation

@main
enum CoreSmoke {
    static func main() async throws {
        precondition(EagleAPIClient.connectionTestTimeout == 5)
        precondition(
            EagleClientError.connectionTestTimedOut.localizedDescription
                == "Couldn’t connect to Eagle."
        )
        precondition(
            ConnectionEditorTestTiming.startDelay == .milliseconds(1_200)
        )
        let canceledStartDelay = Task {
            await ConnectionEditorTestTiming.waitBeforeStarting()
        }
        canceledStartDelay.cancel()
        let didFinishCanceledDelay = await canceledStartDelay.value
        precondition(didFinishCanceledDelay == false)

        let sharedSuggestedName = MediaFileSupport.resolvedSharedFileName(
            suggestedName: "Vacation.jpg",
            representationFileName: "NSItemProvider-4F3A.tmp",
            preferredFilenameExtension: "jpg"
        )
        precondition(sharedSuggestedName == "Vacation.jpg")
        let sharedRepresentationName = MediaFileSupport.resolvedSharedFileName(
            suggestedName: "   ",
            representationFileName: "Original.png",
            preferredFilenameExtension: "png"
        )
        precondition(sharedRepresentationName == "Original.png")
        let sharedNameWithAddedExtension = MediaFileSupport.resolvedSharedFileName(
            suggestedName: "Scan",
            representationFileName: "provider-item",
            preferredFilenameExtension: "pdf"
        )
        precondition(sharedNameWithAddedExtension == "Scan.pdf")
        precondition(
            MediaFileSupport.itemName(forFileName: sharedNameWithAddedExtension)
                == "Scan"
        )

        precondition(EagleConnection.default.host == "192.168.0.100")
        precondition(EagleConnection.default.isValid)

        let connectionEditorBaseline = EagleConnectionProfile(
            name: "Studio Eagle",
            connection: EagleConnection(
                host: "192.168.0.20",
                port: 41595,
                token: ""
            ),
            expectedLibraryName: "Studio",
            libraryName: "Studio"
        )
        let unchangedConnectionDraft = ConnectionEditorDraft(
            profile: connectionEditorBaseline,
            portText: "41595"
        )
        precondition(unchangedConnectionDraft.isValid)
        precondition(
            unchangedConnectionDraft.preparedProfile == connectionEditorBaseline
        )
        precondition(
            !unchangedConnectionDraft.hasUnsavedChanges(
                comparedTo: connectionEditorBaseline
            )
        )
        precondition(
            unchangedConnectionDraft.matchesVerifiedConnection(
                connectionEditorBaseline.connection
            )
        )
        precondition(!unchangedConnectionDraft.matchesVerifiedConnection(nil))

        let changedPortDraft = ConnectionEditorDraft(
            profile: connectionEditorBaseline,
            portText: "41600"
        )
        precondition(changedPortDraft.isValid)
        precondition(changedPortDraft.preparedProfile?.connection.port == 41600)
        precondition(
            changedPortDraft.hasUnsavedChanges(comparedTo: connectionEditorBaseline)
        )
        precondition(
            !changedPortDraft.matchesVerifiedConnection(
                connectionEditorBaseline.connection
            )
        )

        var blankNameProfile = connectionEditorBaseline
        blankNameProfile.name = "   "
        precondition(
            !ConnectionEditorDraft(
                profile: blankNameProfile,
                portText: "41595"
            ).isValid
        )
        var blankHostProfile = connectionEditorBaseline
        blankHostProfile.connection.host = "   "
        precondition(
            !ConnectionEditorDraft(
                profile: blankHostProfile,
                portText: "41595"
            ).isValid
        )
        for invalidPort in ["not-a-port", "0", "65536"] {
            let invalidPortDraft = ConnectionEditorDraft(
                profile: connectionEditorBaseline,
                portText: invalidPort
            )
            precondition(!invalidPortDraft.isValid)
            precondition(
                invalidPortDraft.hasUnsavedChanges(
                    comparedTo: connectionEditorBaseline
                )
            )
        }

        let settingsSuiteName = "com.tuki0918.EagleInbox.CoreSmoke.\(UUID().uuidString)"
        guard let settingsDefaults = UserDefaults(suiteName: settingsSuiteName) else {
            throw EagleClientError.invalidResponse
        }
        settingsDefaults.removePersistentDomain(forName: settingsSuiteName)
        defer {
            settingsDefaults.removePersistentDomain(forName: settingsSuiteName)
        }
        settingsDefaults.set(
            try JSONEncoder().encode([Int]()),
            forKey: "eagle.connection-profiles.v\(SharedIdentifiers.connectionStoreVersion)"
        )
        settingsDefaults.set(
            UUID().uuidString,
            forKey: "eagle.selected-profile-id"
        )
        let emptySettingsSnapshot = SharedSettingsStore(
            defaultsSuiteName: settingsSuiteName
        ).load()
        precondition(emptySettingsSnapshot.profiles.isEmpty)
        precondition(emptySettingsSnapshot.selectedProfileID == nil)

        let isolatedTokenService = "\(settingsSuiteName).tokens"
        precondition(
            SharedSettingsStore().tokenServiceIdentifier
                == SharedIdentifiers.tokenService
        )
        precondition(
            SharedSettingsStore(
                defaultsSuiteName: settingsSuiteName,
                tokenService: isolatedTokenService
            ).tokenServiceIdentifier == isolatedTokenService
        )

        let tokenlessConnection = EagleConnection(
            host: "127.0.0.1",
            port: 41595,
            token: ""
        )
        precondition(tokenlessConnection.isValid)
        let tokenlessEndpoint = try tokenlessConnection.endpoint("/api/v2/app/info")
        precondition(
            URLComponents(url: tokenlessEndpoint, resolvingAgainstBaseURL: false)?
                .queryItems?.contains(where: { $0.name == "token" }) != true
        )
        var whitespaceTokenConnection = tokenlessConnection
        whitespaceTokenConnection.token = "   "
        let whitespaceTokenEndpoint = try whitespaceTokenConnection.endpoint(
            "/api/v2/app/info"
        )
        precondition(
            URLComponents(url: whitespaceTokenEndpoint, resolvingAgainstBaseURL: false)?
                .queryItems?.contains(where: { $0.name == "token" }) != true
        )

        let connection = EagleConnection(
            host: "http://192.168.1.20:9999/path",
            port: 41595,
            token: "  token value  "
        )
        let endpoint = try connection.endpoint("/api/v2/item/add")
        precondition(connection.normalizedHost == "192.168.1.20")
        precondition(
            connection.normalizedForStorage
                == EagleConnection(
                    host: "192.168.1.20",
                    port: 41595,
                    token: "token value"
                )
        )
        precondition(endpoint.host == "192.168.1.20")
        precondition(endpoint.port == 41595)
        precondition(URLComponents(url: endpoint, resolvingAgainstBaseURL: false)?
            .queryItems?.first?.value == "token value")

        let pagedEndpoint = try connection.endpoint(
            "/api/v2/folder/get",
            queryItems: [
                URLQueryItem(name: "offset", value: "1000"),
                URLQueryItem(name: "limit", value: "1000")
            ]
        )
        let queryItems = URLComponents(
            url: pagedEndpoint,
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []
        precondition(queryItems.first(where: { $0.name == "offset" })?.value == "1000")
        precondition(queryItems.first(where: { $0.name == "limit" })?.value == "1000")
        precondition(queryItems.first(where: { $0.name == "token" })?.value == "token value")

        let recentFoldersEndpoint = try connection.endpoint(
            "/api/v2/folder/get",
            queryItems: [URLQueryItem(name: "isRecent", value: "true")]
        )
        let recentFolderQueryItems = URLComponents(
            url: recentFoldersEndpoint,
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []
        precondition(
            recentFolderQueryItems.first(where: { $0.name == "isRecent" })?.value
                == "true"
        )

        let parsedTags = EagleTag.parsed(
            from: [
                ["name": "Design", "count": 12, "groups": ["styles"]],
                ["name": "design", "count": 42, "groups": ["work"]],
                ["name": "Designer", "count": 80, "groups": ["styles"]],
                ["name": "UI Design", "count": 120],
                ["name": "デザイン", "count": 24],
                ["name": "", "count": 999]
            ]
        )
        precondition(parsedTags.count == 4)
        precondition(parsedTags.first(where: { $0.id == "design" })?.count == 42)
        precondition(
            parsedTags.first(where: { $0.id == "design" })?.groupIDs
                == ["styles", "work"]
        )

        let stringCountTags = EagleTag.parsed(
            from: [["name": "String Count", "count": "17"]]
        )
        precondition(stringCountTags.first?.count == 17)

        let imageCountTags = EagleTag.parsed(
            from: [
                ["name": "Image Count", "imageCount": 23],
                ["name": "Preferred Count", "imageCount": 31, "count": 0]
            ]
        )
        precondition(
            imageCountTags.first(where: { $0.id == "image count" })?.count
                == 23
        )
        precondition(
            imageCountTags.first(where: { $0.id == "preferred count" })?.count
                == 31
        )

        let recentTagsWithImageCounts = EagleTag.parsed(
            from: [
                ["name": "Reference", "imageCount": 8],
                ["name": "Design", "imageCount": 13]
            ],
            preservingOrder: true
        )
        precondition(recentTagsWithImageCounts.map(\.count) == [8, 13])

        let parsedTagGroups = EagleTagGroup.parsed(
            from: [
                [
                    "id": "styles",
                    "name": "Styles",
                    "color": "blue",
                    "tags": ["Design", "Designer"],
                    "description": "Visual styles"
                ],
                [
                    "id": "work",
                    "name": "Work",
                    "tags": ["design", "UI Design"]
                ]
            ]
        )
        precondition(parsedTagGroups.map(\.name) == ["Styles", "Work"])
        let groupedTagSections = EagleTagGrouping.sections(
            from: parsedTags,
            groups: parsedTagGroups
        )
        precondition(groupedTagSections.map(\.title) == ["Styles", "Work", "Ungrouped"])
        precondition(groupedTagSections[0].tags.map(\.id) == ["design", "designer"])
        precondition(groupedTagSections[1].tags.map(\.id) == ["design", "ui design"])
        precondition(groupedTagSections[2].tags.map(\.name) == ["デザイン"])

        let recentTags = EagleTag.recent(from: EagleTag.parsed(
            from: [
                ["name": "First", "count": 1],
                ["name": "Second", "count": 99],
                ["name": "Third", "count": 3],
                ["name": "Fourth", "count": 4],
                ["name": "Fifth", "count": 5],
                ["name": "Sixth", "count": 6],
                ["name": "first", "count": 10]
            ],
            preservingOrder: true
        ))
        precondition(EagleTag.recentLimit == 5)
        precondition(
            recentTags.map(\.id) == ["first", "second", "third", "fourth", "fifth"]
        )

        let designSuggestions = EagleTagSuggestionRanker.suggestions(
            from: parsedTags,
            matching: "design",
            excluding: []
        )
        precondition(
            designSuggestions.map(\.name) == ["design", "Designer", "UI Design"]
        )
        let suggestionsWithoutSelected = EagleTagSuggestionRanker.suggestions(
            from: parsedTags,
            matching: "DESIGN",
            excluding: ["Design"]
        )
        precondition(
            suggestionsWithoutSelected.map(\.name) == ["Designer", "UI Design"]
        )
        let japaneseSuggestions = EagleTagSuggestionRanker.suggestions(
            from: parsedTags,
            matching: "デザ",
            excluding: []
        )
        precondition(japaneseSuggestions.map(\.name) == ["デザイン"])
        precondition(EagleTag.normalized("Ｃａｆé") == "cafe")

        // Keep the original labeled initializer call source-compatible when the
        // optional expected-library pin is omitted.
        let legacyProfile = EagleConnectionProfile(
            name: "Studio Mac",
            connection: connection,
            libraryName: "Legacy Library"
        )
        precondition(legacyProfile.expectedLibraryName == nil)
        precondition(legacyProfile.libraryName == "Legacy Library")
        precondition(legacyProfile.displayTitle == "Studio Mac")

        let detectedLibrary = EagleConnectionStatus(
            libraryName: "Design Library"
        )
        var pinnedProfile = EagleConnectionProfile(
            name: "Studio Mac",
            connection: connection
        )

        // The first successful test has no expectation yet and supplies the pin.
        pinnedProfile.expectedLibraryName = detectedLibrary.libraryName
        precondition(pinnedProfile.expectedLibraryName == "Design Library")
        precondition(pinnedProfile.displayTitle == "Studio Mac - Design Library")

        // Re-testing the pinned library produces no mismatch.
        precondition(
            detectedLibrary.libraryMismatch(
                expectedLibraryName: pinnedProfile.expectedLibraryName
            ) == nil
        )

        let differentLibraryStatus = EagleConnectionStatus(
            libraryName: "Reference Library"
        )
        let mismatch = try requiredMismatch(
            differentLibraryStatus.libraryMismatch(
                expectedLibraryName: pinnedProfile.expectedLibraryName
            )
        )
        precondition(mismatch.expectedLibraryName == "Design Library")
        precondition(mismatch.actualLibraryName == "Reference Library")
        precondition(mismatch.warningMessage.contains("Design Library"))
        precondition(mismatch.warningMessage.contains("Reference Library"))
        precondition(!mismatch.warningMessage.contains("Open “Design Library”"))
        precondition(
            mismatch.warningMessage
                == "Library mismatch.\nExpected “Design Library”, but “Reference Library” is open."
        )
        precondition(
            mismatch.uploadConfirmationMessage
                == "Expected “Design Library”, but “Reference Library” is open."
        )
        precondition(mismatch.libraryUpdateConfirmationMessage.contains("Update it to use “Reference Library”?"))

        // A changed library is proposed to the editor; applying and saving it
        // remains an explicit UI decision.
        var proposedProfile = pinnedProfile
        proposedProfile.expectedLibraryName = mismatch.actualLibraryName
        proposedProfile.libraryName = mismatch.actualLibraryName
        let draftResult = EagleDraftConnectionTestResult.libraryUpdateProposal(
            profile: proposedProfile,
            mismatch: mismatch
        )
        guard case let .libraryUpdateProposal(profile, proposalMismatch) = draftResult else {
            preconditionFailure("A changed library must require an update proposal.")
        }
        precondition(profile.expectedLibraryName == "Reference Library")
        precondition(proposalMismatch == mismatch)
        precondition(pinnedProfile.expectedLibraryName == "Design Library")

        let savedLibraryProposal = EagleConnectionLibraryUpdateProposal(
            profile: proposedProfile,
            mismatch: mismatch
        )
        precondition(savedLibraryProposal.profile.id == pinnedProfile.id)
        precondition(savedLibraryProposal.testedExpectedLibraryName == "Design Library")
        precondition(savedLibraryProposal.mismatch.actualLibraryName == "Reference Library")

        let warningState = ConnectionTestState.warning(mismatch.warningMessage)
        guard case let .warning(warningMessage) = warningState else {
            preconditionFailure("A library mismatch must be represented as a warning.")
        }
        precondition(warningMessage == mismatch.warningMessage)

        let successfulNotification = try requiredNotificationResult(
            .completed(sent: 2, failed: 0)
        )
        precondition(successfulNotification.title == "Sent to Eagle")
        precondition(successfulNotification.body == "2 items were sent.")

        let partialNotification = try requiredNotificationResult(
            .completed(sent: 2, failed: 1)
        )
        precondition(partialNotification.title == "Some Items Couldn’t Send")
        precondition(partialNotification.body.contains("2 sent, 1 failed"))

        let failedNotification = try requiredNotificationResult(
            .completed(sent: 0, failed: 1)
        )
        precondition(failedNotification.title == "Couldn’t Send to Eagle")
        precondition(failedNotification.body.contains("1 item couldn’t be sent"))
        precondition(UploadNotificationResult.completed(sent: 0, failed: 0) == nil)

        precondition(pinnedProfile.expectedLibraryName == "Design Library")

        let mediaURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eagle-inbox-core-smoke.bin")
        try Data([0, 1, 2, 3, 4, 5]).write(to: mediaURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: mediaURL) }

        let bodyURL = try Base64JSONBodyWriter.write(
            fileURL: mediaURL,
            mimeType: "image/png",
            metadata: EagleUploadMetadata(
                name: "smoke",
                website: "https://example.com",
                tags: ["test"],
                folders: ["FOLDER"],
                annotation: "first line\nsecond line"
            )
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: bodyURL))
        let dictionary = try requiredDictionary(object)
        precondition(dictionary["name"] as? String == "smoke")
        precondition(dictionary["annotation"] as? String == "first line\nsecond line")
        precondition(dictionary["base64"] as? String == "data:image/png;base64,AAECAwQF")

        let missingMediaURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eagle-inbox-missing-\(UUID().uuidString).bin")
        do {
            _ = try Base64JSONBodyWriter.write(
                fileURL: missingMediaURL,
                mimeType: "application/octet-stream",
                metadata: EagleUploadMetadata(
                    name: "missing",
                    website: nil,
                    tags: [],
                    folders: [],
                    annotation: nil
                )
            )
            preconditionFailure("A missing upload source must fail body generation")
        } catch {}

        let bookmark = EagleUploadMetadata(
            name: "Example Site",
            website: "https://unused.example.com",
            tags: ["reference"],
            folders: [],
            annotation: nil
        ).bookmarkJSONObject(url: URL(string: "https://www.example.com")!)
        precondition(bookmark["bookmarkURL"] as? String == "https://www.example.com")
        precondition(bookmark["name"] as? String == "Example Site")
        precondition(bookmark["tags"] as? [String] == ["reference"])
        precondition(bookmark["website"] == nil)

        let identityA = MediaFileSupport.bookmarkIdentity(
            for: URL(string: "HTTPS://Example.com:443#overview")!
        )
        let identityB = MediaFileSupport.bookmarkIdentity(
            for: URL(string: "https://example.com/")!
        )
        precondition(identityA == identityB)

        let importedFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("eagle-inbox-import-\(UUID().uuidString).png")
        let onePixelPNG = Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        try onePixelPNG.write(to: importedFile)
        defer { try? FileManager.default.removeItem(at: importedFile) }
        precondition(MediaFileSupport.isSupportedFile(importedFile))

        let importedFiles = MediaFileSupport.importFiles(
            [importedFile, importedFile]
        )
        precondition(importedFiles.latestErrorMessage == nil)
        precondition(importedFiles.uploads.count == 1)
        precondition(importedFiles.uploads.first?.name.hasPrefix("eagle-inbox-import-") == true)
        for upload in importedFiles.uploads {
            if case let .file(url, mimeType) = upload.source {
                precondition(mimeType == "image/png")
                try? FileManager.default.removeItem(at: url)
            }
        }

        let folders = EagleFolder.flattened(
            from: [
                [
                    "id": "ROOT",
                    "name": "Design",
                    "imageCount": 12,
                    "children": [
                        [
                            "id": "CHILD",
                            "name": "References",
                            "imageCount": "4"
                        ]
                    ]
                ],
                [
                    "id": "LOOSE_CHILD",
                    "name": "Inspiration",
                    "parent": "ROOT",
                    "imageCount": 7
                ]
            ]
        )
        precondition(folders.map(\.id) == ["ROOT", "CHILD", "LOOSE_CHILD"])
        precondition(folders.first(where: { $0.id == "CHILD" })?.path == "Design / References")
        precondition(folders.first(where: { $0.id == "LOOSE_CHILD" })?.depth == 1)
        precondition(folders.first(where: { $0.id == "ROOT" })?.imageCount == 12)
        precondition(folders.first(where: { $0.id == "CHILD" })?.imageCount == 4)

        let recentFolders = EagleFolder.recent(
            from: [folders[2], folders[0], folders[2]],
            matching: folders
        )
        precondition(recentFolders.map(\.id) == ["LOOSE_CHILD", "ROOT"])
        precondition(recentFolders.map(\.imageCount) == [7, 12])

        print("Core smoke tests passed")
    }

    private static func requiredDictionary(_ object: Any) throws -> [String: Any] {
        guard let dictionary = object as? [String: Any] else {
            throw EagleClientError.invalidResponse
        }
        return dictionary
    }

    private static func requiredMismatch(
        _ mismatch: EagleLibraryMismatch?
    ) throws -> EagleLibraryMismatch {
        guard let mismatch else {
            throw EagleClientError.invalidResponse
        }
        return mismatch
    }

    private static func requiredNotificationResult(
        _ result: UploadNotificationResult?
    ) throws -> UploadNotificationResult {
        guard let result else {
            throw EagleClientError.invalidResponse
        }
        return result
    }

    private static func requiredUUID(_ value: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            throw EagleClientError.invalidResponse
        }
        return uuid
    }
}
