import Foundation
import UserNotifications

enum UploadNotificationResult: Equatable, Sendable {
    case success(sent: Int)
    case partial(sent: Int, failed: Int)
    case failure(failed: Int)

    static func completed(sent: Int, failed: Int) -> UploadNotificationResult? {
        guard sent > 0 || failed > 0 else { return nil }
        if failed == 0 {
            return .success(sent: sent)
        }
        if sent == 0 {
            return .failure(failed: failed)
        }
        return .partial(sent: sent, failed: failed)
    }

    var title: String {
        switch self {
        case .success:
            return "Sent to Eagle"
        case .partial:
            return "Some Items Couldn’t Send"
        case .failure:
            return "Couldn’t Send to Eagle"
        }
    }

    var body: String {
        switch self {
        case let .success(sent):
            return "\(sent) item\(sent == 1 ? " was" : "s were") sent."
        case let .partial(sent, failed):
            return "\(sent) sent, \(failed) failed. Open Eagle Inbox for details."
        case let .failure(failed):
            return "\(failed) item\(failed == 1 ? "" : "s") couldn’t be sent. Open Eagle Inbox for details."
        }
    }
}

protocol UploadNotifying {
    func prepareAuthorization() async
    func post(_ result: UploadNotificationResult) async
}

struct SystemUploadNotifier: UploadNotifying {
    private let notificationIdentifier = "com.tuki0918.EagleInbox.upload-result"

    func prepareAuthorization() async {
        guard !Task.isCancelled else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard !Task.isCancelled,
              settings.authorizationStatus == .notDetermined else {
            return
        }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func post(_ result: UploadNotificationResult) async {
        guard !Task.isCancelled else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard !Task.isCancelled else { return }
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        case .notDetermined, .denied:
            return
        @unknown default:
            return
        }

        let content = UNMutableNotificationContent()
        content.title = result.title
        content.body = result.body
        content.sound = .default

        center.removePendingNotificationRequests(
            withIdentifiers: [notificationIdentifier]
        )
        center.removeDeliveredNotifications(
            withIdentifiers: [notificationIdentifier]
        )

        let request = UNNotificationRequest(
            identifier: notificationIdentifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: 0.1,
                repeats: false
            )
        )
        guard !Task.isCancelled else { return }
        try? await center.add(request)

        if Task.isCancelled {
            center.removePendingNotificationRequests(
                withIdentifiers: [notificationIdentifier]
            )
            center.removeDeliveredNotifications(
                withIdentifiers: [notificationIdentifier]
            )
        }
    }
}
