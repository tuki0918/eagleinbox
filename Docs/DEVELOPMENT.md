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

`EagleInboxUITests` verifies navigation from Connections to the Connection Editor, text entry on the first tap, connection-test cancellation during its start delay, confirmation before discarding unsaved changes, appearance in Safari's share menu, and the deterministic states used for README screenshots. It uses dedicated `UserDefaults` and Keychain namespaces and does not access saved user connections or a real Eagle server.

```sh
xcodebuild test \
  -project EagleInbox.xcodeproj \
  -scheme EagleInbox \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  -derivedDataPath /tmp/EagleInboxUITestsDerived \
  -only-testing:EagleInboxUITests
```

## Manual QA

At minimum, verify the following on a physical device or through TestFlight:

- Local Network behavior before and after permission is granted
- Notifications when allowed or denied, and while the app is in the foreground
- Adding, editing, deleting, and selecting connections, including confirmation before discarding unsaved changes
- Launch, resume, pull-to-refresh, and revalidation after switching connections
- Successful uploads, partial failures, the five-second timeout, and an incorrect API token
- Canceling or approving a one-time upload when the library does not match
- Canceling an upload in progress, retaining unsent items, and retrying failed items
- Photos, files, URLs, and the share extension
- Connection sharing between the main app and share extension
- iPad in iPhone compatibility mode
- Running as a Designed for iPhone app on an Apple Silicon Mac

## Release

Before submitting a release:

- [ ] Keep `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in sync for the main app and share extension
- [ ] Increment the build number for every upload
- [ ] Verify the distribution certificate, provisioning profiles, App Group, and Keychain access group for the production team
- [ ] Test both the main app and share extension through TestFlight
- [ ] Make the App Privacy answers in App Store Connect match the implementation
- [ ] Prepare the Privacy Policy URL, Support URL, description, screenshots, and Review Notes
- [ ] Add a Privacy Policy link in an easy-to-find location within the app
- [ ] Enable [`Make this app available`](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/manage-availability-of-iphone-and-ipad-apps-on-macs-with-apple-silicon) for Apple Silicon Macs under `Pricing and Availability` in App Store Connect
- [ ] Run Archive, Validate App, and Upload in Xcode Organizer
- [ ] Choose a license before making the repository public

The Review Notes should explain that Eagle 4.0 Build 21 or later must be running on another device, that both devices must be on the same local network, that some connections require an API token, and why the app validates the destination library.

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
