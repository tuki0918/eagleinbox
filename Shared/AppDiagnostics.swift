import Foundation
import OSLog

enum AppDiagnostics {
    enum Component: String {
        case mainApp = "main-app"
        case shareExtension = "share-extension"
        case shortcut
    }

    enum StoreKitOperation: String {
        case productLoad = "product-load"
        case purchase
        case restore
        case transactionUpdate = "transaction-update"
    }

    private static let subsystem = "com.tuki0918.EagleInbox"
    private static let connectionLogger = Logger(
        subsystem: subsystem,
        category: "connection"
    )
    private static let uploadLogger = Logger(
        subsystem: subsystem,
        category: "upload"
    )
    private static let settingsLogger = Logger(
        subsystem: subsystem,
        category: "settings"
    )
    private static let shareLogger = Logger(
        subsystem: subsystem,
        category: "share-extension"
    )
    private static let storeKitLogger = Logger(
        subsystem: subsystem,
        category: "storekit"
    )

    static func connectionTestFailed(
        in component: Component,
        error: Error
    ) {
        connectionLogger.error(
            "Connection test failed: component=\(component.rawValue, privacy: .public) code=\(errorCode(for: error), privacy: .public)"
        )
    }

    static func settingsMutationFailed(
        in component: Component,
        error: Error
    ) {
        if let settingsError = error as? SharedSettingsMutationError {
            switch settingsError {
            case .profileLimitReached, .selectionNotAllowed:
                return
            case .alreadyExists, .changedOrRemoved:
                break
            }
        }
        settingsLogger.error(
            "Settings mutation failed: component=\(component.rawValue, privacy: .public) code=\(errorCode(for: error), privacy: .public)"
        )
    }

    static func uploadVerificationFailed(
        in component: Component,
        error: Error
    ) {
        uploadLogger.error(
            "Upload verification failed: component=\(component.rawValue, privacy: .public) code=\(errorCode(for: error), privacy: .public)"
        )
    }

    static func uploadItemFailed(
        in component: Component,
        error: Error
    ) {
        uploadLogger.error(
            "Upload item failed: component=\(component.rawValue, privacy: .public) code=\(errorCode(for: error), privacy: .public)"
        )
    }

    static func uploadCompleted(
        in component: Component,
        sent: Int,
        failed: Int
    ) {
        uploadLogger.notice(
            "Upload completed: component=\(component.rawValue, privacy: .public) sent=\(sent, privacy: .public) failed=\(failed, privacy: .public)"
        )
    }

    static func shareAttachmentLoadFailed(count: Int) {
        shareLogger.error(
            "Share attachments failed to load: count=\(count, privacy: .public)"
        )
    }

    static func storeKitFailed(
        _ operation: StoreKitOperation,
        error: Error? = nil
    ) {
        storeKitLogger.error(
            "StoreKit operation failed: operation=\(operation.rawValue, privacy: .public) code=\(error.map(errorCode(for:)) ?? "unknown", privacy: .public)"
        )
    }

    private static func errorCode(for error: Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }
        if let clientError = error as? EagleClientError {
            switch clientError {
            case .invalidConnection:
                return "client.invalid-connection"
            case .invalidBookmarkURL:
                return "client.invalid-bookmark-url"
            case .invalidResponse:
                return "client.invalid-response"
            case .libraryNotPinned:
                return "client.library-not-pinned"
            case .connectionChangedDuringVerification:
                return "client.connection-changed"
            case .connectionTestTimedOut:
                return "client.connection-timeout"
            case let .server(statusCode, _):
                return "client.server.\(statusCode)"
            case .api:
                return "client.api"
            case .cannotCreateUploadBody:
                return "client.upload-body"
            case let .keychain(status):
                return "client.keychain.\(status)"
            }
        }
        if let urlError = error as? URLError {
            return "url.\(urlError.code.rawValue)"
        }
        if let settingsError = error as? SharedSettingsMutationError {
            switch settingsError {
            case .alreadyExists:
                return "settings.already-exists"
            case .changedOrRemoved:
                return "settings.changed-or-removed"
            case .profileLimitReached:
                return "settings.profile-limit"
            case .selectionNotAllowed:
                return "settings.selection-not-allowed"
            }
        }

        let nsError = error as NSError
        switch nsError.domain {
        case NSCocoaErrorDomain:
            return "cocoa.\(nsError.code)"
        case NSURLErrorDomain:
            return "url.\(nsError.code)"
        default:
            return "other"
        }
    }
}
