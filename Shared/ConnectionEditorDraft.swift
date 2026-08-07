import Foundation

struct ConnectionEditorDraft: Equatable, Sendable {
    let profile: EagleConnectionProfile
    let portText: String

    var preparedProfile: EagleConnectionProfile? {
        guard let port = Int(portText) else { return nil }
        var candidate = profile
        candidate.connection.port = port
        return candidate
    }

    var isValid: Bool {
        guard let candidate = preparedProfile else { return false }
        return !candidate.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && candidate.connection.isValid
    }

    func hasUnsavedChanges(
        comparedTo baseline: EagleConnectionProfile
    ) -> Bool {
        preparedProfile != baseline
    }

    func matchesVerifiedConnection(
        _ verifiedConnection: EagleConnection?
    ) -> Bool {
        guard let verifiedConnection else { return false }
        return preparedProfile?.connection == verifiedConnection
    }
}
