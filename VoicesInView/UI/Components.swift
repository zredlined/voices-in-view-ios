import SwiftUI

struct SessionModePicker: View {
    @Binding var selection: SessionMode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Caption mode", systemImage: "captions.bubble.fill")
                .font(.headline)

            HStack(spacing: 8) {
                modeButton(.ghost)
                modeButton(.saved)
            }
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
                Text(mode == .ghost ? "Ghost" : "Save")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(selection == mode ? Color.black : AppTheme.primaryText)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .center)
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
    var isPreparing = false
    var toggleTest: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Image(systemName: displayInputIcon)
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
                        HStack(spacing: 7) {
                            if isPreparing {
                                ProgressView()
                            }
                            Text(testButtonTitle)
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: isPreparing ? 108 : 48, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(isTesting ? AppTheme.warning : AppTheme.accent)
                    .disabled(isPreparing)
                    .accessibilityLabel(testAccessibilityLabel)
                    .accessibilityHint("Tests microphone levels without creating captions")
                } else {
                    Text(inputBadge)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(inputColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(inputColor)
                }
            }

            if isPreparing || isTesting || !audio.meterSnapshot.rms.isEmpty {
                ChannelMeters(snapshot: audio.meterSnapshot)
            }

            if isPreparing || isTesting {
                Label(captureActivityText, systemImage: captureActivityIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(captureActivityColor)
                    .accessibilityIdentifier("capture-buffer-status")
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
        case .builtIn, .bluetooth, .other: AppTheme.accent
        case .unavailable: AppTheme.danger
        }
    }

    private var inputBadge: String {
        switch displayInputKind {
        case .usb: "USB"
        case .bluetooth: "AirPods"
        case .builtIn: "iPhone"
        case .other: "Other"
        case .unavailable: "None"
        }
    }

    private var displayInputKind: InputKind {
        if audio.captureProfile.requiresAirPods {
            return audio.selectedInputKind ?? .bluetooth
        }
        return audio.detectedUSBInputName == nil ? audio.routeSnapshot.inputKind : .usb
    }

    private var displayInputName: String {
        if audio.captureProfile.requiresAirPods {
            return audio.selectedInputName ?? "AirPods (automatic)"
        }
        return audio.detectedUSBInputName ?? audio.routeSnapshot.inputName
    }

    private var displayStatus: String {
        if audio.captureProfile.requiresAirPods,
           audio.routeSnapshot.inputKind != .bluetooth
        {
            return displayInputKind == .bluetooth ? "Ready" : "Unavailable"
        }
        if audio.detectedUSBInputName != nil, audio.routeSnapshot.inputKind != .usb {
            return "USB available · tap Test to connect"
        }
        return audio.routeSnapshot.statusDescription
    }

    private var displayInputIcon: String {
        switch displayInputKind {
        case .bluetooth: "airpodspro"
        case .usb: "cable.connector"
        case .builtIn, .other: "mic.fill"
        case .unavailable: "mic.slash"
        }
    }

    private var captureActivityText: String {
        if isPreparing {
            return "Connecting to the selected microphone…"
        }
        if audio.receivedBufferCount == 0 {
            return "Waiting for microphone buffers…"
        }
        if audio.nonSilentBufferCount == 0 {
            return "Receiving buffers, but they are silent"
        }
        return "Receiving live microphone audio"
    }

    private var captureActivityIcon: String {
        if isPreparing { return "arrow.trianglehead.2.clockwise.rotate.90.circle" }
        return audio.nonSilentBufferCount > 0 ? "waveform.circle.fill" : "exclamationmark.circle"
    }

    private var captureActivityColor: Color {
        if isPreparing { return AppTheme.accent }
        return audio.nonSilentBufferCount > 0 ? AppTheme.success : AppTheme.warning
    }

    private var testButtonTitle: String {
        if isPreparing { return "Connecting" }
        return isTesting ? "Stop" : "Test"
    }

    private var testAccessibilityLabel: String {
        if isPreparing { return "Connecting Microphone" }
        return isTesting ? "Stop Mic Check" : "Check Mic Levels"
    }
}

struct MicrophoneSelectionCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var audio: AudioCaptureService
    var isTesting = false
    var isPreparing = false
    var toggleTest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Input", systemImage: "mic.fill")
                    .font(.headline)

                Spacer()

                Button(action: toggleTest) {
                    HStack(spacing: 7) {
                        if isPreparing {
                            ProgressView()
                        }
                        Text(testButtonTitle)
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: isPreparing ? 108 : 48, minHeight: 40)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(isTesting ? AppTheme.warning : AppTheme.accent)
                .disabled(isPreparing)
                .accessibilityLabel(testAccessibilityLabel)
            }

            HStack(spacing: 8) {
                sourceButton(.standard, icon: "iphone")
                sourceButton(.usb, icon: "cable.connector")
                airPodsButton
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("capture-profile-picker")

            if isPreparing || isTesting {
                ChannelMeters(snapshot: audio.meterSnapshot)
            }
        }
        .appCard()
        .accessibilityElement(children: .contain)
    }

    private var controlsAreDisabled: Bool {
        model.isTestingMicrophones || model.isPreparingMicrophoneTest || model.isStarting
    }

    @ViewBuilder
    private var airPodsButton: some View {
        if audio.bluetoothInputChoices.count > 1 {
            Menu {
                ForEach(audio.bluetoothInputChoices) { choice in
                    Button {
                        model.selectCaptureProfile(.airPodsFarField)
                        audio.selectBluetoothInput(id: choice.id)
                    } label: {
                        if choice.name == audio.selectedInputName {
                            Label(choice.name, systemImage: "checkmark")
                        } else {
                            Text(choice.name)
                        }
                    }
                }
            } label: {
                sourceLabel(.airPodsFarField, icon: "airpodspro", showsMenu: true)
            }
            .buttonStyle(.plain)
            .disabled(controlsAreDisabled)
            .accessibilityLabel("AirPods")
            .accessibilityHint("Shows connected AirPods")
        } else {
            sourceButton(.airPodsFarField, icon: "airpodspro")
        }
    }

    private func sourceButton(_ profile: AudioCaptureProfile, icon: String) -> some View {
        Button {
            model.selectCaptureProfile(profile)
        } label: {
            sourceLabel(profile, icon: icon)
        }
        .buttonStyle(.plain)
        .disabled(controlsAreDisabled || (profile == .usb && audio.detectedUSBInputName == nil))
        .opacity(profile == .usb && audio.detectedUSBInputName == nil ? 0.4 : 1)
        .accessibilityLabel(profile.title)
        .accessibilityAddTraits(audio.captureProfile == profile ? .isSelected : [])
    }

    private func sourceLabel(
        _ profile: AudioCaptureProfile,
        icon: String,
        showsMenu: Bool = false
    ) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                if showsMenu {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                }
            }
            Text(profile.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(audio.captureProfile == profile ? Color.black : AppTheme.primaryText)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(
            audio.captureProfile == profile ? AppTheme.accent : Color.white.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .contentShape(Rectangle())
    }

    private var testButtonTitle: String {
        if isPreparing { return "Connecting" }
        return isTesting ? "Stop" : "Test"
    }

    private var testAccessibilityLabel: String {
        if isPreparing { return "Connecting Microphone" }
        return isTesting ? "Stop Mic Check" : "Check Mic Levels"
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
