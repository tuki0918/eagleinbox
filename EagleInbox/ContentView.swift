import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var model: AppModel
    @State private var needsActivationRefresh = false

    var body: some View {
        UploadView()
            .task(id: scenePhase) {
                guard scenePhase == .active else {
                    needsActivationRefresh = false
                    return
                }
                needsActivationRefresh = true
                await performPendingActivationRefresh()
            }
            .onChange(of: model.isWorking) { _, isWorking in
                guard !isWorking else { return }
                Task { @MainActor in
                    await performPendingActivationRefresh()
                }
            }
    }

    @MainActor
    private func performPendingActivationRefresh() async {
        guard model.allowsAutomaticConnectionRefresh else {
            needsActivationRefresh = false
            return
        }
        guard needsActivationRefresh,
              scenePhase == .active,
              !model.isWorking else {
            return
        }
        needsActivationRefresh = false
        model.reloadProfiles()
        guard model.selectedProfile != nil else { return }
        await model.testConnection()
    }
}
