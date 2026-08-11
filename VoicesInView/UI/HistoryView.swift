import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.history.isEmpty {
                ContentUnavailableView {
                    Label("No Saved Captions", systemImage: "text.document")
                } description: {
                    Text("Sessions recorded in Saved mode will appear here. Ghost sessions never do.")
                }
            } else {
                List {
                    ForEach(model.history) { session in
                        NavigationLink {
                            SessionDetailView(session: session)
                        } label: {
                            SessionRow(session: session)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", role: .destructive) {
                                Task { await model.delete(session) }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(AppTheme.background)
        .navigationTitle("History")
        .task { await model.refreshHistory() }
        .refreshable { await model.refreshHistory() }
    }
}

private struct SessionRow: View {
    let session: CaptionSession

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                Spacer()
                Text(session.duration.formattedDuration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Text(session.openingExcerpt.isEmpty ? "No finalized captions" : session.openingExcerpt)
                .font(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(2)

            Label(session.inputName, systemImage: session.channelCount > 1 ? "waveform" : "mic")
                .font(.caption)
                .foregroundStyle(AppTheme.accent)
        }
        .padding(.vertical, 8)
    }
}

struct SessionDetailView: View {
    @EnvironmentObject private var model: AppModel
    @ScaledMetric(relativeTo: .title) private var dynamicTypeScale: CGFloat = 1
    let session: CaptionSession

    @State private var transcript: SessionTranscript?
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.startedAt.formatted(date: .complete, time: .shortened))
                        .font(.headline)
                    Text("\(session.duration.formattedDuration) · \(session.inputName)")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .appCard()

                if let transcript {
                    if transcript.segments.isEmpty {
                        Text("No finalized captions were saved in this session.")
                            .foregroundStyle(AppTheme.secondaryText)
                    } else {
                        ForEach(transcript.segments) { segment in
                            VStack(alignment: .leading, spacing: 5) {
                                if segment.channel.id != AudioChannel.group.id {
                                    Text(segment.channel.label)
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(AppTheme.accent)
                                }
                                Text(segment.text)
                                    .font(
                                        .system(
                                            size: CGFloat(model.captionFontSize) * dynamicTypeScale,
                                            weight: .medium,
                                            design: .rounded
                                        )
                                    )
                                    .foregroundStyle(AppTheme.primaryText)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else if let loadError {
                    ErrorBanner(message: loadError) { self.loadError = nil }
                } else {
                    ProgressView("Loading transcript…")
                        .tint(AppTheme.accent)
                }
            }
            .padding(20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(AppTheme.background)
        .navigationTitle("Transcript")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                transcript = try await model.loadTranscript(session)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}

private extension TimeInterval {
    var formattedDuration: String {
        Duration.seconds(self).formatted(
            .time(pattern: .hourMinuteSecond(padHourToLength: 1, fractionalSecondsLength: 0))
        )
    }
}
