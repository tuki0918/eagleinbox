import SwiftUI
import UserNotifications
import UIKit

final class AppNotificationDelegate: NSObject,
    UIApplicationDelegate,
    UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

@main
struct EagleInboxApp: App {
    @UIApplicationDelegateAdaptor(AppNotificationDelegate.self)
    private var notificationDelegate
    @StateObject private var model: AppModel
    @StateObject private var purchases: ProPurchaseManager

    init() {
        let dependencies = Self.makeDependencies()
        _model = StateObject(wrappedValue: dependencies.model)
        _purchases = StateObject(wrappedValue: dependencies.purchases)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(purchases)
                .preferredColorScheme(.light)
                .task {
                    await purchases.prepare()
                }
        }
    }

    @MainActor
    private static func makeDependencies() -> (
        model: AppModel,
        purchases: ProPurchaseManager
    ) {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing") {
            let suiteName = "com.tuki0918.EagleInbox.UITests"
            UserDefaults.standard.set(false, forKey: "upload.metadata-expanded")
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)

            let settingsStore = SharedSettingsStore(
                defaultsSuiteName: suiteName,
                tokenService: "com.tuki0918.EagleInbox.UITests.connections"
            )
            let entitlementStore = ProEntitlementStore(
                defaultsSuiteName: suiteName
            )
            entitlementStore.save(
                isPro: arguments.contains("--ui-testing-pro")
            )
            let snapshot: ConnectionSettingsSnapshot
            if arguments.contains("--ui-testing-seeded-unverified-connection") {
                let profile = EagleConnectionProfile(
                    id: UUID(uuidString: "3B112B34-6C80-44E8-B7D7-0A1C7399A5A7")!,
                    name: "Studio",
                    connection: EagleConnection(
                        host: "192.168.0.100",
                        port: 41595,
                        token: "demo-api-token"
                    ),
                    expectedLibraryName: "Design"
                )
                snapshot = ConnectionSettingsSnapshot(
                    profiles: [profile],
                    selectedProfileID: profile.id
                )
            } else if arguments.contains("--ui-testing-seeded-connection") {
                let profile = EagleConnectionProfile(
                    id: UUID(uuidString: "3B112B34-6C80-44E8-B7D7-0A1C7399A5A7")!,
                    name: "Studio",
                    connection: EagleConnection(
                        host: "192.168.0.100",
                        port: 41595,
                        token: "demo-api-token"
                    ),
                    expectedLibraryName: "Design",
                    libraryName: "Design"
                )
                snapshot = ConnectionSettingsSnapshot(
                    profiles: [profile],
                    selectedProfileID: profile.id
                )
            } else {
                snapshot = ConnectionSettingsSnapshot(
                    profiles: [],
                    selectedProfileID: nil
                )
            }
            _ = try? settingsStore.replaceAllForUITesting(snapshot)
            let model = AppModel(
                settingsStore: settingsStore,
                entitlementStore: entitlementStore,
                allowsAutomaticConnectionRefresh: false
            )
            if arguments.contains("--ui-testing-seeded-unverified-connection") {
                model.seedPinnedUnverifiedConnectionForUITesting(
                    expectedLibraryName: "Design"
                )
            }
            if arguments.contains("--ui-testing-seeded-connection-failure") {
                model.seedConnectionFailureForUITesting(
                    String(localized: "Couldn’t connect to Eagle.")
                )
            }
            if arguments.contains(
                "--ui-testing-seeded-recovered-send-connection"
            ) {
                model.seedRecoveredSendConnectionForUITesting(
                    String(localized: "Couldn’t connect to Eagle."),
                    expectedLibraryName: "Design"
                )
            }
            if arguments.contains("--ui-testing-seeded-library-mismatch") {
                model.seedLibraryMismatchForUITesting(
                    expectedLibraryName: "Design",
                    actualLibraryName: "Reference"
                )
            }
            if arguments.contains("--ui-testing-seeded-upload-queue") {
                model.queue = Self.makeScreenshotUploadQueue()
            }
            if arguments.contains(
                "--ui-testing-seeded-upload-library-mismatch-dialog"
            ) {
                model.seedUploadLibraryMismatchConfirmationForUITesting(
                    expectedLibraryName: "Design",
                    actualLibraryName: "Reference"
                )
            }
            return (
                model,
                ProPurchaseManager(
                    entitlementStore: entitlementStore,
                    isStoreKitEnabled: false,
                    purchaseButtonTitleOverride: arguments.contains(
                        "--ui-testing-store-screenshot"
                    ) ? String(localized: "Unlock Pro") : nil
                )
            )
        }
#endif
        let entitlementStore = ProEntitlementStore()
        return (
            AppModel(entitlementStore: entitlementStore),
            ProPurchaseManager(entitlementStore: entitlementStore)
        )
    }

#if DEBUG
    @MainActor
    private static func makeScreenshotUploadQueue() -> [QueuedUpload] {
        let photos: [QueuedUpload] = ["IMG_0001", "IMG_0111"].compactMap {
            name -> QueuedUpload? in
            guard let url = Bundle.main.url(
                forResource: name,
                withExtension: "jpg"
            ) else {
                assertionFailure("Missing README screenshot fixture: \(name).jpg")
                return nil
            }
            return QueuedUpload(
                name: name,
                source: .file(url: url, mimeType: "image/jpeg")
            )
        }
        let bookmark = QueuedUpload(
            name: "Example Domain",
            source: .bookmark(URL(string: "https://example.com/")!)
        )
        return photos + [bookmark]
    }
#endif
}
