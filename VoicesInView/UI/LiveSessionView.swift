import SwiftUI

struct LiveSessionView: View {
    @EnvironmentObject private var model: AppModel
    @ScaledMetric(relativeTo: .title) private var dynamicTypeScale: CGFloat = 1
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            liveHeader

            if let routeBanner = model.routeBanner {
                ErrorBanner(message: routeBanner) {
                    model.routeBanner = nil
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
            }

            transcript

            liveControls
        }
        .background(AppTheme.background.ignoresSafeArea())
    }

    private var liveHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(AppTheme.success)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(AppTheme.success.opacity(0.3), lineWidth: 6))
                    .accessibilityHidden(true)

                Text("LIVE")
                    .font(.caption.weight(.black))
                    .tracking(1.2)

                if model.currentSession?.mode == .ghost {
                    Divider().frame(height: 18)
                    GhostIcon(size: 20)
                    Text("Ghost Mode — not saved")
                        .font(.caption.weight(.bold))
                } else {
                    Divider().frame(height: 18)
                    Image(systemName: "lock.fill")
                        .font(.caption)
                    Text("Saving on this iPhone")
                        .font(.caption.weight(.semibold))
                }

                Spacer()

                Text(model.audioCapture.routeSnapshot.inputKind == .usb ? "USB" : "iPhone Mic")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(
                        model.audioCapture.routeSnapshot.inputKind == .usb
                            ? AppTheme.success
                            : AppTheme.accent
                    )
            }
            ChannelMeters(snapshot: model.audioCapture.meterSnapshot)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(AppTheme.card)
        .overlay(alignment: .bottom) { Divider().overlay(AppTheme.cardBorder) }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if model.visibleSegments.isEmpty {
                            listeningPlaceholder
                        } else {
                            ForEach(model.visibleSegments) { segment in
                                CaptionSegmentView(
                                    segment: segment,
                                    fontSize: model.captionFontSize
                                )
                                .id(segment.id)
                            }
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("live-bottom")
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 28)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8).onChanged { _ in autoScroll = false }
                )

                if !autoScroll, !model.visibleSegments.isEmpty {
                    Button {
                        autoScroll = true
                        withAnimation { proxy.scrollTo("live-bottom", anchor: .bottom) }
                    } label: {
                        Label("Jump to Live", systemImage: "arrow.down.circle.fill")
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(AppTheme.accent, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .padding(16)
                }
            }
            .onChange(of: model.visibleSegments) { _, _ in
                guard autoScroll else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("live-bottom", anchor: .bottom)
                }
            }
        }
    }

    private var listeningPlaceholder: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Listening…")
                .font(
                    .system(
                        size: CGFloat(model.captionFontSize) * dynamicTypeScale,
                        weight: .semibold,
                        design: .rounded
                    )
                )
                .foregroundStyle(AppTheme.primaryText)
            Text("Start speaking near the connected microphones. Words will appear here.")
                .font(.title3)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var liveControls: some View {
        HStack(spacing: 13) {
            Button(action: model.decreaseFontSize) {
                Image(systemName: "textformat.size.smaller")
                    .frame(width: 48, height: 48)
            }
            .disabled(model.captionFontSize <= 24)
            .accessibilityLabel("Decrease caption size")

            Text("\(Int(model.captionFontSize))")
                .font(.callout.monospacedDigit().weight(.bold))
                .foregroundStyle(AppTheme.secondaryText)
                .frame(minWidth: 30)

            Button(action: model.increaseFontSize) {
                Image(systemName: "textformat.size.larger")
                    .frame(width: 48, height: 48)
            }
            .disabled(model.captionFontSize >= 72)
            .accessibilityLabel("Increase caption size")

            Spacer()

            Button(role: .destructive) {
                Task { await model.stopCaptions() }
            } label: {
                HStack(spacing: 8) {
                    if model.isStopping {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "stop.fill")
                    }
                    Text(stopButtonTitle)
                        .fontWeight(.bold)
                }
                .frame(minWidth: 132, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.danger)
            .disabled(model.isStopping)
            .accessibilityHint("Stops listening. Saved sessions open as a transcript.")
        }
        .buttonStyle(.bordered)
        .tint(AppTheme.primaryText)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppTheme.card)
        .overlay(alignment: .top) { Divider().overlay(AppTheme.cardBorder) }
    }

    private var stopButtonTitle: String {
        guard model.isStopping else { return "End Captions" }
        return model.currentSession?.mode == .saved ? "Saving…" : "Ending…"
    }
}

private struct CaptionSegmentView: View {
    let segment: CaptionSegment
    let fontSize: Double
    @ScaledMetric(relativeTo: .title) private var dynamicTypeScale: CGFloat = 1

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            RoundedRectangle(cornerRadius: 3)
                .fill(accentColor)
                .frame(width: 5)

            VStack(alignment: .leading, spacing: 7) {
                if segment.channel.id != AudioChannel.group.id {
                    Text(segment.channel.label)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(accentColor)
                }

                Text(segment.text + (segment.isFinal ? "" : " …"))
                    .font(
                        .system(
                            size: CGFloat(fontSize) * dynamicTypeScale,
                            weight: .semibold,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(AppTheme.primaryText)
                    .lineSpacing(CGFloat(fontSize) * dynamicTypeScale * 0.18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.interpolate)

                if !segment.isFinal {
                    Text("updating")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppTheme.secondaryText)
                        .textCase(.uppercase)
                        .tracking(0.8)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            segment.channel.id == AudioChannel.group.id
                ? segment.text
                : "\(segment.channel.label): \(segment.text)"
        )
    }

    private var accentColor: Color {
        switch segment.channel.accent {
        case .neutral: AppTheme.accent
        case .blue: AppTheme.accent
        case .orange: AppTheme.orange
        }
    }
}
