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

                NavigationLink {
                    HistoryView()
                } label: {
                    SavedTranscriptsCard(sessions: model.history)
                }
                .buttonStyle(.plain)

                FontSizeControls(
                    size: model.captionFontSize,
                    decrease: model.decreaseFontSize,
                    increase: model.increaseFontSize
                )
                .appCard()

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
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    DiagnosticsView()
                } label: {
                    Image(systemName: "waveform.badge.magnifyingglass")
                }
                .accessibilityLabel("Diagnostics")
            }
        }
        .task {
            await model.refreshHistory()
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

private struct SavedTranscriptsCard: View {
    let sessions: [CaptionSession]

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "text.document.fill")
                .font(.title2)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text("Saved Transcripts")
                    .font(.headline)

                if let latest = sessions.first {
                    Text(latest.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                    if !latest.openingExcerpt.isEmpty {
                        Text(latest.openingExcerpt)
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)
                    }
                } else {
                    Text("Finished saved sessions appear here")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }

            Spacer(minLength: 8)

            if !sessions.isEmpty {
                Text("\(sessions.count)")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            sessions.isEmpty
                ? "Saved Transcripts, none saved"
                : "Saved Transcripts, \(sessions.count) sessions"
        )
        .accessibilityIdentifier("saved-transcripts")
    }
}
