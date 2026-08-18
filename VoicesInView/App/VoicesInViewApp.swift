import SwiftUI

@main
struct VoicesInViewApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .task {
                    await model.refreshModelReadiness()
                    await model.refreshHistory()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .background else { return }
                    if model.isSessionActive {
                        Task { await model.stopCaptions() }
                    } else if model.isTestingMicrophones || model.isPreparingMicrophoneTest {
                        model.stopMicrophoneTest()
                    }
                }
        }
    }
}
