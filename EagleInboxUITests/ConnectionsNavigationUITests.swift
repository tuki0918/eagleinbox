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

    func testJapaneseLocalizationSmoke() {
        launchApp(language: "ja", locale: "ja_JP")

        XCTAssertTrue(
            app.staticTexts["接続先が必要です"].waitForExistence(
                timeout: Self.waitTimeout
            )
        )
        XCTAssertTrue(app.staticTexts["送信リスト"].exists)

        openConnections(expectedTitle: "接続先")
        app.buttons["connections.add"].tap()

        let editor = app.navigationBars["新しい接続先"]
        XCTAssertTrue(editor.waitForExistence(timeout: Self.waitTimeout))
        XCTAssertTrue(editor.buttons["保存"].exists)
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

    func testSecondConnectionOpensProUpgrade() {
        launchApp(seedConnection: true)
        openConnections()

        app.buttons["connections.add"].tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["pro.title"].waitForExistence(
                timeout: Self.waitTimeout
            )
        )
        XCTAssertTrue(app.staticTexts["Unlimited Connections"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "Unlock unlimited connections and all Shortcut actions."
            ].exists
        )
        XCTAssertTrue(app.staticTexts["All Shortcut Actions"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "Send files and URLs with tags and an annotation."
            ].exists
        )
        XCTAssertTrue(
            app.staticTexts[
                "Send files and URLs without opening the app."
            ].exists
        )
        XCTAssertTrue(app.buttons["pro.purchase"].exists)
        XCTAssertTrue(app.buttons["pro.restore"].exists)
        XCTAssertTrue(app.buttons["Restore Purchases"].exists)

        app.buttons["Not Now"].tap()
        XCTAssertTrue(
            app.navigationBars["Connections"].waitForExistence(
                timeout: Self.waitTimeout
            )
        )
    }

    func testStoreScreenshotPaywallUsesPriceFreeTitle() {
        launchApp(seedConnection: true, storeScreenshot: true)
        openConnections()
        app.buttons["connections.add"].tap()

        XCTAssertTrue(
            app.buttons["pro.purchase"].waitForExistence(
                timeout: Self.waitTimeout
            )
        )
        XCTAssertEqual(app.buttons["pro.purchase"].label, "Unlock Pro")
        XCTAssertTrue(app.buttons["pro.purchase"].isEnabled)
    }

    func testJapaneseProUpgradeLocalization() {
        launchApp(
            seedConnection: true,
            language: "ja",
            locale: "ja_JP"
        )
        openConnections(expectedTitle: "接続先")
        app.buttons["connections.add"].tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["pro.title"].waitForExistence(
                timeout: Self.waitTimeout
            )
        )
        for text in [
            "接続先を無制限に追加し、すべてのショートカット機能を利用できます。",
            "Eagleの接続先をいくつでも登録・切り替えできます。",
            "ショートカット機能",
            "タグや注釈を付け、ファイルやURLを送信できます。",
            "アプリを開かず、ファイルやURLを送信できます。",
            "買い切りで、継続料金はかかりません。"
        ] {
            XCTAssertTrue(
                app.staticTexts[text].waitForExistence(
                    timeout: Self.waitTimeout
                ),
                "Expected localized Pro copy: \(text)"
            )
        }
        XCTAssertTrue(app.buttons["購入を復元"].exists)
    }

    func testHTTPSSelectionRequiresConfirmation() {
        launchApp()
        openConnections()

        app.buttons["connections.add"].tap()
        XCTAssertTrue(
            app.navigationBars["New Connection"].waitForExistence(
                timeout: Self.waitTimeout
            )
        )

        let protocolPicker = app.segmentedControls["connectionEditor.scheme"]
        XCTAssertTrue(protocolPicker.waitForExistence(timeout: Self.waitTimeout))
        XCTAssertTrue(protocolPicker.buttons["HTTP"].isSelected)

        protocolPicker.buttons["HTTPS"].tap()
        let alert = app.alerts["Use HTTPS?"]
        XCTAssertTrue(alert.waitForExistence(timeout: Self.waitTimeout))
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(protocolPicker.buttons["HTTP"].isSelected)

        protocolPicker.buttons["HTTPS"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: Self.waitTimeout))
        alert.buttons["Use HTTPS"].tap()
        XCTAssertTrue(protocolPicker.buttons["HTTPS"].isSelected)
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
        launchApp(pro: true)
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

        shareExtension.tap()
        let sharedItemCount = safari.staticTexts["upload.queue.count"]
        XCTAssertTrue(
            sharedItemCount.waitForExistence(timeout: Self.waitTimeout),
            safari.debugDescription
        )
        XCTAssertEqual(sharedItemCount.label, "1 item")
    }

    func testReadmeAddItemsMenuAndSeededQueueScreenshots() {
        launchApp(pro: true)
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
        launchApp(seedConnection: true, pro: true)

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
        launchApp(seedConnection: true, pro: true)

        let connectionStatusButton = app.buttons["Test Connection"]
        XCTAssertTrue(
            connectionStatusButton.waitForExistence(
                timeout: Self.waitTimeout
            ),
            app.debugDescription
        )
        XCTAssertEqual(
            connectionStatusButton.value as? String,
            "Verified"
        )

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
        launchApp(
            seedConnection: true,
            seedUploadQueue: true,
            pro: true
        )

        let queuedItemCount = app.staticTexts["upload.queue.count"]
        XCTAssertTrue(
            queuedItemCount.waitForExistence(timeout: Self.waitTimeout),
            app.debugDescription
        )
        XCTAssertEqual(queuedItemCount.label, "3 items")

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

    func testSendIsDisabledForUnverifiedConnection() {
        launchApp(
            seedUploadQueue: true,
            seedUnverifiedConnection: true
        )

        let sendButton = app.buttons["upload.send"]
        XCTAssertTrue(
            sendButton.waitForExistence(timeout: Self.waitTimeout),
            app.debugDescription
        )
        XCTAssertEqual(sendButton.label, "Send to Eagle")
        XCTAssertFalse(sendButton.isEnabled)

        let connectionStatusButton = app.buttons["Test Connection"]
        XCTAssertEqual(
            connectionStatusButton.value as? String,
            "Not verified"
        )
        XCTAssertFalse(
            app.staticTexts[
                "Test this connection and save it before uploading."
            ].exists
        )
    }

    func testConnectionListIsDisabledWhileTesting() {
        launchApp(
            seedConnection: true,
            delayedConnectionTest: true
        )

        let connectionStatusButton = app.buttons["Test Connection"]
        XCTAssertTrue(
            connectionStatusButton.waitForExistence(timeout: Self.waitTimeout),
            app.debugDescription
        )
        connectionStatusButton.tap()
        waitForValue(
            "Testing",
            on: connectionStatusButton,
            timeout: Self.waitTimeout
        )

        let connectionButton = app.buttons["upload.connection.open"]
        XCTAssertTrue(
            connectionButton.waitForExistence(timeout: Self.waitTimeout),
            app.debugDescription
        )
        XCTAssertFalse(connectionButton.isEnabled)
        XCTAssertFalse(connectionStatusButton.isEnabled)

        connectionButton.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).tap()
        XCTAssertFalse(
            app.navigationBars["Connections"].waitForExistence(timeout: 1)
        )
    }

    func testSelectingConnectionReturnsDirectlyToTestingState() {
        launchApp(
            seedConnection: true,
            delayedConnectionTest: true
        )

        openConnections()
        let selectButton = app.buttons["connections.select"]
        XCTAssertTrue(
            selectButton.waitForExistence(timeout: Self.waitTimeout),
            app.debugDescription
        )
        XCTAssertTrue(selectButton.isEnabled)
        selectButton.tap()

        let connectionStatusButton = app.buttons["Test Connection"]
        XCTAssertTrue(
            connectionStatusButton.waitForExistence(timeout: Self.waitTimeout),
            app.debugDescription
        )
        XCTAssertEqual(
            connectionStatusButton.value as? String,
            "Testing"
        )
        XCTAssertFalse(connectionStatusButton.isEnabled)
        XCTAssertFalse(app.buttons["upload.connection.open"].isEnabled)
    }

    func testSendRemainsEnabledForLibraryMismatchWarning() {
        launchApp(
            seedConnection: true,
            seedUploadQueue: true,
            seedLibraryMismatch: true
        )

        let sendButton = app.buttons["upload.send"]
        XCTAssertTrue(
            sendButton.waitForExistence(timeout: Self.waitTimeout),
            app.debugDescription
        )
        let connectionStatus = app.buttons["Test Connection"].value as? String
        XCTAssertTrue(
            connectionStatus?.hasPrefix("Warning: Library mismatch.") == true,
            connectionStatus ?? app.debugDescription
        )
        XCTAssertTrue(sendButton.isEnabled, app.debugDescription)
    }

    func testSendIsDisabledForFailedConnection() {
        launchApp(
            seedConnection: true,
            seedUploadQueue: true,
            seedConnectionFailure: true
        )

        let sendButton = app.buttons["upload.send"]
        XCTAssertTrue(
            sendButton.waitForExistence(timeout: Self.waitTimeout),
            app.debugDescription
        )
        XCTAssertEqual(sendButton.label, "Couldn’t Send")
        XCTAssertFalse(sendButton.isEnabled)

        let connectionStatusButton = app.buttons["Test Connection"]
        XCTAssertEqual(
            connectionStatusButton.value as? String,
            "Failed: Couldn’t connect to Eagle."
        )

        let operationMessage = app.staticTexts["upload.operationMessage.text"]
        XCTAssertTrue(
            operationMessage.waitForExistence(timeout: Self.waitTimeout),
            app.debugDescription
        )
        XCTAssertEqual(operationMessage.label, "Couldn’t connect to Eagle.")
        let connectionFailure = app.staticTexts["upload.connection.failure"]
        XCTAssertTrue(
            connectionFailure.waitForExistence(timeout: Self.waitTimeout),
            app.debugDescription
        )
        XCTAssertEqual(connectionFailure.label, "Couldn’t connect to Eagle.")
        XCTAssertEqual(
            operationMessage.frame.midX,
            app.frame.midX,
            accuracy: 2
        )
        XCTAssertTrue(app.buttons["upload.operationMessage.dismiss"].exists)
        attachScreenshot(named: "send-connection-failure")

        app.buttons["upload.operationMessage.dismiss"].tap()
        XCTAssertTrue(
            operationMessage.waitForNonExistence(timeout: Self.waitTimeout)
        )
        XCTAssertTrue(connectionFailure.exists)
        XCTAssertEqual(connectionFailure.label, "Couldn’t connect to Eagle.")
        XCTAssertEqual(
            connectionStatusButton.value as? String,
            "Failed: Couldn’t connect to Eagle."
        )
        waitForLabel(
            "Send to Eagle",
            on: sendButton,
            timeout: Self.waitTimeout
        )
        XCTAssertFalse(sendButton.isEnabled)
    }

    func testRecoveredConnectionClearsSendFailureFeedback() {
        launchApp(
            seedConnection: true,
            seedUploadQueue: true,
            seedRecoveredSendConnection: true
        )

        let sendButton = app.buttons["upload.send"]
        XCTAssertTrue(
            sendButton.waitForExistence(timeout: Self.waitTimeout),
            app.debugDescription
        )
        XCTAssertEqual(sendButton.label, "Send to Eagle")
        XCTAssertTrue(sendButton.isEnabled)
        XCTAssertEqual(
            app.buttons["Test Connection"].value as? String,
            "Verified"
        )
        XCTAssertFalse(
            app.staticTexts["upload.operationMessage.text"].exists
        )
    }

    func testReadmeLibraryMismatchScreenshot() {
        launchApp(
            seedConnection: true,
            seedLibraryMismatch: true,
            pro: true
        )

        let warning = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Library mismatch.")
        ).firstMatch
        XCTAssertTrue(
            warning.waitForExistence(timeout: Self.waitTimeout),
            app.debugDescription
        )
        XCTAssertTrue(warning.label.contains("Design"))
        XCTAssertTrue(warning.label.contains("Reference"))
        attachScreenshot(named: "library-mismatch")
    }

    func testReadmeUploadLibraryMismatchConfirmationScreenshot() {
        launchApp(
            seedConnection: true,
            seedUploadQueue: true,
            seedUploadLibraryMismatchDialog: true,
            pro: true
        )

        let alert = app.alerts["Library Mismatch"]
        XCTAssertTrue(
            alert.waitForExistence(timeout: Self.waitTimeout),
            app.debugDescription
        )
        XCTAssertTrue(alert.buttons["Cancel"].exists)
        XCTAssertTrue(alert.buttons["Send"].exists)
        let message = alert.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Expected")
        ).firstMatch
        XCTAssertTrue(message.exists)
        XCTAssertTrue(message.label.contains("Design"))
        XCTAssertTrue(message.label.contains("Reference"))
        XCTAssertFalse(
            message.label.localizedCaseInsensitiveContains(
                "Library mismatch."
            )
        )
        attachScreenshot(named: "library-mismatch-send-confirmation")
    }

    func testTagSelectionSupportsSuggestionsAndNewTags() {
        launchApp(seedConnection: true, seedTags: true, pro: true)

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
        let initialInboxRows = app.buttons.matching(
            identifier: "tags.suggestion.inbox"
        )
        XCTAssertEqual(initialInboxRows.count, 2)
        for index in 0..<initialInboxRows.count {
            XCTAssertTrue(
                initialInboxRows.element(boundBy: index).label.contains(
                    "42 items"
                )
            )
        }
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
        XCTAssertTrue(
            app.buttons["tags.selected.inbox"].label.contains("42 items")
        )
        let inboxCopies = app.buttons.matching(
            identifier: "tags.suggestion.inbox"
        )
        XCTAssertEqual(inboxCopies.count, 0)
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
        attachScreenshot(named: "tags-selected")
        let selectButton = app.buttons["tags.select"]
        XCTAssertTrue(
            selectButton.waitForExistence(timeout: Self.waitTimeout)
        )
        selectButton.tap()

        XCTAssertTrue(tagsButton.waitForExistence(timeout: Self.waitTimeout))
        XCTAssertEqual(tagsButton.value as? String, "2 tags")
    }

    func testFolderSelectionShowsSelectedRecentAndAllSections() {
        launchApp(seedConnection: true, seedFolders: true, pro: true)

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
        XCTAssertEqual(inboxCopies.count, 1)
        XCTAssertEqual(
            inboxCopies.element(boundBy: 0).value as? String,
            "Selected"
        )
        XCTAssertTrue(inboxCopies.element(boundBy: 0).label.contains("42 items"))
        attachScreenshot(named: "folders-selected-recent-all")

        let referenceRows = app.buttons.matching(
            identifier: "folders.row.folder-reference"
        )
        XCTAssertEqual(referenceRows.count, 2)
        referenceRows.element(boundBy: 0).tap()

        let archiveRow = app.buttons["folders.row.folder-archive"]
        XCTAssertTrue(archiveRow.waitForExistence(timeout: Self.waitTimeout))
        archiveRow.tap()
        XCTAssertFalse(
            app.staticTexts["folders.section.all"].waitForExistence(
                timeout: 1
            )
        )

        inboxCopies.element(boundBy: 0).tap()
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

    private func waitForValue(
        _ value: String,
        on element: XCUIElement,
        timeout: TimeInterval
    ) {
        let expectation = expectation(
            for: NSPredicate(format: "value == %@", value),
            evaluatedWith: element
        )
        wait(for: [expectation], timeout: timeout)
    }

    private func launchApp(
        seedConnection: Bool = false,
        seedUploadQueue: Bool = false,
        seedTags: Bool = false,
        seedFolders: Bool = false,
        seedLibraryMismatch: Bool = false,
        seedUploadLibraryMismatchDialog: Bool = false,
        seedUnverifiedConnection: Bool = false,
        seedConnectionFailure: Bool = false,
        seedRecoveredSendConnection: Bool = false,
        delayedConnectionTest: Bool = false,
        storeScreenshot: Bool = false,
        pro: Bool = false,
        language: String = "en",
        locale: String = "en_US"
    ) {
        XCUIDevice.shared.press(.home)
        app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale
        ]
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
        if seedLibraryMismatch {
            app.launchArguments.append("--ui-testing-seeded-library-mismatch")
        }
        if seedUploadLibraryMismatchDialog {
            app.launchArguments.append(
                "--ui-testing-seeded-upload-library-mismatch-dialog"
            )
        }
        if seedUnverifiedConnection {
            app.launchArguments.append(
                "--ui-testing-seeded-unverified-connection"
            )
        }
        if seedConnectionFailure {
            app.launchArguments.append(
                "--ui-testing-seeded-connection-failure"
            )
        }
        if seedRecoveredSendConnection {
            app.launchArguments.append(
                "--ui-testing-seeded-recovered-send-connection"
            )
        }
        if delayedConnectionTest {
            app.launchArguments.append(
                "--ui-testing-delayed-connection-test"
            )
        }
        if storeScreenshot {
            app.launchArguments.append("--ui-testing-store-screenshot")
        }
        if pro {
            app.launchArguments.append("--ui-testing-pro")
        }
        app.launch()
    }

    private func openConnections(expectedTitle: String = "Connections") {
        let button = app.buttons["upload.connection.open"]
        XCTAssertTrue(button.waitForExistence(timeout: Self.waitTimeout))
        button.tap()
        XCTAssertTrue(
            app.navigationBars[expectedTitle].waitForExistence(
                timeout: Self.waitTimeout
            )
        )
    }

    private func openSeededConnectionEditor(
        captureScreenshots: Bool = false
    ) {
        launchApp(seedConnection: true, pro: captureScreenshots)
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
