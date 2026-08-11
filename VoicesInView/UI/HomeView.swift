import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                InputStatusCard(
                    audio: model.audioCapture,
                    isTesting: model.isTestingMicrophones,
                    toggleTest: { Task { await model.toggleMicrophoneTest() } }
                )

                SessionModePicker(selection: $model.sessionMode)

                Button {
                    Task { await model.startCaptions() }
                } label: {
                    HStack(spacing: 11) {
                        if model.isStarting {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: "captions.bubble.fill")
                        }
                        Text(model.isStarting ? "Preparing…" : "Start Captions")
                    }
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(model.isStarting)
                .accessibilityHint("Begins listening and shows live on-device captions")

                if shouldShowModelStatus {
                    ModelStatusRow(readiness: model.modelReadiness)
                }
            }
            .padding(20)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .background(AppTheme.background)
        .navigationTitle("Voices in View")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink {
                    HistoryView()
                } label: {
                    Image(systemName: "doc.text.fill")
                }
                .accessibilityLabel("Saved Transcripts")
                .accessibilityIdentifier("saved-transcripts")

                NavigationLink {
                    DiagnosticsView()
                } label: {
                    Image(systemName: "waveform.badge.magnifyingglass")
                }
                .accessibilityLabel("Diagnostics")
            }
        }
        .task {
            model.audioCapture.refreshRoute()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.audioCapture.refreshRoute()
            }
        }
    }

    private var shouldShowModelStatus: Bool {
        switch model.modelReadiness {
        case .checking, .downloading, .unavailable:
            true
        case .needsDownload, .ready:
            false
        }
    }
}
