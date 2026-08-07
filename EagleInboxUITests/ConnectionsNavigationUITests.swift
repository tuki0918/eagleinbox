import XCTest

final class ConnectionsNavigationUITests: XCTestCase {
    private static let waitTimeout: TimeInterval = 5
    private static let seededProfileID =
        "3B112B34-6C80-44E8-B7D7-0A1C7399A5A7"

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testAddConnectionPushAndFirstTapTextEntry() {
        launchApp()
        openConnections()

        app.buttons["connections.add"].tap()

        XCTAssertTrue(
            app.navigationBars["New Connection"].waitForExistence(
                timeout: Self.waitTimeout
            )
        )
        let nameField = app.textFields["connectionEditor.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: Self.waitTimeout))

        nameField.tap()
        nameField.typeText(" UITEST")

        XCTAssertEqual(nameField.value as? String, "My Eagle UITEST")
    }

    func testUnchangedBackReturnsToConnections() {
        launchApp()
        openConnections()

        app.buttons["connections.add"].tap()
        XCTAssertTrue(
            app.navigationBars["New Connection"].waitForExistence(
                timeout: Self.waitTimeout
            )
        )

        app.buttons["connectionEditor.back"].tap()

        XCTAssertTrue(
            app.navigationBars["Connections"].waitForExistence(
                timeout: Self.waitTimeout
            )
        )
        XCTAssertFalse(app.alerts["Discard Changes?"].exists)
    }

    func testDirtyBackKeepEditingThenDiscard() {
        launchApp()
        openConnections()

        app.buttons["connections.add"].tap()
        let nameField = app.textFields["connectionEditor.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: Self.waitTimeout))
        nameField.tap()
        nameField.typeText(" UITEST")

        app.buttons["connectionEditor.back"].tap()

        let alert = app.alerts["Discard Changes?"]
        XCTAssertTrue(alert.waitForExistence(timeout: Self.waitTimeout))
        alert.buttons["Keep Editing"].tap()
        XCTAssertTrue(
            app.navigationBars["New Connection"].waitForExistence(
                timeout: Self.waitTimeout
            )
        )

        app.buttons["connectionEditor.back"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: Self.waitTimeout))
        alert.buttons["Discard Changes"].tap()

        XCTAssertTrue(
            app.navigationBars["Connections"].waitForExistence(
                timeout: Self.waitTimeout
            )
        )
    }

    func testSeededConnectionEditPushAndBack() {
        openSeededConnectionEditor(captureScreenshots: true)

        let tokenField = app.secureTextFields["connectionEditor.apiToken"]
        XCTAssertTrue(tokenField.waitForExistence(timeout: Self.waitTimeout))
        XCTAssertFalse((tokenField.value as? String)?.isEmpty ?? true)
        let showTokenButton = app.buttons["Show API token"]
        XCTAssertTrue(showTokenButton.waitForExistence(timeout: Self.waitTimeout))
        let addressLabel = app.staticTexts["Address"]
        XCTAssertTrue(
            addressLabel.waitForExistence(timeout: Self.waitTimeout)
        )
        let connectionSectionY = addressLabel.frame.minY
        showTokenButton.tap()
        let visibleTokenField = app.textFields["connectionEditor.apiToken"]
        XCTAssertTrue(
            visibleTokenField.waitForExistence(timeout: Self.waitTimeout)
        )
        XCTAssertEqual(visibleTokenField.value as? String, "demo-api-token")
        let hideTokenButton = app.buttons["Hide API token"]
        XCTAssertTrue(
            hideTokenButton.waitForExistence(timeout: Self.waitTimeout)
        )
        XCTAssertEqual(
            addressLabel.frame.minY,
            connectionSectionY,
            accuracy: 0.5
        )
        XCTAssertFalse(app.staticTexts["Eagle Version"].exists)
        let connectedStatus = app.staticTexts[
            "connectionEditor.statusValue"
        ]
        XCTAssertTrue(
            connectedStatus.waitForExistence(
                timeout: Self.waitTimeout
            )
        )
        XCTAssertTrue(connectedStatus.label.contains("Connected"))
        XCTAssertTrue(app.staticTexts["Connection"].exists)
        attachScreenshot(named: "connection-editor")
        app.buttons["connectionEditor.back"].tap()

        XCTAssertTrue(
            app.navigationBars["Connections"].waitForExistence(
                timeout: Self.waitTimeout
            )
        )
        XCTAssertFalse(app.alerts["Discard Changes?"].exists)
    }

    func testConnectionTestCanBeCanceledDuringStartDelay() {
        openSeededConnectionEditor()

        let connectedStatus = app.staticTexts[
            "connectionEditor.statusValue"
        ]
        XCTAssertTrue(
            connectedStatus.waitForExistence(timeout: Self.waitTimeout)
        )
        XCTAssertTrue(connectedStatus.label.contains("Connected"))

        let testConnectionButton = app.buttons["connectionEditor.test"]
        XCTAssertTrue(
            testConnectionButton.waitForExistence(timeout: Self.waitTimeout)
        )
        testConnectionButton.tap()

        waitForLabel(
            "Cancel Connection Test",
            on: testConnectionButton,
            timeout: 2
        )
        XCTAssertFalse(connectedStatus.exists)
        XCTAssertFalse(app.staticTexts["Testing…"].exists)
        testConnectionButton.tap()

        waitForLabel(
            "Test Connection",
            on: testConnectionButton,
            timeout: Self.waitTimeout
        )
        XCTAssertTrue(
            connectedStatus.waitForExistence(timeout: Self.waitTimeout)
        )
        XCTAssertTrue(testConnectionButton.isEnabled)
        XCTAssertFalse(
            app.staticTexts["connectionEditor.statusMessage"].exists
        )
    }

    func testSavingEditedConnectionUpdatesNameWithoutSuccessMessage() {
        openSeededConnectionEditor()

        let nameField = app.textFields["connectionEditor.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: Self.waitTimeout))
        nameField.tap()
        nameField.typeText(" Updated")
        XCTAssertEqual(nameField.value as? String, "Studio Updated")

        let saveButton = app.navigationBars["Edit Connection"].buttons["Save"]
        XCTAssertTrue(saveButton.isEnabled)
        saveButton.tap()

        XCTAssertTrue(
            app.navigationBars["Connections"].waitForExistence(
                timeout: Self.waitTimeout
            )
        )
        let updatedTitle = "Studio Updated - Design"
        let updatedRow = app.buttons[
            "connections.row.\(Self.seededProfileID)"
        ]
        XCTAssertTrue(
            updatedRow.waitForExistence(timeout: Self.waitTimeout)
        )
        XCTAssertTrue(updatedRow.label.contains(updatedTitle))
        XCTAssertFalse(app.staticTexts["Connection saved."].exists)

        let selectButton = app.buttons["connections.select"]
        XCTAssertTrue(selectButton.isEnabled)
        selectButton.tap()

        let connectionButton = app.buttons["upload.connection.open"]
        XCTAssertTrue(
            connectionButton.waitForExistence(timeout: Self.waitTimeout)
        )
        XCTAssertEqual(connectionButton.value as? String, updatedTitle)
        XCTAssertFalse(app.staticTexts["Connection saved."].exists)
    }

    func testShareMenuShowsUploadToEagle() {
        // Launch the containing app once so iOS installs its bundled share
        // extension before Safari builds the activity list.
        launchApp()
        app.terminate()

        let safari = XCUIApplication(
            bundleIdentifier: "com.apple.mobilesafari"
        )
        safari.open(URL(string: "https://example.com")!)

        let shareButton = firstExistingElement(
            in: safari,
            labels: ["Share", "共有"]
        )
        if !shareButton.waitForExistence(timeout: 1) {
            // iOS 26 places Share inside Safari's trailing page menu.
            let moreButton = firstExistingElement(
                in: safari,
                labels: ["More", "さらに表示"]
            )
            XCTAssertTrue(
                moreButton.waitForExistence(timeout: Self.waitTimeout)
            )
            moreButton.tap()
        }
        XCTAssertTrue(shareButton.waitForExistence(timeout: Self.waitTimeout))
        shareButton.tap()

        let shareExtension = firstExistingElement(
            in: safari,
            labels: ["Eagle Inbox", "Upload to Eagle"]
        )
        XCTAssertTrue(
            shareExtension.waitForExistence(timeout: Self.waitTimeout),
            safari.debugDescription
        )
        XCTAssertTrue(shareExtension.frame.intersects(safari.frame))
        attachScreenshot(named: "share-menu")
    }

    func testReadmeAddItemsMenuAndSeededQueueScreenshots() {
        launchApp()
        XCTAssertTrue(
            app.staticTexts["Connection Required"].waitForExistence(
                timeout: Self.waitTimeout
            ),
            app.debugDescription
        )
        XCTAssertTrue(
            app.staticTexts["No items yet"].waitForExistence(
                timeout: Self.waitTimeout
            )
        )
        attachScreenshot(named: "connection-required")

        openConnections()
        XCTAssertTrue(
            app.staticTexts["No Connections"].waitForExistence(
                timeout: Self.waitTimeout
            ),
            app.debugDescription
        )
        XCTAssertTrue(
            app.buttons["connections.add"].waitForExistence(
                timeout: Self.waitTimeout
            )
        )
        attachScreenshot(named: "connections-empty")

        app.terminate()
        launchApp(seedConnection: true)

        let addItemsButton = app.buttons["Add Items"]
        XCTAssertTrue(
            addItemsButton.waitForExistence(timeout: Self.waitTimeout)
        )
        addItemsButton.tap()

        for label in ["Photos", "Files", "URL"] {
            XCTAssertTrue(
                app.buttons[label].waitForExistence(timeout: Self.waitTimeout),
                "Expected \(label) in Add Items menu"
            )
        }
        attachScreenshot(named: "add-items-menu")

        app.terminate()
        launchApp(seedConnection: true)

        let metadataButton = app.buttons["Metadata"]
        XCTAssertTrue(
            metadataButton.waitForExistence(timeout: Self.waitTimeout),
            app.debugDescription
        )
        metadataButton.tap()

        XCTAssertEqual(
            metadataButton.value as? String,
            "Expanded, 3 settings"
        )
        XCTAssertTrue(
            app.buttons["Folders"].waitForExistence(
                timeout: Self.waitTimeout
            )
        )
        XCTAssertTrue(
            app.textViews["Annotation"].waitForExistence(
                timeout: Self.waitTimeout
            )
        )
        let tagsButton = app.buttons["Tags"]
        XCTAssertTrue(
            tagsButton.waitForExistence(timeout: Self.waitTimeout)
        )
        XCTAssertEqual(tagsButton.value as? String, "None")
        attachScreenshot(named: "metadata-expanded")

        app.terminate()
        launchApp(seedConnection: true, seedUploadQueue: true)

        let photoNames = app.textFields.matching(
            NSPredicate(format: "label == %@", "File name")
        )
        XCTAssertTrue(
            photoNames.firstMatch.waitForExistence(timeout: Self.waitTimeout),
            app.debugDescription
        )
        let thumbnailRendering = expectation(
            description: "Queue thumbnails finish rendering"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            thumbnailRendering.fulfill()
        }
        wait(for: [thumbnailRendering], timeout: 2)
        attachScreenshot(named: "upload-queue-photo-url")

        XCTAssertEqual(photoNames.count, 2)
        let displayedPhotoNames = Set(
            (0..<photoNames.count).compactMap {
                photoNames.element(boundBy: $0).value as? String
            }
        )
        XCTAssertEqual(
            displayedPhotoNames,
            Set(["IMG_0001", "IMG_0111"])
        )

        let bookmark = app.staticTexts["https://example.com/"]
        XCTAssertTrue(
            bookmark.waitForExistence(timeout: Self.waitTimeout),
            app.debugDescription
        )
    }

    func testTagSelectionSupportsSuggestionsAndNewTags() {
        launchApp(seedConnection: true, seedTags: true)

        let metadataButton = app.buttons["Metadata"]
        XCTAssertTrue(
            metadataButton.waitForExistence(timeout: Self.waitTimeout)
        )
        metadataButton.tap()

        let tagsButton = app.buttons["Tags"]
        XCTAssertTrue(tagsButton.waitForExistence(timeout: Self.waitTimeout))
        XCTAssertEqual(tagsButton.value as? String, "None")
        tagsButton.tap()

        XCTAssertTrue(
            app.navigationBars["Tags"].waitForExistence(
                timeout: Self.waitTimeout
            )
        )
        for groupID in ["work", "ideas", "__ungrouped__"] {
            XCTAssertTrue(
                app.staticTexts["tags.group.\(groupID)"].waitForExistence(
                    timeout: Self.waitTimeout
                ),
                app.debugDescription
            )
        }
        XCTAssertTrue(
            app.staticTexts["tags.section.recent"].waitForExistence(
                timeout: Self.waitTimeout
            ),
            app.debugDescription
        )
        attachScreenshot(named: "tags-grouped")

        let searchField = app.searchFields["Search or create a tag"]
        XCTAssertTrue(searchField.waitForExistence(timeout: Self.waitTimeout))
        searchField.tap()
        searchField.typeText("in")

        let inboxSuggestion = app.buttons["tags.suggestion.inbox"]
        XCTAssertTrue(
            inboxSuggestion.waitForExistence(timeout: Self.waitTimeout),
            app.debugDescription
        )
        XCTAssertTrue(
            app.buttons["tags.create"].waitForExistence(
                timeout: Self.waitTimeout
            )
        )
        attachScreenshot(named: "tags-selection")
        inboxSuggestion.tap()

        XCTAssertTrue(
            app.buttons["tags.selected.inbox"].waitForExistence(
                timeout: Self.waitTimeout
            )
        )
        let inboxCopies = app.buttons.matching(
            identifier: "tags.suggestion.inbox"
        )
        XCTAssertEqual(inboxCopies.count, 2)
        for index in 0..<inboxCopies.count {
            XCTAssertEqual(inboxCopies.element(boundBy: index).value as? String, "Selected")
        }
        searchField.tap()
        searchField.typeText("Concept")
        let createButton = app.buttons["tags.create"]
        XCTAssertTrue(
            createButton.waitForExistence(timeout: Self.waitTimeout)
        )
        createButton.tap()

        XCTAssertTrue(
            app.buttons["tags.selected.concept"].waitForExistence(
                timeout: Self.waitTimeout
            )
        )
        let closeSearchButton = app.buttons["close"]
        if closeSearchButton.exists {
            closeSearchButton.tap()
        }
        let selectButton = app.buttons["tags.select"]
        XCTAssertTrue(
            selectButton.waitForExistence(timeout: Self.waitTimeout)
        )
        selectButton.tap()

        XCTAssertTrue(tagsButton.waitForExistence(timeout: Self.waitTimeout))
        XCTAssertEqual(tagsButton.value as? String, "2 tags")
    }

    func testFolderSelectionShowsSelectedRecentAndAllCopies() {
        launchApp(seedConnection: true, seedFolders: true)

        let metadataButton = app.buttons["Metadata"]
        XCTAssertTrue(
            metadataButton.waitForExistence(timeout: Self.waitTimeout)
        )
        metadataButton.tap()

        let foldersButton = app.buttons["Folders"]
        XCTAssertTrue(foldersButton.waitForExistence(timeout: Self.waitTimeout))
        foldersButton.tap()
        XCTAssertTrue(
            app.navigationBars["Folders"].waitForExistence(
                timeout: Self.waitTimeout
            )
        )

        for sectionID in ["selected", "recent", "all"] {
            XCTAssertTrue(
                app.staticTexts["folders.section.\(sectionID)"].waitForExistence(
                    timeout: Self.waitTimeout
                ),
                app.debugDescription
            )
        }
        let inboxCopies = app.buttons.matching(
            identifier: "folders.row.folder-inbox"
        )
        XCTAssertEqual(inboxCopies.count, 3)
        for index in 0..<inboxCopies.count {
            XCTAssertEqual(inboxCopies.element(boundBy: index).value as? String, "Selected")
        }
        attachScreenshot(named: "folders-selected-recent-all")

        inboxCopies.element(boundBy: 2).tap()
        XCTAssertFalse(
            app.staticTexts["folders.section.selected"].waitForExistence(
                timeout: 1
            )
        )
        let remainingCopies = app.buttons.matching(
            identifier: "folders.row.folder-inbox"
        )
        XCTAssertEqual(remainingCopies.count, 2)
        for index in 0..<remainingCopies.count {
            XCTAssertEqual(
                remainingCopies.element(boundBy: index).value as? String,
                "Not selected"
            )
        }
    }

    private func firstExistingElement(
        in application: XCUIApplication,
        labels: [String]
    ) -> XCUIElement {
        application.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "label IN %@ OR identifier IN %@",
                    labels,
                    labels
                )
            )
            .firstMatch
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForLabel(
        _ label: String,
        on element: XCUIElement,
        timeout: TimeInterval
    ) {
        let expectation = expectation(
            for: NSPredicate(format: "label == %@", label),
            evaluatedWith: element
        )
        wait(for: [expectation], timeout: timeout)
    }

    private func launchApp(
        seedConnection: Bool = false,
        seedUploadQueue: Bool = false,
        seedTags: Bool = false,
        seedFolders: Bool = false
    ) {
        XCUIDevice.shared.press(.home)
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        if seedConnection {
            app.launchArguments.append("--ui-testing-seeded-connection")
        }
        if seedUploadQueue {
            app.launchArguments.append("--ui-testing-seeded-upload-queue")
        }
        if seedTags {
            app.launchArguments.append("--ui-testing-seeded-tags")
        }
        if seedFolders {
            app.launchArguments.append("--ui-testing-seeded-folders")
        }
        app.launch()
    }

    private func openConnections() {
        let button = app.buttons["upload.connection.open"]
        XCTAssertTrue(button.waitForExistence(timeout: Self.waitTimeout))
        button.tap()
        XCTAssertTrue(
            app.navigationBars["Connections"].waitForExistence(
                timeout: Self.waitTimeout
            )
        )
    }

    private func openSeededConnectionEditor(
        captureScreenshots: Bool = false
    ) {
        launchApp(seedConnection: true)
        XCTAssertTrue(
            app.buttons["upload.connection.open"].waitForExistence(
                timeout: Self.waitTimeout
            )
        )
        if captureScreenshots {
            attachScreenshot(named: "upload-overview")
        }

        openConnections()
        if captureScreenshots {
            attachScreenshot(named: "connections")
        }

        let editButton = app.buttons[
            "connections.edit.\(Self.seededProfileID)"
        ]
        XCTAssertTrue(editButton.waitForExistence(timeout: Self.waitTimeout))
        editButton.tap()

        XCTAssertTrue(
            app.navigationBars["Edit Connection"].waitForExistence(
                timeout: Self.waitTimeout
            )
        )
    }
}
