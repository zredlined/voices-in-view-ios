import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pendingDeletion: CaptionSession?

    var body: some View {
        Group {
            if model.history.isEmpty {
                ContentUnavailableView {
                    Label("No Saved Transcripts", systemImage: "text.document")
                } description: {
                    Text("Choose Save on this iPhone before starting. Finished transcripts will appear here.")
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
                                pendingDeletion = session
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(AppTheme.background)
        .navigationTitle("Saved Transcripts")
        .task { await model.refreshHistory() }
        .refreshable { await model.refreshHistory() }
        .confirmationDialog(
            "Delete this transcript?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { session in
            Button("Delete Transcript", role: .destructive) {
                pendingDeletion = nil
                Task { await model.delete(session) }
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { _ in
            Text("This permanently removes the saved text from this iPhone.")
        }
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
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .title) private var dynamicTypeScale: CGFloat = 1
    let session: CaptionSession
    var isJustCompleted = false

    @State private var transcript: SessionTranscript?
    @State private var loadError: String?
    @State private var confirmDelete = false
    @State private var isDeleting = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if isJustCompleted {
                        Label("Transcript Saved", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(AppTheme.success)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.startedAt.formatted(date: .complete, time: .shortened))
                            .font(.headline)
                        Text("\(session.duration.formattedDuration) · \(session.inputName)")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .appCard()

                    transcriptContent
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }

            if isJustCompleted {
                completionControls
            }
        }
        .background(AppTheme.background)
        .navigationTitle("Saved Transcript")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isJustCompleted {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { model.dismissCompletedSession() }
                }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                if let transcript, !transcript.segments.isEmpty {
                    ShareLink(item: transcript.shareText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share Transcript")
                }

                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(isDeleting)
                .accessibilityLabel("Delete Transcript")
            }
        }
        .task {
            do {
                transcript = try await model.loadTranscript(session)
            } catch {
                loadError = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Delete this transcript?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Transcript", role: .destructive) {
                isDeleting = true
                Task {
                    await model.delete(session)
                    if !isJustCompleted {
                        dismiss()
                    }
                    isDeleting = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the saved text from this iPhone.")
        }
    }

    @ViewBuilder
    private var transcriptContent: some View {
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

    private var completionControls: some View {
        HStack(spacing: 12) {
            if let transcript, !transcript.segments.isEmpty {
                ShareLink(item: transcript.shareText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(minWidth: 82, minHeight: 48)
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.primaryText)
            }

            Button {
                model.dismissCompletedSession()
                Task { await model.startCaptions() }
            } label: {
                Label("Start New Captions", systemImage: "captions.bubble.fill")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
            .foregroundStyle(.black)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppTheme.card)
        .overlay(alignment: .top) { Divider().overlay(AppTheme.cardBorder) }
    }
}

private extension TimeInterval {
    var formattedDuration: String {
        Duration.seconds(self).formatted(
            .time(pattern: .hourMinuteSecond(padHourToLength: 1, fractionalSecondsLength: 0))
        )
    }
}
