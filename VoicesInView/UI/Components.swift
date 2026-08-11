import SwiftUI

struct SessionModePicker: View {
    @Binding var selection: SessionMode

    var body: some View {
        HStack(spacing: 8) {
            modeButton(.ghost)
            modeButton(.saved)
        }
        .appCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session privacy")
    }

    private func modeButton(_ mode: SessionMode) -> some View {
        Button {
            selection = mode
        } label: {
            HStack(spacing: 8) {
                if mode == .ghost {
                    GhostIcon(size: 21)
                } else {
                    Image(systemName: "square.and.arrow.down")
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode == .ghost ? "Ghost Mode" : "Save")
                        .font(.subheadline.weight(.semibold))
                    Text(mode == .ghost ? "Not saved" : "On this iPhone")
                        .font(.caption2)
                        .opacity(0.78)
                }
            }
            .foregroundStyle(selection == mode ? Color.black : AppTheme.primaryText)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .padding(.horizontal, 12)
            .background(
                selection == mode ? AppTheme.accent : Color.white.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode == .ghost ? "Ghost Mode, not saved" : "Saved mode")
        .accessibilityAddTraits(selection == mode ? .isSelected : [])
    }
}

struct InputStatusCard: View {
    @ObservedObject var audio: AudioCaptureService
    var isTesting = false
    var toggleTest: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Image(systemName: displayInputKind == .usb ? "cable.connector" : "mic.fill")
                    .font(.title2)
                    .foregroundStyle(inputColor)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text(displayInputName)
                        .font(.headline)
                    Text(displayStatus)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                }

                Spacer()

                if let toggleTest {
                    Button(action: toggleTest) {
                        Text(isTesting ? "Stop" : "Test")
                            .font(.subheadline.weight(.semibold))
                            .frame(minWidth: 48, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(isTesting ? AppTheme.warning : AppTheme.accent)
                    .accessibilityLabel(isTesting ? "Stop Mic Check" : "Check Mic Levels")
                    .accessibilityHint("Tests microphone levels without creating captions")
                } else {
                    Text(displayInputKind == .usb ? "USB" : "iPhone")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(inputColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(inputColor)
                }
            }

            if isTesting || !audio.meterSnapshot.rms.isEmpty {
                ChannelMeters(snapshot: audio.meterSnapshot)
            }

            if audio.meterSnapshot.channelsAreNearlyIdentical {
                Label("Channels match — switch the receiver to Stereo", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.warning)
                    .accessibilityLabel("DJI channels appear duplicated. Switch the receiver to Stereo mode.")
            }
        }
        .appCard()
        .accessibilityElement(children: .contain)
    }

    private var inputColor: Color {
        switch displayInputKind {
        case .usb: AppTheme.success
        case .builtIn, .other: AppTheme.accent
        case .unavailable: AppTheme.danger
        }
    }

    private var displayInputKind: InputKind {
        audio.detectedUSBInputName == nil ? audio.routeSnapshot.inputKind : .usb
    }

    private var displayInputName: String {
        audio.detectedUSBInputName ?? audio.routeSnapshot.inputName
    }

    private var displayStatus: String {
        if audio.detectedUSBInputName != nil, audio.routeSnapshot.inputKind != .usb {
            return "USB available · tap Test to connect"
        }
        return audio.routeSnapshot.statusDescription
    }
}

struct ChannelMeters: View {
    let snapshot: AudioMeterSnapshot

    var body: some View {
        if snapshot.rms.isEmpty {
            HStack(spacing: 8) {
                ForEach(0 ..< 2, id: \.self) { _ in
                    Capsule()
                        .fill(Color.white.opacity(0.09))
                        .frame(maxWidth: .infinity, minHeight: 8, maxHeight: 8)
                }
            }
            .accessibilityLabel("Microphone level unavailable until captions start")
        } else {
            VStack(spacing: 8) {
                ForEach(Array(snapshot.rms.enumerated()), id: \.offset) { index, level in
                    HStack(spacing: 9) {
                        Text(snapshot.rms.count == 1 ? "Mic" : "CH \(index + 1)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(AppTheme.secondaryText)
                            .frame(width: 34, alignment: .leading)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.10))
                                Capsule()
                                    .fill(snapshot.clippedChannels.contains(index) ? AppTheme.danger : AppTheme.success)
                                    .frame(width: max(3, geometry.size.width * CGFloat(level)))
                            }
                        }
                        .frame(height: 8)
                        if snapshot.clippedChannels.contains(index) {
                            Text("CLIP")
                                .font(.caption2.weight(.black))
                                .foregroundStyle(AppTheme.danger)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Channel \(index + 1) level \(Int(level * 100)) percent")
                    .accessibilityValue(snapshot.clippedChannels.contains(index) ? "Clipping" : "Not clipping")
                }
            }
        }
    }
}

struct ModelStatusRow: View {
    let readiness: ModelReadiness

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(AppTheme.warning)
            Text(readiness.title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            if readiness == .checking || readiness == .downloading {
                ProgressView().tint(AppTheme.accent)
            }
        }
        .appCard()
    }
}

struct FontSizeControls: View {
    let size: Double
    let decrease: () -> Void
    let increase: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("Caption size")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button(action: decrease) {
                Image(systemName: "textformat.size.smaller")
                    .frame(width: 44, height: 44)
            }
            .disabled(size <= 24)
            .accessibilityLabel("Decrease caption size")

            Text("\(Int(size))")
                .font(.body.monospacedDigit().weight(.semibold))
                .frame(minWidth: 32)
                .accessibilityLabel("\(Int(size)) points")
                .accessibilityIdentifier("caption-size-value")

            Button(action: increase) {
                Image(systemName: "textformat.size.larger")
                    .frame(width: 44, height: 44)
            }
            .disabled(size >= 72)
            .accessibilityLabel("Increase caption size")
        }
        .buttonStyle(.bordered)
        .tint(AppTheme.accent)
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.warning)
            Text(message)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(14)
        .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(AppTheme.warning.opacity(0.65), lineWidth: 1)
        }
    }
}
