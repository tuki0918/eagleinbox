import Foundation

enum EagleClientError: LocalizedError {
    case invalidConnection
    case invalidBookmarkURL
    case invalidResponse
    case libraryNotPinned
    case connectionChangedDuringVerification
    case connectionTestTimedOut
    case server(statusCode: Int, message: String)
    case api(message: String)
    case cannotCreateUploadBody
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidConnection:
            return "Check the protocol, host, port, and API token."
        case .invalidBookmarkURL:
            return "Enter a valid HTTP or HTTPS URL."
        case .invalidResponse:
            return "Eagle returned an unreadable response."
        case .libraryNotPinned:
            return "Test this connection and save it before uploading."
        case .connectionChangedDuringVerification:
            return "The connection changed while it was being verified. Try again."
        case .connectionTestTimedOut:
            return "Couldn’t connect to Eagle."
        case let .server(statusCode, message):
            return "Eagle API error (\(statusCode)): \(message)"
        case let .api(message):
            return message
        case .cannotCreateUploadBody:
            return "The temporary upload body could not be created."
        case let .keychain(status):
            return "The API token could not be saved to Keychain (\(status))."
        }
    }
}
