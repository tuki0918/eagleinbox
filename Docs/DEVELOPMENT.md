# Development

This document covers how to build, test, and release Eagle Inbox. See [ARCHITECTURE.md](./ARCHITECTURE.md) for the implementation structure.

## Development Environment

- Xcode 26.2
- iOS 17 or later
- Eagle 4.0 Build 21 or later (when verifying connections and uploads on a physical device)

## Setup

1. Open `EagleInbox.xcodeproj` in Xcode.
2. Set the Signing Team for `EagleInbox` and `EagleInboxShare` to the same Apple Developer team.
3. Confirm that App Groups and Keychain Sharing match for both targets.
4. Run the `EagleInbox` scheme on a physical iPhone or in Simulator. The share extension is built at the same time and embedded in the main app.

### Eagle Inbox Pro

Create a non-consumable in-app purchase in App Store Connect with product ID `com.tuki0918.EagleInbox.pro`. Configure its display name, description, availability, and price there; the app always displays StoreKit's localized price rather than a hard-coded amount.

For local purchase testing, create or synchronize a StoreKit configuration in Xcode with the same product ID and select it under Scheme → Run → Options → StoreKit Configuration. Test the free state, successful purchase, cancellation, pending approval, restoration, revocation, and product-load failure before using Sandbox or TestFlight.

## Localization

English is the source language and Japanese is the supported translation. iOS selects the system language by default; users can override it for Eagle Inbox under Settings → Apps → Eagle Inbox → Language.

- `Shared/Localizable.xcstrings` contains app and share-extension UI, model, error, notification, and App Intent strings. Keep it in both targets.
- `EagleInbox/InfoPlist.xcstrings` and `EagleInboxShare/InfoPlist.xcstrings` contain target-specific display names and Local Network permission descriptions.
- `EagleInbox/AppShortcuts.xcstrings` contains the localized Siri phrases for App Shortcuts.
- SwiftUI string literals are extracted automatically. A user-facing value produced as `String`, including computed labels and errors, must use `String(localized:)` so it is extracted and localized before display.

When adding a user-facing string, verify both English and Japanese in the main app and share extension. Preserve format placeholders and do not localize user content, server responses, URLs, MIME types, accessibility identifiers, or SF Symbol names.

### Identifiers

To distribute the app under a different Developer Team or Bundle ID, update the following values as a single set.

| Type | Current value | Main locations |
| --- | --- | --- |
| Main app Bundle ID | `com.tuki0918.EagleInbox` | Project build settings |
| Share extension Bundle ID | `com.tuki0918.EagleInbox.Share` | Project build settings |
| App Group | `group.com.tuki0918.EagleInbox` | Both entitlements files and `Shared/SharedIdentifiers.swift` |
| Keychain access group | `com.tuki0918.EagleInbox.shared` | Both entitlements files and both `Info.plist` files |
| Keychain service | `com.tuki0918.EagleInbox.connections` | `Shared/SharedIdentifiers.swift` |

When migrating an existing installation after changing identifiers, plan compatibility and data migration for the previous Keychain and `UserDefaults` values separately.

## Build

Debug Simulator build:

```sh
xcodebuild \
  -project EagleInbox.xcodeproj \
  -scheme EagleInbox \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  -derivedDataPath /tmp/EagleInboxDerivedDebug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Unsigned Release build:

```sh
xcodebuild \
  -project EagleInbox.xcodeproj \
  -scheme EagleInbox \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/EagleInboxDerivedRelease \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Tests

### Core Smoke Test

`Tests/CoreSmoke.swift` is not an XCTest target. It is a lightweight test that compiles and runs shared logic directly on macOS.

```sh
swiftc \
  -module-cache-path /tmp/eagle-inbox-core-smoke-module-cache \
  -o /tmp/eagle-inbox-core-smoke \
  Tests/CoreSmoke.swift \
  Shared/SharedIdentifiers.swift \
  Shared/ProEntitlementStore.swift \
  Shared/SharedSettingsStore.swift \
  Shared/EagleConnection.swift \
  Shared/ConnectionEditorDraft.swift \
  Shared/EagleClientError.swift \
  Shared/EagleUploadModels.swift \
  Shared/Base64JSONBodyWriter.swift \
  Shared/EagleAPIClient.swift \
  Shared/MediaFileSupport.swift \
  Shared/EagleTag.swift \
  Shared/SystemUploadNotifier.swift

/tmp/eagle-inbox-core-smoke
```

### UI Tests

`EagleInboxUITests` verifies navigation from Connections to the Connection Editor, the Pro upgrade for a second connection, text entry on the first tap, connection-test cancellation during its start delay, confirmation before discarding unsaved changes, appearance in Safari's share menu, and the deterministic states used for README screenshots. It uses dedicated `UserDefaults` and Keychain namespaces, forces a free entitlement without contacting StoreKit, and does not access saved user connections or a real Eagle server.

```sh
xcodebuild test \
  -project EagleInbox.xcodeproj \
  -scheme EagleInbox \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  -derivedDataPath /tmp/EagleInboxUITestsDerived \
  -testLanguage en \
  -testRegion US \
  -only-testing:EagleInboxUITests
```

## Manual QA

At minimum, verify the following on a physical device or through TestFlight:

- Local Network behavior before and after permission is granted
- Notifications when allowed or denied, and while the app is in the foreground
- Adding, editing, deleting, and selecting HTTP and HTTPS connections, including the HTTPS warning and confirmation before discarding unsaved changes
- Launch, resume, pull-to-refresh, and revalidation after switching connections
- Successful uploads, partial failures, the five-second timeout, and an incorrect API token
- Canceling or approving a one-time upload when the library does not match
- Canceling an upload in progress, retaining unsent items, and retrying failed items
- Per-item progress for a large video, including preparing, uploading, and finishing states
- Photos, files, URLs, and the share extension
- All five Eagle Inbox actions in Apple Shortcuts: simple file/URL sends without metadata fields; both `with Tags, Annotation` actions with neither optional value, tags only, an annotation only, and both values; and `Split Text into Tags` with comma-separated, newline-separated, blank, and duplicate values
- An OCR workflow that connects extracted text to `Split Text into Tags`, its output to a `with Tags, Annotation` action, and the original image to the file input; also verify existing saved simple shortcuts and saved `with Tags` shortcuts from the previous version, Japanese labels, and an Action Button workflow on a physical iPhone
- Connection sharing between the main app and share extension
- Free access to one connection and all direct-upload, share-extension, batch, folder, annotation, and tag features
- The second connection opening the Pro upgrade in the main app and a functional Pro-required message in the share extension
- A successful Pro purchase and restore unlocking unlimited connections without deleting or rewriting existing connection records
- Cancellation, pending approval, relaunch, offline launch, refund, and revocation returning to a consistent entitlement state
- All five Shortcuts failing before any file or network work in the free state, showing the localized Pro-required error instead of an internal error type, and running after Pro is unlocked
- iPad in iPhone compatibility mode
- Running as a Designed for iPhone app on an Apple Silicon Mac

## Release

Before submitting a release:

- [ ] Keep `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in sync for the main app and share extension
- [ ] Increment the build number for every upload
- [ ] Verify the distribution certificate, provisioning profiles, App Group, and Keychain access group for the production team
- [ ] Test both the main app and share extension through TestFlight
- [ ] Create the non-consumable `com.tuki0918.EagleInbox.pro`, complete its review metadata, and submit it with the app version
- [ ] Verify that screenshots and the description mark Shortcuts, Action Button, and unlimited connections as requiring Eagle Inbox Pro
- [ ] Verify purchase, restoration, pending approval, and revoked-entitlement behavior with the production product identifier
- [ ] Make the App Privacy answers in App Store Connect match the implementation
- [ ] Prepare the Privacy Policy URL, Support URL, description, screenshots, and Review Notes
- [ ] Add a Privacy Policy link in an easy-to-find location within the app
- [ ] Enable [`Make this app available`](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/manage-availability-of-iphone-and-ipad-apps-on-macs-with-apple-silicon) for Apple Silicon Macs under `Pricing and Availability` in App Store Connect
- [ ] Run Archive, Validate App, and Upload in Xcode Organizer
- [ ] Choose a license before making the repository public

The Review Notes should explain that Eagle 4.0 Build 21 or later must be running on another device, that both devices must be on the same local network, that some connections require an API token, and why the app validates the destination library. Also explain that Pro unlocks only Eagle Inbox's own upload automation and does not sell or alter the operating system's Shortcuts or Action Button functionality.

### Screenshots

Store README images in `Docs/Screenshots/`. Capture the current UI and use the placeholder host `192.168.0.100` and API token `demo-api-token` in the Connection Editor. Never include real credentials in screenshots or Git history.

The deterministic upload-queue screenshot uses optimized photos in `EagleInbox/ScreenshotFixtures/`. They are bundled for Debug UI tests and excluded from Release builds with `EXCLUDED_SOURCE_FILE_NAMES`. UI test launch states also produce the `Library mismatch` warning and the confirmation shown after tapping `Send to Eagle`, without contacting a real Eagle server.

## Troubleshooting

### `Couldn’t connect to Eagle.`

- Confirm that Eagle is running
- Confirm that the device and Eagle are on the same local network
- Check the host name or IP address, port, and API token
- Confirm that Local Network permission is enabled
- Confirm that the firewall is not blocking TCP port 41595

### `Library mismatch.`

The library stored with the connection differs from the library currently open in Eagle. Open the expected library, or run `Test Connection` in the Connection Editor to update the stored library. Selecting `Send` in the upload confirmation sends to the current library once without changing the stored value.

### Notifications Do Not Appear

Check the iOS notification settings. Uploads still work when notifications are disabled. A canceled upload does not schedule a result notification.

## API References

- [Eagle Web API v2](https://developer.eagle.cool/web-api)
- [Item API](https://developer.eagle.cool/web-api/api/item)
