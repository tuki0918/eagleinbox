import SwiftUI
import UserNotifications
import UIKit

final class ShareViewController: UIViewController, UNUserNotificationCenterDelegate {
    override func viewDidLoad() {
        super.viewDidLoad()
        let canvasBackgroundColor = UIColor(
            red: 242.0 / 255.0,
            green: 242.0 / 255.0,
            blue: 247.0 / 255.0,
            alpha: 1
        )
        overrideUserInterfaceStyle = .light
        view.backgroundColor = canvasBackgroundColor
        UNUserNotificationCenter.current().delegate = self

        let model = ShareUploadViewModel(extensionContext: extensionContext)
        let hostingController = UIHostingController(
            rootView: ShareUploadView(model: model)
                .preferredColorScheme(.light)
        )
        hostingController.overrideUserInterfaceStyle = .light
        hostingController.view.backgroundColor = canvasBackgroundColor

        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hostingController.didMove(toParent: self)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
