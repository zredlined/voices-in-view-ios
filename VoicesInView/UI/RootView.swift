import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()
            if model.isSessionActive || model.isStopping {
                LiveSessionView()
                    .transition(.opacity)
            } else if let session = model.completedSession {
                NavigationStack {
                    SessionDetailView(session: session, isJustCompleted: true)
                }
                .transition(.opacity)
            } else {
                NavigationStack {
                    HomeView()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.isSessionActive)
        .animation(.easeInOut(duration: 0.18), value: model.completedSession?.id)
        .alert(
            "Voices in View",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.clearError() } }
            )
        ) {
            Button("Open Settings") { model.openSettings() }
            Button("OK", role: .cancel) { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
